#!/bin/bash

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

# Build find exclude path expressions
exclude_expr=""
for domain in "${valid_domains[@]}"; do
    exclude_expr+="! -path '*/$domain/*' "
done

# Execute the find command
echo -e "\n🧹 Starting cache cleanup excluding:"
printf ' - %s\n' "${valid_domains[@]}"
echo -e "\nPress Enter to continue with cache cleanup, or any other key to cancel..."

# Read one key
IFS= read -rsn1 key
if [[ -n "$key" ]]; then
    echo "❌ Cancelled."
    exit 1
fi

eval "find /home/www/wwwroot/*/{site,public/site}/*/cache \
-type d \
$exclude_expr \
-exec rm -rfv {} + 2>/dev/null"
