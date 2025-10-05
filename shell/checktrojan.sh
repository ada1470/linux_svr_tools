#!/bin/bash

# trojan_checker.sh
# Usage: ./trojan_checker.sh /path/to/file.php

LOG_FILE="/tmp/trojan_scan.log"
RED='\033[1;31m'
ORANGE='\033[1;33m'
GREEN='\033[1;32m'
NC='\033[0m' # No Color

check_file="$1"

if [[ ! -f "$check_file" ]]; then
    echo -e "${RED}❌ File not found: $check_file${NC}"
    exit 1
fi

declare -A rules

# Define rules (add more as needed from the list)
rules["mime.types"]="document.cookie|atob|createElement|script"
rules["config.php"]=""
rules["python.service"]="curl"
rules["Session.php"]="samesite"
rules["config/config.php"]="base64"
rules["*.log"]="base64"
rules["*.html"]="document.write|eval|atob"
rules["index.php"]="error_reporting"
rules["Loader.php"]="file_get_contents|base64"
rules["Upload.php"]="base64"
rules["common.php"]="substr|eval"
rules["*.sh"]="curl|eval"
rules["*.py"]="eval"
rules["Route.php"]="file_get_contents|base64"
rules["Map.php"]="error_reporting"

# Extract base name
filename=$(basename "$check_file")

matched_any=false
found_unlisted=false

# Check if file is listed and apply rule
for key in "${!rules[@]}"; do
    if [[ "$filename" == $key || "$check_file" == *"$key" ]]; then
        keywords="${rules[$key]}"
        IFS='|' read -ra patterns <<< "$keywords"
        for pattern in "${patterns[@]}"; do
            if [[ -n "$pattern" ]] && grep -Eq "$pattern" "$check_file"; then
                echo -e "${RED}🚨 Matched [$pattern] in $check_file${NC}"
                echo "[$(date)] $check_file MATCHED [$pattern]" >> "$LOG_FILE"
                matched_any=true
            fi
        done
    fi
done

# Unlisted file: basic scan
if ! $matched_any; then
    # Scan for common backdoor/injection patterns
    if grep -Eq "(eval|base64_decode|shell_exec|system|passthru|curl|file_get_contents|gzinflate|str_rot13|create_function)" "$check_file"; then
        echo -e "${ORANGE}⚠️ Suspicious unlisted file: $check_file${NC}"
        echo "[$(date)] $check_file SUSPICIOUS UNLISTED" >> "$LOG_FILE"
        found_unlisted=true
    fi
fi

if ! $matched_any && ! $found_unlisted; then
    echo -e "${GREEN}✅ Clean: $check_file${NC}"
fi

echo -e "\n📝 Log file: ${LOG_FILE}"
