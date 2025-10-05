#!/usr/bin/env bash
# scan_webshell_and_hardening.sh
# Non-destructive checklist scanner for CentOS 7 web servers.
# - Tìm POST requests khả nghi trong access log
# - Liệt kê file webroot thay đổi gần đây
# - Tìm pattern webshell phổ biến
# - Kiểm tra SUID files, symlink trong webroot
# - Liệt kê crontab, authorized_keys
# - Kiểm tra trạng thái SELinux và nginx/php-fpm processes
# - Ghi kết quả vào ./scan_results_TIMESTAMP.txt

set -euo pipefail
IFS=$'\n\t'

OUTFILE="./scan_results_$(date +%Y%m%d_%H%M%S).txt"
LOGDIRS=("/var/log/nginx" "/var/log")
WEBROOTS=("/var/www" "/usr/share/nginx/html" "/srv/www" "/home")
NGINX_ACCESS_CANDIDATES=("/var/log/nginx/access.log" "/var/log/nginx/access.log.1")

function heading() {
  echo -e "\n===== $1 =====\n" | tee -a "$OUTFILE"
}

function run_cmd() {
  echo "+ $*" | tee -a "$OUTFILE"
  eval "$*" 2>>"$OUTFILE" | tee -a "$OUTFILE"
}

# start
echo "Scan started at: $(date)" > "$OUTFILE"

heading "WHOAMI / ENV"
run_cmd "whoami"
run_cmd "uname -a"
run_cmd "getenforce || echo 'SELinux: getenforce not available'"

heading "NGINX / PHP-PROCESSES"
run_cmd "ps aux | egrep 'nginx:|php-fpm|php-fpm:' | sed -n '1,200p'"

heading "OPEN PORTS (ss)"
run_cmd "ss -tulnpt | sed -n '1,200p'"

# Access log analysis
heading "NGINX ACCESS LOG - suspicious POST requests (top targets)"
ACCESS_LOG=""
for c in "${NGINX_ACCESS_CANDIDATES[@]}"; do
  if [[ -f "$c" ]]; then
    ACCESS_LOG="$c"
    break
  fi
done

if [[ -z "$ACCESS_LOG" ]]; then
  echo "No nginx access log found at common paths. Searching for access.log..." | tee -a "$OUTFILE"
  ACCESS_LOG=$(find /var/log -type f -name 'access.log*' -path '*/nginx/*' 2>/dev/null | head -n1 || true)
fi

if [[ -n "$ACCESS_LOG" && -f "$ACCESS_LOG" ]]; then
  echo "Using access log: $ACCESS_LOG" | tee -a "$OUTFILE"
  # show most frequent POST URIs with status
  awk '$6 ~ /POST/ {print $7" " $9 " " $1 " " $4 " " $12}' "$ACCESS_LOG" 2>/dev/null | \
    sort | uniq -c | sort -rn | head -n 50 | tee -a "$OUTFILE" || true
  echo "\nSample POST lines (last 200)" | tee -a "$OUTFILE"
  grep 'POST' "$ACCESS_LOG" | tail -n 200 | tee -a "$OUTFILE" || true
else
  echo "No access log located. Skipping access-log checks." | tee -a "$OUTFILE"
fi

# recent modified files in webroots
heading "RECENTLY MODIFIED FILES IN WEBROOTS (last 7 days)"
for wr in "${WEBROOTS[@]}"; do
  if [[ -d "$wr" ]]; then
    echo "Scanning $wr..." | tee -a "$OUTFILE"
    find "$wr" -type f -mtime -7 -printf '%TY-%Tm-%Td %TH:%TM %p\n' 2>/dev/null | sort -r | head -n 200 | tee -a "$OUTFILE" || true
  fi
done

# search webshell patterns
heading "WEB SHELL PATTERNS (non-exhaustive)"
PATTERN="eval\(|base64_decode|gzinflate|shell_exec|passthru|exec\(|system\(|preg_replace\(.*/e|assert\(|phpinfo\(|\$_POST\[.*\]" 
for wr in "${WEBROOTS[@]}"; do
  if [[ -d "$wr" ]]; then
    echo "Searching in $wr..." | tee -a "$OUTFILE"
    # limit to common web extensions
    grep -RIl --exclude-dir={node_modules,.git} -E "$PATTERN" "$wr" 2>/dev/null | tee -a "$OUTFILE" || true
  fi
done

# find suspicious files in /tmp
heading "/tmp & /var/tmp suspicious files"
if [[ -d /tmp ]]; then
  ls -la /tmp | head -n 200 | tee -a "$OUTFILE"
fi
if [[ -d /var/tmp ]]; then
  ls -la /var/tmp | head -n 200 | tee -a "$OUTFILE"
fi

# symlinks in webroot
heading "SYMLINKS inside webroot(s)"
for wr in "${WEBROOTS[@]}"; do
  if [[ -d "$wr" ]]; then
    find "$wr" -type l -ls 2>/dev/null | tee -a "$OUTFILE" || true
  fi
done

# SUID files
heading "SUID FILES (possible privilege escalation)"
find / -perm /4000 -type f -ls 2>/dev/null | tee -a "$OUTFILE" | head -n 200 || true

# cron jobs
heading "CRONTABS (root & users)"
if command -v crontab >/dev/null 2>&1; then
  echo "root crontab:" | tee -a "$OUTFILE"
  crontab -l 2>>"$OUTFILE" || echo '(no root crontab or permission denied)' | tee -a "$OUTFILE"
fi

echo "Listing /var/spool/cron and /etc/cron.*" | tee -a "$OUTFILE"
ls -la /var/spool/cron 2>/dev/null | tee -a "$OUTFILE" || true
ls -la /etc/cron.* 2>/dev/null | tee -a "$OUTFILE" || true

# authorized_keys
heading "AUTHORIZED_KEYS for root and users (if readable)"
if [[ -f /root/.ssh/authorized_keys ]]; then
  echo "/root/.ssh/authorized_keys:" | tee -a "$OUTFILE"
  sed -n '1,200p' /root/.ssh/authorized_keys 2>/dev/null | tee -a "$OUTFILE" || true
fi
for d in /home/*; do
  if [[ -f "$d/.ssh/authorized_keys" ]]; then
    echo "User $d authorized_keys:" | tee -a "$OUTFILE"
    sed -n '1,200p' "$d/.ssh/authorized_keys" 2>/dev/null | tee -a "$OUTFILE" || true
  fi
done

# php.ini dangerous functions
heading "PHP disable_functions check (if php.ini readable)"
PHP_INIS=("/etc/php.ini" "/etc/php/7.0/fpm/php.ini" "/etc/php/7.2/fpm/php.ini")
for p in "${PHP_INIS[@]}"; do
  if [[ -f "$p" ]]; then
    echo "Checking $p" | tee -a "$OUTFILE"
    grep -E "^disable_functions|^open_basedir|^expose_php|^display_errors" "$p" 2>/dev/null | tee -a "$OUTFILE" || true
  fi
done

# rpm verify (quick head)
heading "RPM verification (first 200 lines)"
if command -v rpm >/dev/null 2>&1; then
  rpm -Va | head -n 200 2>>"$OUTFILE" | tee -a "$OUTFILE" || true
fi

# SELinux mode summary (and audit recent denials)
heading "SELINUX & AUDITD"
if command -v getenforce >/dev/null 2>&1; then
  getenforce | tee -a "$OUTFILE"
fi
if [[ -f /var/log/audit/audit.log ]]; then
  echo "Recent AVC denials (last 200 lines)" | tee -a "$OUTFILE"
  tail -n 200 /var/log/audit/audit.log | egrep "avc:|denied" | tail -n 200 | tee -a "$OUTFILE" || true
fi

# suggest next steps summary
heading "SUGGESTED NEXT STEPS (non-destructive)"
cat >> "$OUTFILE" <<'EOF'
- If you find suspicious php files (contains eval/base64/etc) copy them out for analysis but do NOT edit in place until forensic copy is saved.
- Consider snapshotting server or copying /var/log, /etc, /var/www to offline host for forensics.
- Change sensitive credentials (SSH keys, panel passwords, DB passwords) if compromise suspected.
- If root compromise suspected, isolate and consider full rebuild from known-good backup.
EOF

echo "\nScan finished at: $(date)" | tee -a "$OUTFILE"

echo "\nScan saved to: $OUTFILE"

# End of script
