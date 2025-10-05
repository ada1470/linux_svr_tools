#!/usr/bin/env bash
# sys_backdoor_scan.sh
# Quick system scan for common webserver backdoor indicators
# Usage: sudo bash sys_backdoor_scan.sh [DAYS]
# Default DAYS = 7 (look for files modified in last 7 days)
# Outputs: /root/scan_report_YYYYMMDD_HHMMSS.txt (and prints live to terminal via tee)

set -eu
DAYS=${1:-7}
TS=$(date +"%Y%m%d_%H%M%S")
OUT="/root/scan_report_${TS}.txt"
TMPDIR="/root/scan_tmp_${TS}"
mkdir -p "$TMPDIR"
# create the output file first so we can tee to it
: > "$OUT"

# Redirect ALL stdout & stderr through tee so it prints to terminal and appends to $OUT
# Using a subshell process substitution for tee preserves terminal output format.
exec > >(tee -a "$OUT") 2>&1

echo "System backdoor scan report"
echo "Timestamp: $(date -Is)"
echo "Lookback days: $DAYS"
echo "Target dirs: /var /tmp /dev/shm /www /patch /opt /etc /usr /root"
echo "------------------------------------------------------------"

log() { printf "\n==== %s ====\n" "$1"; }

# 1) Check non-standard directories quickly (user noticed /patch)
log "Non-standard directories listing: /patch /opt"
for d in /patch /opt; do
  if [ -e "$d" ]; then
    printf "\n-- %s --\n" "$d"
    ls -la --color=never "$d" 2>/dev/null || echo "(cannot list $d or empty)"
  else
    echo "$d not present"
  fi
done

# 2) Recently modified files (exclude virtual fs)
log "Recently modified files (last $DAYS days) - excluding /proc /sys /dev"
find / \
  -path /proc -prune -o -path /sys -prune -o -path /dev -prune -o \
  -type f -mtime -"${DAYS}" -print 2>/dev/null | head -n 500 > "${TMPDIR}/recent_files.txt"
echo "Top 500 recent files (by find) saved to ${TMPDIR}/recent_files.txt"
printf "\nSample (first 50):\n"
head -n 50 "${TMPDIR}/recent_files.txt" || true

# 3) Search for suspicious code patterns in common web / tmp dirs
log "Searching for suspicious code patterns in /var /tmp /dev/shm /www /opt /patch"
PATTERNS="base64_decode|eval\\(|gzinflate|str_rot13|system\\(|exec\\(|shell_exec\\(|passthru\\(|popen\\(|proc_open\\(|\\$_(GET|POST|REQUEST)\\["
# limit to likely text files: php, phtml, pl, py, sh, cgi, jsp, js
grep -R --binary-files=without-match -I -nE "$PATTERNS" \
  /var /tmp /dev/shm /www /opt /patch 2>/dev/null | head -n 500 > "${TMPDIR}/suspicious_code_hits.txt"

if [ -s "${TMPDIR}/suspicious_code_hits.txt" ]; then
  echo "Found suspicious code patterns (first 500 hits) saved to ${TMPDIR}/suspicious_code_hits.txt"
  head -n 200 "${TMPDIR}/suspicious_code_hits.txt" || true
else
  echo "No suspicious code patterns found in scanned dirs (grep hits empty)."
fi

# 4) Look for filenames commonly used by web shells or unexpected extensions
log "Files with suspicious names / extensions (php5, .php~, .phtml in tmp, random names)"
find /tmp /var /dev/shm /www /opt /patch -type f \( -iname "*.php5" -o -iname "*.php~" -o -iname "*.phtml" -o -iname "*.pl" -o -iname "*shell*" -o -iname "*.cgi" \) 2>/dev/null | head -n 200 > "${TMPDIR}/susp_names.txt"
if [ -s "${TMPDIR}/susp_names.txt" ]; then
  echo "Suspicious-named files (sample):"
  head -n 200 "${TMPDIR}/susp_names.txt" || true
else
  echo "No suspicious-named files found in scanned dirs."
fi

# 5) World-writable files and dirs
log "World-writable files and directories (mode o+w)"
find / -path /proc -prune -o -path /sys -prune -o -path /dev -prune -o -perm -0002 -type f -ls 2>/dev/null | head -n 200 > "${TMPDIR}/world_writable_files.txt"
find / -path /proc -prune -o -path /sys -prune -o -path /dev -prune -o -perm -0002 -type d -ls 2>/dev/null | head -n 200 > "${TMPDIR}/world_writable_dirs.txt"
echo "World-writable files sample:"
head -n 50 "${TMPDIR}/world_writable_files.txt" || true
echo "World-writable dirs sample:"
head -n 50 "${TMPDIR}/world_writable_dirs.txt" || true

# 6) Setuid binaries
log "Setuid binaries (potentially suspicious)"
find / -perm -4000 -type f -exec ls -ld {} \; 2>/dev/null > "${TMPDIR}/setuid_bins.txt"
echo "Setuid binaries list:"
sed -n '1,200p' "${TMPDIR}/setuid_bins.txt" || true

# 7) Crontab & persistence points
log "Crontabs and persistence"
echo "-- /etc/cron* content --"
ls -la /etc/cron* 2>/dev/null || true
echo "-- /var/spool/cron --"
ls -la /var/spool/cron 2>/dev/null || true
echo "-- root crontab --"
crontab -l 2>/dev/null | sed -n '1,200p' || echo "(no root crontab or cannot read)"
echo "-- system crontab files under /etc/cron* --"
for f in /etc/cron*/* 2>/dev/null; do
  if [ -f "$f" ]; then
    echo "----- $f -----"
    sed -n '1,120p' "$f" || true
  fi
done

# 8) Startup scripts and /etc/rc.local
log "Startup scripts and rc.local"
if [ -f /etc/rc.local ]; then
  echo "---- /etc/rc.local ----"
  sed -n '1,200p' /etc/rc.local || true
else
  echo "/etc/rc.local not present"
fi
echo "Listing /etc/init.d and systemd unit overrides (top):"
ls -la /etc/init.d 2>/dev/null | head -n 50 || true
systemctl list-unit-files --type=service 2>/dev/null | head -n 200 || true

# 9) Network: listening ports and associated processes
log "Network - listening sockets and processes"
if command -v ss >/dev/null 2>&1; then
  ss -tunlp | sed -n '1,200p' 2>/dev/null || true
else
  netstat -tunlp 2>/dev/null | sed -n '1,200p' || true
fi

# Processes: list top and any running from /tmp or /dev/shm
log "Processes - suspicious process owners and processes started from /tmp or /dev/shm"
ps aux --sort=-%mem | sed -n '1,120p' || true
echo "-- binaries executed from tmp or dev/shm --"
ps auxww | awk '{print $11,$2,$3,$4,$9}' | grep -E "/tmp|/dev/shm" || true

# 10) Compare checksums for busy system binaries (best-effort)
log "Binaries checksum quick-scan (ls /usr/bin /usr/sbin /bin /sbin) - sample"
for b in /bin /sbin /usr/bin /usr/sbin; do
  if [ -d "$b" ]; then
    find "$b" -maxdepth 1 -type f -executable -print0 2>/dev/null | xargs -0 md5sum 2>/dev/null | head -n 200 >> "${TMPDIR}/bins_md5.txt" || true
  fi
done
echo "Sample of md5sums saved to ${TMPDIR}/bins_md5.txt"
head -n 80 "${TMPDIR}/bins_md5.txt" || true

# 11) Check /etc/passwd for recent modifications and unexpected users
log "/etc/passwd and /etc/shadow timestamps and unusual users"
ls -l /etc/passwd /etc/shadow 2>/dev/null || true
echo "Users with UID >= 1000 (regular users):"
awk -F: '($3>=1000){print $1\":\"$3\":\"$6}' /etc/passwd | sed -n '1,200p' || true

# 12) Webserver logs tail (sample) - show last lines of common logs
log "Last lines of common webserver logs (nginx, apache) - sample"
if [ -d /var/log/nginx ]; then
  echo "---- /var/log/nginx ----"
  tail -n 200 /var/log/nginx/* 2>/dev/null | sed -n '1,200p' || true
fi
if [ -d /var/log/httpd ]; then
  echo "---- /var/log/httpd ----"
  tail -n 200 /var/log/httpd/* 2>/dev/null | sed -n '1,200p' || true
fi
if [ -d /var/log/apache2 ]; then
  echo "---- /var/log/apache2 ----"
  tail -n 200 /var/log/apache2/* 2>/dev/null | sed -n '1,200p' || true
fi

# 13) Look for suspicious PHP files in /www with obfuscation indicators
log "Obfuscated PHP patterns in /www (long lines, many concatenations, base64)"
find /www -type f -iname "*.php" -print0 2>/dev/null | xargs -0 awk 'length($0)>1000{print FILENAME\": long_line:\"length($0)}' | head -n 200 > "${TMPDIR}/long_php_lines.txt" || true
if [ -s "${TMPDIR}/long_php_lines.txt" ]; then
  echo "Long single-line PHP files (possible obfuscation):"
  head -n 200 "${TMPDIR}/long_php_lines.txt" || true
fi

# 14) Summarize counts for quick eye-scan
log "Summary counts"
echo "suspicious code hits lines: $(wc -l < "${TMPDIR}/suspicious_code_hits.txt" 2>/dev/null || echo 0)"
echo "suspicious-named files: $(wc -l < "${TMPDIR}/susp_names.txt" 2>/dev/null || echo 0)"
echo "recent files found: $(wc -l < "${TMPDIR}/recent_files.txt" 2>/dev/null || echo 0)"
echo "world-writable files: $(wc -l < "${TMPDIR}/world_writable_files.txt" 2>/dev/null || echo 0)"
echo "world-writable dirs: $(wc -l < "${TMPDIR}/world_writable_dirs.txt" 2>/dev/null || echo 0)"
echo "setuid binaries: $(wc -l < "${TMPDIR}/setuid_bins.txt" 2>/dev/null || echo 0)"

# 15) Helpful tips appended
log "Next steps / tips (read this)"
cat <<'EOF'
If you find suspicious files:
  - Do NOT reboot the server immediately.
  - Copy suspicious files to a separate machine for offline analysis (preserve timestamps).
  - Consider renaming/moving suspected files to a quarantine folder (example below).
  - Check webserver/php configs for unknown include paths.
  - Change all credentials (panel, database, system) from a clean machine if root compromise is suspected.
  - Keep logs and a forensic image if you need to involve incident response.

Example quarantine commands (uncomment & run only if you understand):
  mkdir -p /root/quarantine_${TS}
  # mv /path/to/suspect.php /root/quarantine_${TS}/

If you want, run:
  sudo bash /root/sys_backdoor_scan.sh 1
to reduce lookback to last 1 day.

Share the report file /root/scan_report_${TS}.txt if you want me to help triage findings.
EOF

echo "Report written to: $OUT"
echo "Temporary scan files in: $TMPDIR"
echo "Done."
