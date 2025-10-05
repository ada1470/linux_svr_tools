#!/bin/bash
# diagnose_config.sh
#!/bin/bash
#
# ┌────────────────────────────────────────────────────────────┐
# │               Server Configuration Diagnostic Tool         │
# └────────────────────────────────────────────────────────────┘
#
# Description:
#   This script diagnoses common server misconfigurations and issues
#   for web environments using Apache or Nginx with the BT panel.
#   It checks for:
#     - Rewrite rules blocking PC access
#     - Fail2Ban installation and service status
#     - Firewall status (firewalld/ufw)
#     - Large error logs (>1MB)
#     - CDN IP presence in firewall
#     - HTTP 200 response from configured domains via Baiduspider UA
#
# Author: @ada1470
# Version: 1.0
# Date: 2025-06-16
#
# Usage:
#   chmod +x diagnose_config.sh
#   sudo ./diagnose_config.sh
#
# Notes:
#   - Must be run with root or sudo privileges
#   - Output is colorized for readability and saved to /var/log/config_diagnose.log
#


LOGFILE="/var/log/config_diagnose.log"
> "$LOGFILE"  # Clear old log

# === Color Definitions ===
RED="\033[1;31m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
ORANGE="\033[38;5;208m"
CYAN="\033[1;36m"
RESET="\033[0m"

log() {
  # Color to terminal, plain to log
  echo -e "$1"
  echo -e "$(echo "$1" | sed -r 's/\x1B\[[0-9;]*[mK]//g')" >> "$LOGFILE"
}

log "${CYAN}==== CONFIGURATION DIAGNOSTIC START ====${RESET}"

# 1. Check rewrite rules for 'mobile'
log "${YELLOW}--- Checking if PC access is blocked in rewrite configs (expecting 'mobile' keyword) ---${RESET}"
for file in /home/www/wwwroot/*/.htaccess; do
  [[ -f "$file" ]] || continue
  if grep -qi "mobile" "$file"; then
    log "${GREEN}[OK]${RESET} '$file' blocks PC access (contains 'mobile')"
  else
    log "${ORANGE}[WARNING]${RESET} '$file' may allow PC access (missing 'mobile')"
  fi
done

for file in /www/server/panel/vhost/rewrite/*.conf; do
  [[ -f "$file" ]] || continue
  if grep -qi "mobile" "$file"; then
    log "${GREEN}[OK]${RESET} '$file' blocks PC access (contains 'mobile')"
  else
    log "${ORANGE}[WARNING]${RESET} '$file' may allow PC access (missing 'mobile')"
  fi
done


# 9. Check BT WAF cc_mode status per domain (OK if cc_mode=1, WARNING if =4)
# log "${YELLOW}--- Checking BT WAF cc_mode status per domain ---${RESET}"

# WAF_SITE_JSON="/www/server/btwaf/site.json"
# PYTHON_BIN="/www/server/panel/pyenv/bin/python"

# if [[ -f "$WAF_SITE_JSON" && -x "$PYTHON_BIN" ]]; then
#   "$PYTHON_BIN" -c '
# import json
# try:
#     with open("/www/server/btwaf/site.json") as f:
#         d = json.load(f)
#     for domain, config in d.items():
#         cc_mode = int(config.get("cc_mode", 0))
#         if cc_mode == 1:
#             print(f"\033[1;32m[OK]\033[0m CC mode is normal (1) for: {domain}")
#         elif cc_mode == 4:
#             print(f"\033[1;31m[WARNING]\033[0m CC mode is aggressive (4) for: {domain}")
#         else:
#             print(f"\033[1;33m[NOTE]\033[0m CC mode is set to {cc_mode} for: {domain}")
# except Exception as e:
#     print(f"\033[1;31m[ERROR]\033[0m Failed to parse site.json: {e}")
# ' | tee -a "$LOGFILE"
# else
#   log "${RED}[ERROR]${RESET} WAF config or Python binary not found."
# fi
check_waf_cc_mode() {
    log "${YELLOW}--- Checking WAF CC Protection Mode ---${RESET}"

    WAF_CONFIG="/www/server/btwaf/site.json"

    # Check if WAF config exists
    if [[ ! -f "$WAF_CONFIG" ]]; then
        log "${RED}[ERROR]${RESET} WAF config not found at: $WAF_CONFIG"
        return
    fi

    # Determine available Python binary
    # PYTHON_BIN=$(command -v python || command -v /www/server/panel/pyenv/bin/python)
    # Use Baota panel's Python
    PYTHON_BIN="/www/server/panel/pyenv/bin/python"

    if [[ -z "$PYTHON_BIN" ]]; then
        log "${RED}[ERROR]${RESET} No Python interpreter found to parse WAF config."
        return
    fi

#     # Run the WAF check
#     $PYTHON_BIN -c "
# import json
# try:
#     d = json.load(open('$WAF_CONFIG'))
#     for k, v in d.items():
#         if v.get('cc_mode') == '1':
#             print('[WARNING] CC protection ENABLED for:', k)
#         else:
#             print('[OK] CC protection off for:', k)
# except Exception as e:
#     print('[ERROR] Failed to read WAF config:', e)
# "
     # Run the WAF check using HEREDOC to preserve formatting
    $PYTHON_BIN <<EOF
import json
from sys import stdout

try:
    with open("$WAF_CONFIG") as f:
        data = json.load(f)
        for domain, config in data.items():
            if config.get("cc_mode") == "1":
                stdout.write("[\033[1;31mWARNING\033[0m] CC protection ENABLED for: {}\n".format(domain))
            else:
                stdout.write("[\033[1;32mOK\033[0m] CC protection off for: {}\n".format(domain))
except Exception as e:
    stdout.write("[\033[1;31mERROR\033[0m] Failed to read WAF config: {}\n".format(e))
EOF
}

check_waf_cc_mode

# 2. Check if fail2ban is installed
log "${YELLOW}--- Checking Fail2Ban installation ---${RESET}"
if ! command -v fail2ban-client &>/dev/null; then
  log "${RED}[ERROR]${RESET} Fail2Ban is not installed"

  INSTALL_CMD=""
  OS_NAME="unknown"

  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    OS_NAME="$ID"

    if [[ "$ID" == "ubuntu" || "$ID_LIKE" == *"debian"* ]]; then
      INSTALL_CMD="apt update && apt install fail2ban -y"
    elif [[ "$ID" == "centos" || "$ID" == "rocky" || "$ID_LIKE" == *"rhel"* ]]; then
      INSTALL_CMD="yum install fail2ban -y"
    fi
  fi

#   if [[ -n "$INSTALL_CMD" ]]; then
#     log "${CYAN}[PROMPT]${RESET} Do you want to install Fail2Ban now using:"
#     log "         ${YELLOW}$INSTALL_CMD${RESET}"
#     read -rp "$(echo -e "${CYAN}         Install now? (y/n): ${RESET}")" ans
#     if [[ "$ans" =~ ^[Yy]$ ]]; then
#       log "${CYAN}[ACTION]${RESET} Installing Fail2Ban..."
#       eval "$INSTALL_CMD"
#       if command -v fail2ban-client &>/dev/null; then
#         log "${GREEN}[OK]${RESET} Fail2Ban installed successfully."

#         # Enable and start the service
#         log "${CYAN}[ACTION]${RESET} Enabling and starting Fail2Ban service..."
#         systemctl enable fail2ban &>/dev/null && systemctl start fail2ban

#         # Check service status
#         if systemctl is-active --quiet fail2ban; then
#           log "${GREEN}[OK]${RESET} Fail2Ban service is running"
#         else
#           log "${RED}[FAIL]${RESET} Fail2Ban service failed to start. Check manually."
#         fi
#       else
#         log "${RED}[FAIL]${RESET} Fail2Ban installation failed. Please check manually."
#       fi
#     else
#       log "${YELLOW}[SKIP]${RESET} User chose not to install Fail2Ban."
#     fi
#   else
#     log "${CYAN}[SUGGEST]${RESET} OS not recognized. Please install Fail2Ban manually."
#   fi

else
  log "${GREEN}[OK]${RESET} Fail2Ban is already installed"
fi


# 3. Check if firewall is active
log "${YELLOW}--- Checking if firewall is active (firewalld or ufw) ---${RESET}"
if command -v firewall-cmd &>/dev/null; then
  firewall-cmd --state &>/dev/null && \
    log "${GREEN}[OK]${RESET} firewalld is active" || \
    log "${RED}[ERROR]${RESET} firewalld is not active"
elif command -v ufw &>/dev/null; then
  ufw status | grep -q "Status: active" && \
    log "${GREEN}[OK]${RESET} ufw is active" || \
    log "${RED}[ERROR]${RESET} ufw is not active"
else
  log "${RED}[ERROR]${RESET} No known firewall (firewalld or ufw) found"
fi

# 4. Check large .error logs (>1MB)
log "${YELLOW}--- Checking large error log files (>1MB) ---${RESET}"
find /www/wwwlogs/ -type f \( -name "*.error.log" -o -name "*-error_log" \) -size +1M 2>/dev/null | while read -r f; do
  log "${RED}[WARNING]${RESET} Large error log: $f"
done

# 5. Check for CDN IP in firewall config
log "${YELLOW}--- Checking for CDN IPs in firewall config ---${RESET}"
if grep -qi "cdn" /www/server/panel/data/db/firewall.db.firewall_ip.brief 2>/dev/null; then
  log "${GREEN}[OK]${RESET} CDN IPs found in firewall config"
else
  log "${ORANGE}[WARNING]${RESET} CDN IPs missing in firewall config"
fi

# 7. Check if 'app_debug' is enabled in config.php
log "${YELLOW}--- Checking if 'app_debug' is enabled in PHP config files ---${RESET}"
find /home/www/wwwroot/  -maxdepth 3 -type f -path "*/application/config.php" 2>/dev/null | while read -r file; do
  if grep -Eiq "'app_debug'\s*=>\s*true" "$file"; then
    log "${ORANGE}[WARNING]${RESET} Debug mode is ENABLED in: $file"
  else
    log "${GREEN}[OK]${RESET} Debug mode is disabled in: $file"
  fi
done

check_php_status() {
    log "${YELLOW}--- Checking PHP status ---${RESET}"

    # 1. Check PHP 7.4 and PHP 7.2 file_uploads setting
    for ver in 74 72; do
        ini_file="/www/server/php/$ver/etc/php.ini"
        if [[ -f "$ini_file" ]]; then
            if grep -Eiq '^\s*file_uploads\s*=\s*On' "$ini_file"; then
                log "${RED}[WARNING]${RESET} PHP ${ver}: file_uploads is ENABLED in $ini_file"
            else
                log "${GREEN}[OK]${RESET} PHP ${ver}: file_uploads is disabled"
            fi
        else
            log "${YELLOW}[NOTE]${RESET} PHP ${ver}: php.ini not found"
        fi
    done

    # 2. Check PHP 5.6 service or process status
    # Check with service command output text
    service_output=$(service php-fpm-56 status 2>&1)
    if echo "$service_output" | grep -qiE 'running|active'; then
        log "${RED}[WARNING]${RESET} PHP 5.6 service is RUNNING"
    else
        # fallback: check running php-fpm 5.6 process
        if pgrep -f 'php-fpm.*5\.6' &>/dev/null; then
            log "${RED}[WARNING]${RESET} PHP 5.6 process is RUNNING"
        else
            log "${GREEN}[OK]${RESET} PHP 5.6 service/process is NOT running"
        fi
    fi

}


check_php_status

# MacCMS cache check – Ensure cache_core and cache_page are both 1
# check_maccms_cache() {
#     log "${YELLOW}--- Checking MacCMS Cache Settings... ---${RESET}"
    
#     for config_file in /home/www/wwwroot/*/application/extra/maccms.php; do
#         [[ ! -f "$config_file" ]] && continue

#         site=$(echo "$config_file" | cut -d/ -f5)

#         cache_core=$(grep "'cache_core'" "$config_file" | awk -F'=> ' '{print $2}' | tr -d " ',")
#         cache_page=$(grep "'cache_page'" "$config_file" | awk -F'=> ' '{print $2}' | tr -d " ',")

#         if [[ "$cache_core" == "1" && "$cache_page" == "1" ]]; then
#             log "[OK] Cache is ENABLED for: $site"
#         else
#             warn=""
#             [[ "$cache_core" != "1" ]] && warn+="cache_core=OFF "
#             [[ "$cache_page" != "1" ]] && warn+="cache_page=OFF"
#             log "[WARNING] Cache not fully enabled for: $site ($warn)"
#         fi
#     done
# }
check_maccms_cache() {
    log "${YELLOW}--- Checking MacCMS Cache Settings... ---${RESET}"
    find /home/www/wwwroot/ -maxdepth 4 -type f -path "*/application/extra/maccms.php" 2>/dev/null | while read -r file; do
        cache_core=$(grep "'cache_core'" "$file" | awk -F'=> ' '{print $2}' | tr -d " ',")
        cache_page=$(grep "'cache_page'" "$file" | awk -F'=> ' '{print $2}' | tr -d " ',")

        if [[ "$cache_core" == "1" && "$cache_page" == "1" ]]; then
            log "${GREEN}[OK]${RESET} Cache is ENABLED in: $file"
        else
            warn=""
            [[ "$cache_core" != "1" ]] && warn+="cache_core=OFF "
            [[ "$cache_page" != "1" ]] && warn+="cache_page=OFF"
            log "${RED}[WARNING]${RESET} Cache not fully enabled in: $file (${warn})"
        fi
    done
}


check_maccms_cache

check_site_status() {
  log "${YELLOW}--- Checking site status of 'datacenter.com' from site.db ---${RESET}"

  SITE_DB="/www/server/panel/data/db/site.db"
  DOMAIN="datacenter.com"

  if [[ ! -f $SITE_DB ]]; then
    log "${RED}[ERROR]${RESET} site.db not found at $SITE_DB"
    return
  fi

  status=$(sqlite3 "$SITE_DB" "SELECT status FROM sites WHERE name = '$DOMAIN';" 2>/dev/null)

  if [[ "$status" == "1" ]]; then
    log "${RED}[WARNING]${RESET} Site '$DOMAIN' is ENABLED (status = 1)"
  elif [[ "$status" == "0" ]]; then
    log "${GREEN}[OK]${RESET} Site '$DOMAIN' is DISABLED (status = 0)"
  else
    log "${YELLOW}[NOTE]${RESET} Site '$DOMAIN' not found in site.db or status is undefined"
  fi
}

check_site_status


# 8. Check if SSH password authentication is enabled
log "${YELLOW}--- Checking SSH authentication method (password vs key) ---${RESET}"

SSH_CONFIG="/etc/ssh/sshd_config"

if [[ -f "$SSH_CONFIG" ]]; then
  password_auth=$(grep -Ei "^\s*PasswordAuthentication" "$SSH_CONFIG" | tail -n1)

  if [[ "$password_auth" =~ [Yy][Ee][Ss] ]]; then
    log "${ORANGE}[WARNING]${RESET} SSH PasswordAuthentication is ENABLED → Not safe! Use SSH keys instead."
  elif [[ "$password_auth" =~ [Nn][Oo] ]]; then
    log "${GREEN}[OK]${RESET} SSH password login is DISABLED. Using keys only — good."
  else
    log "${YELLOW}[NOTE]${RESET} SSH config does not explicitly set PasswordAuthentication. Default may allow password login!"
  fi
else
  log "${RED}[ERROR]${RESET} SSH config file not found at $SSH_CONFIG"
fi

# 10. Check if siteconfig.tar.gz exists and is recent (≤ 7 days)
log "${YELLOW}--- Checking if siteconfig.tar.gz backup is recent ---${RESET}"

CONFIG_BACKUP="/home/www/backup/siteconfig.tar.gz"

if [[ -f "$CONFIG_BACKUP" ]]; then
  if find "$CONFIG_BACKUP" -mtime -7 | grep -q .; then
    log "${GREEN}[OK]${RESET} siteconfig.tar.gz exists and is recent (within 7 days)"
  else
    log "${RED}[WARNING]${RESET} siteconfig.tar.gz exists but is older than 7 days"
  fi
else
  log "${RED}[ERROR]${RESET} siteconfig.tar.gz backup is missing"
fi

# 11. Check if latest MySQL backups are recent for each database
log "${YELLOW}--- Checking if MySQL database backups are recent ---${RESET}"

BACKUP_DIR="/home/www/backup/database/mysql/crontab_backup"
MAX_DAYS=7

if [[ -d "$BACKUP_DIR" ]]; then
  for db_path in "$BACKUP_DIR"/*; do
    [[ -d "$db_path" ]] || continue
    db_name=$(basename "$db_path")

    latest_file=$(find "$db_path" -type f -name "*.sql.gz" -printf "%T@ %p\n" 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2-)

    if [[ -n "$latest_file" ]]; then
      if find "$latest_file" -mtime -"$MAX_DAYS" | grep -q .; then
        log "${GREEN}[OK]${RESET} Latest backup for DB '${db_name}' is recent: $(basename "$latest_file")"
      else
        log "${RED}[WARNING]${RESET} Backup for DB '${db_name}' is older than ${MAX_DAYS} days: $(basename "$latest_file")"
      fi
    else
      log "${RED}[ERROR]${RESET} No backup found for DB '${db_name}'"
    fi
  done
else
  log "${RED}[ERROR]${RESET} Backup directory not found: $BACKUP_DIR"
fi

# 12. Check if server uptime is too long
log "${YELLOW}--- Checking system uptime ---${RESET}"

UPTIME_LIMIT_DAYS=60
uptime_seconds=$(cut -d. -f1 /proc/uptime)
uptime_days=$(( uptime_seconds / 60 / 60 / 24 ))

if (( uptime_days > UPTIME_LIMIT_DAYS )); then
  log "${RED}[WARNING]${RESET} Server has been running for $uptime_days days. Consider restarting."
else
  log "${GREEN}[OK]${RESET} Server uptime is $uptime_days days (under ${UPTIME_LIMIT_DAYS}-day limit)"
fi



# # 6. Check random domains for HTTP 200 using Baiduspider UA
# log "${YELLOW}--- Performing random HTTP check on domains using Baiduspider UA ---${RESET}"
# domains=$(grep -r -h -E '^\s*Server(Name|Alias)' /www/server/panel/vhost/*/*.conf \
#   | awk '{ for(i=2; i<=NF; i++) print $i }' \
#   | sed -E 's/^(www\.|\*\.)//' | sort | uniq)

# if [[ -z "$domains" ]]; then
#   log "${RED}[ERROR]${RESET} No domains found in vhost configs"
# else
#   for domain in $(shuf -n 3 <<< "$domains"); do
#     code=$(curl -s -o /dev/null -w "%{http_code}" -A "Baiduspider" -m 5 "http://$domain")
#     if [[ "$code" == "200" ]]; then
#       log "${GREEN}[OK]${RESET} Domain $domain returned HTTP 200"
#     else
#       log "${RED}[WARNING]${RESET} Domain $domain returned HTTP $code"
#     fi
#   done
# fi

# 6. Check random domains for HTTP 200 using Baiduspider UA
check_http_baiduspider() {
    log "${YELLOW}--- Performing random HTTP check on domains using Baiduspider UA ---${RESET}"

    domains=$(grep -r -h -E '^\s*Server(Name|Alias)' /www/server/panel/vhost/*/*.conf \
      | awk '{ for(i=2; i<=NF; i++) print $i }' \
      | sed -E 's/^(www\.|\*\.)//' | sort | uniq)

    if [[ -z "$domains" ]]; then
        log "${RED}[ERROR]${RESET} No domains found in vhost configs"
        return
    fi

    # Get local IPs
    local_ips=$(hostname -I | xargs -n1 | sort -u)

    # Filter random domains matching local IPs
    selected_domains=()
    attempted_domains=()

    while [[ ${#selected_domains[@]} -lt 3 && ${#attempted_domains[@]} -lt 100 ]]; do
        domain=$(shuf -n 1 <<< "$domains")
        [[ " ${attempted_domains[*]} " =~ " $domain " ]] && continue
        attempted_domains+=("$domain")

        domain_ips=$(getent hosts "$domain" 2>/dev/null | awk '{print $1}' | sort -u)
        for ip in $domain_ips; do
            if grep -q "^$ip\$" <<< "$local_ips"; then
                selected_domains+=("$domain")
                break
            fi
        done
    done

    if [[ ${#selected_domains[@]} -eq 0 ]]; then
        log "${RED}[ERROR]${RESET} No domains resolved to local IPs"
        return
    fi

    for domain in "${selected_domains[@]}"; do
        code=$(curl -s -o /dev/null -w "%{http_code}" -A "Baiduspider" -m 5 "http://$domain")
        if [[ "$code" == "200" ]]; then
            log "${GREEN}[OK]${RESET} Domain $domain returned HTTP 200"
        else
            log "${RED}[WARNING]${RESET} Domain $domain returned HTTP $code"
        fi
    done
}

check_http_baiduspider


log "${CYAN}==== CONFIGURATION DIAGNOSTIC COMPLETE ====${RESET}"
