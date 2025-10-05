
#!/bin/bash

# Paths
CONFIG_FILE="/www/server/panel/config/config.json"
IP_FILE="/www/server/panel/data/iplist.txt"

red()    { echo -e "\033[31m$*\033[0m"; }
green()  { echo -e "\033[32m$*\033[0m"; }

PYTHON_CMD=$(command -v python3 || command -v python || command -v py)
PYTHON_CMD=$(echo "$PYTHON_CMD" | tr -d '\r\n')

if [[ -z "$PYTHON_CMD" ]]; then
    echo "❌ No usable Python interpreter (python3, python or py) found"
    exit 1
fi

# Get title from JSON config
if [ -f "$CONFIG_FILE" ]; then
    # TITLE=$(grep -oP '"title"\s*:\s*"\K[^"]+' "$CONFIG_FILE")
    # TITLE=$(jq -r '.title' "$CONFIG_FILE" 2>/dev/null)
    # TITLE=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE')).get('title', 'Unknown'))" 2>/dev/null)
    TITLE=$($PYTHON_CMD - "$CONFIG_FILE" <<'EOF'
# -*- coding: utf-8 -*-
import json, sys, traceback

try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
    title = data.get('title') or data.get('panel', {}).get('title', 'Unknown')
    # Python 2 requires encode, Python 3 does not
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

# Get first non-empty line from IP file
if [ -f "$IP_FILE" ]; then
    SERVER_IP=$(grep -m 1 -v '^$' "$IP_FILE" | xargs)
else
    SERVER_IP="Unknown"
fi

# Output
echo "Panel Title: $TITLE"
echo "Server IP: $SERVER_IP"

# Function to validate domain names using regex
is_valid_domain() {
    [[ $1 =~ ^([a-zA-Z0-9-]+\.)+[a-zA-Z]{2,}$ ]]
}

echo "Enter the list of domains to EXCLUDE (e.g., a.com, b.com, or one per line)."
echo "To paste content, use Shift+Insert. When finished, press Ctrl+D (on an empty line) to continue:"

# Read multi-line input into a single variable
domain_input=$(cat)

# Convert input to an array: split by newline and comma
domain_array=()
while IFS= read -r line; do
    # Split by comma if any
    IFS=',' read -ra parts <<< "$line"
    for domain in "${parts[@]}"; do
        domain_trimmed=$(echo "$domain" | xargs)  # trim whitespace
        [[ -n "$domain_trimmed" ]] && domain_array+=("$domain_trimmed")
    done
done <<< "$domain_input"

valid_domains=()
invalid_domains=()

# Validate domains
for domain in "${domain_array[@]}"; do
    if is_valid_domain "$domain"; then
        valid_domains+=("$domain")
    else
        invalid_domains+=("$domain")
    fi
done

# Show invalid domains and ask confirmation
if [ "${#invalid_domains[@]}" -gt 0 ]; then
    echo -e "\n❗ Invalid domain(s) detected:"
    printf ' - %s\n' "${invalid_domains[@]}"
    read -p "Do you want to continue anyway? (y/N): " confirm_invalid
    [[ "$confirm_invalid" =~ ^[Yy]$ ]] || exit 1
fi

# Check if less than 2 valid domains
if [ "${#valid_domains[@]}" -lt 2 ]; then
    echo -e "\n⚠️ Only ${#valid_domains[@]} valid domain(s) provided:"
    printf ' - %s\n' "${valid_domains[@]}"
    read -p "Are you sure you want to continue? (y/N): " confirm_few
    [[ "$confirm_few" =~ ^[Yy]$ ]] || exit 1
fi

# Get the real domain name directory (based on cache path)

real_domains=()

echo "Getting the real domain name directory . . ."

# Check site/
while read -r dir; do
    [[ -d "$dir/cache" ]] && real_domains+=("$(basename "$dir")")
done < <(find /home/www/wwwroot/*/site/ -mindepth 1 -maxdepth 1 -type d 2>/dev/null)

# Check public/site/
while read -r dir; do
    [[ -d "$dir/cache" ]] && real_domains+=("$(basename "$dir")")
done < <(find /home/www/wwwroot/*/public/site/ -mindepth 1 -maxdepth 1 -type d 2>/dev/null)


# Remove duplicates
real_domains=($(printf "%s\n" "${real_domains[@]}" | sort -u))

# Check if the input domain name actually exists

matched_excludes=()

unmatched_excludes=()
echo "Check if the input domain name actually exists . . . "

for domain in "${valid_domains[@]}"; do
    if [[ " ${real_domains[*]} " == *" $domain "* ]]; then
        matched_excludes+=("$domain")
    else
        unmatched_excludes+=("$domain")
    fi
done

# If none match, warn and show host info and unmatched domains
if [ "${#matched_excludes[@]}" -eq 0 ]; then
    red "\n❌ The input domains do not match any cache directories on this server, you may be connected to the wrong server!"

    echo -e "\n🔍 The input domains are as follows, but none match existing cache directories:"
    for domain in "${valid_domains[@]}"; do
        echo " - $domain"
    done

    echo -e "\n📛 Current server hostname: $(hostname)"
    echo "🌐 Current server IP address: $(hostname -I | awk '{print $1}')"
    echo "📋 Current server panel identifier: $TITLE"

    echo
    read -p "Do you still want to continue? (y/N): " confirm_wrong
    [[ "$confirm_wrong" =~ ^[Yy]$ ]] || exit 1

# If some domains don’t match, just warn and prompt
elif [ "${#unmatched_excludes[@]}" -gt 0 ]; then
    red "\n⚠️ The following input domains were not found in the server cache directories and will be ignored:"
    for domain in "${unmatched_excludes[@]}"; do
        echo " - $domain"
    done
    echo
    read -p "Continue anyway? (Y/n): " confirm_partial
    [[ "$confirm_partial" =~ ^[Nn]$ ]] && exit 1
fi


# Build find exclude path expressions
exclude_expr=""
for domain in "${valid_domains[@]}"; do
    exclude_expr+="! -path '*/$domain/*' "
done

# List the domains that will be cleaned up (i.e. actually exist and are not in the exclusion list)


to_clean=()

for domain in "${real_domains[@]}"; do

    skip=0

    for ex in "${matched_excludes[@]}"; do

        [[ "$domain" == "$ex" ]] && skip=1 && break

    done

    [[ $skip -eq 0 ]] && to_clean+=("$domain")

done

echo -e "\n🧹 Will clean up the cache directories of the following domains:"

for d in "${to_clean[@]}"; do

    echo " - $d"

done


# Final output: Which domain names will be retained
if [ "${#matched_excludes[@]}" -gt 0 ]; then
    green "\n✅ The following domain names will be retained and the cache will not be cleared:"
    for domain in "${matched_excludes[@]}"; do
        echo " - $domain"
    done
fi

# # Execute the find command
# echo -e "\n🧹 Starting cache cleanup excluding:"
# printf ' - %s\n' "${valid_domains[@]}"
echo -e "\nPress Enter to continue with cache cleanup, or any other key to cancel..."

# Read one key
IFS= read -rsn1 key
if [[ -n "$key" ]]; then
    echo "❌ Cancelled."
    exit 1
fi

echo -e "\nStart cleaning . . ."
eval "find /home/www/wwwroot/*/{site,public/site}/*/cache \
-type d \
$exclude_expr \
-exec rm -rfv {} + 2>/dev/null"

echo -e "\nDone cleaning."
