# #!/bin/bash

# install_jq() {
#   if [ -f /etc/centos-release ]; then
#     sudo yum install -y epel-release
#     sudo yum install -y jq
#   elif [ -f /etc/lsb-release ] || grep -qi ubuntu /etc/os-release; then
#     sudo apt update
#     sudo apt install -y jq
#   else
#     echo "Unsupported OS. Please install jq manually."
#     exit 1
#   fi
# }

# # Check if jq exists
# if ! command -v jq > /dev/null 2>&1; then
#   echo "jq not found, installing..."
#   install_jq || {
#     echo "Install failed, checking /usr/bin/jq immutability..."
#     sudo chattr -i /usr/bin 2>/dev/null
#     install_jq || {
#       echo "jq install failed after removing immutability. Please check manually."
#       exit 1
#     }
#   }
# fi

# # Prepare IP JSON
# hostname -I | awk '{for(i=1;i<=NF;i++) print $i}' | jq -R . | jq -s '{ips: .}' > ips.json

hostname -I | awk '{
    printf "{ \"ips\": ["
    for (i = 1; i <= NF; i++) {
        printf "\"%s\"", $i
        if (i < NF) printf ", "
    }
    print "] }"
}' > ips.json


# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

# Temp file for failed IPs
failed_log=$(mktemp)

# Print header
printf "\n%-18s | %-11s | %-9s | %-8s\n" "IP Address" "Status" "HTTP Code" "Time(s)"
printf "%-18s-+-%-11s-+-%-9s-+-%-8s\n" "------------------" "-----------" "---------" "--------"

curl -s -X POST \
  -H "Content-Type: application/json" \
  -H "X-API-KEY: MY_SUPER_SECRET_KEY_123456" \
  -d @ips.json \
  http://162.209.200.138:60000/curl-check | while read -r line; do

  # Determine if the response contains "ip" or "domain"
#   if echo "$line" | jq -e 'has("ip") or has("domain")' > /dev/null 2>&1; then
# if echo "$line" | jq -e 'has("host")' > /dev/null 2>&1; then
if echo "$line" | grep -q '"host"'; then
# echo $line
    # Use the first available key between "ip" and "domain"
    # target=$(echo "$line" | jq -r '.ip // .domain')
    # target=$(echo "$line" | jq -r '.host')

    # status_raw=$(echo "$line" | jq -r '.status')
    # code=$(echo "$line" | jq -r '.http_code // "null"')
    # time=$(echo "$line" | jq -r '.time_total_s // "null"')
    
    # Extract "host" value
    target=$(echo "$line" | sed -n 's/.*"host"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    
    # Extract "status" value (string or number, assuming no quotes)
    status_raw=$(echo "$line" | sed -n 's/.*"status"[[:space:]]*:[[:space:]]*"\{0,1\}\([^",}]*\)"\{0,1\}.*/\1/p')
    
    # Extract "http_code" value or "null" if missing
    code=$(echo "$line" | sed -n 's/.*"http_code"[[:space:]]*:[[:space:]]*"\{0,1\}\([^",}]*\)"\{0,1\}.*/\1/p')
    if [[ -z "$code" ]]; then code="null"; fi
    
    # Extract "time_total_s" value or "null" if missing
    time=$(echo "$line" | sed -n 's/.*"time_total_s"[[:space:]]*:[[:space:]]*"\{0,1\}\([^",}]*\)"\{0,1\}.*/\1/p')
    if [[ -z "$time" ]]; then time="null"; fi


    # Log if http_code is null or 000
    if [ "$code" = "null" ] || [ "$code" = "000" ]; then
      echo "$target" >> "$failed_log"
    fi

    # Build base line
    line=$(printf "%-32s | %-11s | %-9s | %-8s" "$target" "$status_raw" "$code" "$time")

    # Color HTTP code
    if [ "$code" = "null" ] || [ "$code" = "000" ]; then
      code_colored="${RED}${code}${NC}"
    elif [ "$code" = "200" ]; then
      code_colored="${GREEN}${code}${NC}"
    else
      code_colored="\033[0;33m${code}${NC}"  # orange
    fi

    # Color time
    if [[ "$time" =~ ^[0-9]*\.?[0-9]+$ ]]; then
        if awk "BEGIN {exit !($time < 1)}"; then
          time_colored="${GREEN}${time}${NC}"
        elif awk "BEGIN {exit !($time < 5)}"; then
          time_colored="\033[0;33m${time}${NC}"
        else
          time_colored="${RED}${time}${NC}"
        fi
    else
      time_colored="${RED}${time}${NC}"
    fi

    # Color status
    if [ "$status_raw" = "OK" ]; then
      status_colored="${GREEN}${status_raw}${NC}"
    else
      status_colored="${RED}${status_raw}${NC}"
    fi

    # Replace fields in line
    line="${line/ $status_raw / ${status_colored} }"
    line="${line/ $code / ${code_colored} }"
    line="${line/ $time / ${time_colored} }"

    echo -e "$line"

  else
    echo "⚠ Unexpected response: $line"
  fi

done
