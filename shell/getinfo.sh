#!/bin/bash

# Colors
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BOLD="\033[1m"
RESET="\033[0m"

CONFIG_FILE="/www/server/panel/config/config.json"
IP_FILE="/www/server/panel/data/iplist.txt"


# Get hostname
HOSTNAME=$(hostname)

# Get Python
PYTHON_CMD=$(command -v python3 || command -v python || command -v py)
if [[ -z "$PYTHON_CMD" ]]; then
    echo -e "${RED}❌ No usable Python interpreter found${RESET}"
    exit 1
fi

# Get Panel Title
if [ -f "$CONFIG_FILE" ]; then
    TITLE=$($PYTHON_CMD - "$CONFIG_FILE" <<'EOF'
# -*- coding: utf-8 -*-
import json, sys, traceback
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
    title = data.get('title') or data.get('panel', {}).get('title', 'Unknown')
    if sys.version_info[0] < 3:
        if isinstance(title, unicode):
            title = title.encode('utf-8')
    print(title)
except Exception:
    print("Unknown")
    traceback.print_exc(file=sys.stderr)
EOF
    )
else
    TITLE="Unknown"
fi

# Get IP
if [ -f "$IP_FILE" ]; then
    SERVER_IP=$(grep -m 1 -v '^$' "$IP_FILE" | xargs)
else
    SERVER_IP="Unknown"
fi

# Web server
if pgrep -x "nginx" >/dev/null || [ -x /www/server/nginx/sbin/nginx ]; then
    WEBSERVER="Nginx $(nginx -v 2>&1 | awk -F/ '{print $2}')"
elif pgrep -x "httpd" >/dev/null || [ -x /www/server/apache/bin/httpd ]; then
    WEBSERVER="Apache $(httpd -v | grep version | cut -d/ -f2 | awk '{print $1}')"
else
    WEBSERVER="Not detected"
fi

# Python version
PYTHON_VERSION=$($PYTHON_CMD -V 2>&1)

# PHP versions
PHP_BASE="/www/server/php"
PHP_VERSIONS=()
PHP_DIRS=$(find "$PHP_BASE" -maxdepth 1 -mindepth 1 -type d | sort)
for dir in $PHP_DIRS; do
    phpbin="$dir/bin/php"
    if [ -x "$phpbin" ]; then
        version=$($phpbin -v 2>/dev/null | head -n1 | awk '{print $2}')
        active=""
        [ "$(command -v php)" = "$phpbin" ] && active=" (active)"
        PHP_VERSIONS+=("PHP $version$active")
    fi
done

# CLI PHP
PHP_CLI=$(php -v 2>/dev/null | head -n1 | awk '{print $2}')

# MySQL
if command -v mysql >/dev/null; then
    MYSQL_VERSION=$(mysql -V | sed 's/Distrib //;s/,.*//')
else
    MYSQL_VERSION="Not found"
fi

# Redis
REDIS=""
[ -x "$(command -v redis-server)" ] && REDIS=$(redis-server -v | awk '{print $3}' | cut -d= -f2)

# Memcached (robust extraction)
MEMCACHED=""
if command -v memcached >/dev/null; then
    MEMCACHED=$(memcached -h 2>&1 | grep -oP 'memcached\s+\K[\d.]+' | head -n1)
fi

# OS and uptime
OS=$(grep '^PRETTY_NAME=' /etc/os-release | cut -d= -f2 | tr -d '"')
KERNEL=$(uname -r)
UPTIME=$(uptime -p)

# Output formatting
LINE_WIDTH=74
LINE=$(printf '%*s' "$LINE_WIDTH" '' | sed 's/ /─/g')


# Function to convert IP digits to spaced emoji format with 🔸 separators
ip_to_emoji() {
  local ip="$1"
  local result=""
  local -A map=(
    ["0"]="0️⃣"
    ["1"]="1️⃣"
    ["2"]="2️⃣"
    ["3"]="3️⃣"
    ["4"]="4️⃣"
    ["5"]="5️⃣"
    ["6"]="6️⃣"
    ["7"]="7️⃣"
    ["8"]="8️⃣"
    ["9"]="9️⃣"
  )
  
  IFS='.' read -ra octets <<< "$ip"
  for ((o=0; o<${#octets[@]}; o++)); do
    octet="${octets[o]}"
    for ((i=0; i<${#octet}; i++)); do
      c="${octet:$i:1}"
      result+="${map[$c]:-$c} "  # Add emoji with 2 spaces
    done
    if [[ $o -lt 3 ]]; then
      result+="🔸 "
    fi
  done
  echo "$result"
}


# print_row() {
#     local label="$1"
#     local value="$2"
#     printf "%20s : %-53s\n" "$label" "$value"
# }

print_row() {
    local label="$1"
    local value="$2"

    # Debug info (prints raw characters and lengths)
    echo "DEBUG: label='${label}' (${#label} chars), value='${value}' (${#value} chars)" >&2

    # Strip ANSI color codes for width calculation (optional)
    local clean_label=$(echo -e "$label" | sed 's/\x1B\[[0-9;]*[a-zA-Z]//g')
    local clean_value=$(echo -e "$value" | sed 's/\x1B\[[0-9;]*[a-zA-Z]//g')

    echo "DEBUG: clean_label='${clean_label}' (${#clean_label}), clean_value='${clean_value}' (${#clean_value})" >&2

    printf "%20s : %-53s\n" "$label" "$value"
}


echo
# Header line: server IP in emoji digits, centered & bold
header_text=$(ip_to_emoji "$SERVER_IP")
pad_left=$(( (LINE_WIDTH - $(echo -n "$header_text" | wc -m)) / 2 ))
pad_right=$(( LINE_WIDTH - pad_left - $(echo -n "$header_text" | wc -m) ))
# printf "%*s%s%*s\n" "$pad_left" "" "${BOLD}${header_text}${RESET}" "$pad_right" ""
echo "🌐  $header_text"

echo "$LINE"

print_row "🖥️  Hostname" "$HOSTNAME"
print_row "🧩  Panel Title" "$TITLE"
print_row "🔆  Server IP" "$SERVER_IP"
print_row "🕸️  Web Server" "$WEBSERVER"
print_row "🐍  Python" "$PYTHON_VERSION"

if [ ${#PHP_VERSIONS[@]} -eq 0 ]; then
    print_row "🐘  PHP Versions" "Not found"
else
    print_row "🐘  PHP Versions" "${PHP_VERSIONS[0]}"
    for ((i=1; i<${#PHP_VERSIONS[@]}; i++)); do
        printf "%16s  : %-53s\n" "" "${PHP_VERSIONS[$i]}"
    done
fi

print_row "➡️  CLI PHP" "PHP $PHP_CLI"
print_row "🛢️  MySQL" "$MYSQL_VERSION"
[ -n "$REDIS" ] && print_row "📦  Redis" "$REDIS"
[ -n "$MEMCACHED" ] && print_row "📦  Memcached" "$MEMCACHED"
print_row "🖥️  System (OS)" "$OS"
print_row "🧬  Kernel" "$KERNEL"
print_row "⏱️  Uptime" "$UPTIME"

echo "$LINE"
echo
