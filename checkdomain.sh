#!/bin/bash

vhost_dir="/www/server/panel/vhost"
# Use /var/tmp for safety and no permission issues
in_range_file="/var/tmp/in_range_domains.txt"
out_of_range_file="/var/tmp/out_of_range_domains.txt"


> "$in_range_file"
> "$out_of_range_file"

RED='\033[0;31m'
GREEN='\033[0;32m'
ORANGE='\033[0;33m'
NC='\033[0m'

# # Extract domains from vhost config
# extract_domains() {
#     grep -r -h -E '^\s*Server(Name|Alias)' "$vhost_dir"/*/*.conf \
#     | awk '{ for(i=2; i<=NF; i++) print $i }' \
#     | sed -E 's/^(www\.|\*\.)//'
# }

# Extract domains from vhost config
extract_domains() {
    # Get from Nginx: server_name lines
    grep -r -h -E '^\s*server_name' "$vhost_dir"/nginx/*.conf 2>/dev/null \
        | awk '{for(i=2;i<=NF;i++)print $i}' \
        | sed -E 's/^(www\.|\*\.)//' |

    # Get from Apache: ServerAlias only (skip ServerName)
    cat - <(grep -r -h -E '^\s*ServerAlias' "$vhost_dir"/apache/*.conf 2>/dev/null \
        | awk '{for(i=2;i<=NF;i++)print $i}' \
        | sed -E 's/^(www\.|\*\.)//') |
    
    # Merge, sort, and deduplicate
    sort -u
}


# Convert to base domain (remove subdomain)
get_base_domain() {
    domain=$(echo "$1" | tr '[:upper:]' '[:lower:]')  # lowercase
    IFS='.' read -r -a parts <<< "$domain"
    count=${#parts[@]}

    if (( count < 2 )); then
        echo "$domain"
        return
    fi

    tld_keywords=("com" "net" "org" "gov" "co")

    second_last=${parts[$count-2]}
    for kw in "${tld_keywords[@]}"; do
        if [[ "$second_last" == "$kw" && $count -ge 3 ]]; then
            echo "${parts[$count-3]}.${parts[$count-2]}.${parts[$count-1]}"
            return
        fi
    done

    echo "${parts[$count-2]}.${parts[$count-1]}"
}

# Validate domain: reject numeric/malformed TLDs
is_valid_domain() {
    domain="$1"
    tld="${domain##*.}"
    if [[ "$tld" =~ ^[a-zA-Z]{2,}$ ]]; then
        return 0
    else
        return 1
    fi
}

# Prepare unique base domains
all_domains=$(extract_domains)
unique_base_domains=()
for d in $all_domains; do
    base=$(get_base_domain "$d")
    if is_valid_domain "$base"; then
        unique_base_domains+=("$base")
    fi
done

# Deduplicate
all_domains=$(printf "%s\n" "${unique_base_domains[@]}" | sort -u)
total_domains=$(echo "$all_domains" | wc -l)

# Print total domains before menu
echo "🟢 Total valid base domains on server: $total_domains"
echo

# Ask user for number of domains if no param is given
if [ -z "$1" ]; then
    echo "Select option:"
    echo "1) Check all domains"
    echo "2) Check a specific number of domains"
    read -rp "Enter choice [1/2]: " choice
    if [ "$choice" == "1" ]; then
        limit=""
    elif [ "$choice" == "2" ]; then
        read -rp "Enter number of domains to check: " limit
    else
        echo "Invalid choice"; exit 1
    fi
else
    limit="$1"
fi

> "$in_range_file"
> "$out_of_range_file"

get_ip() {
    domain=$1
    ip=$(getent ahostsv4 "$domain" | awk '{print $1; exit}')
    if [ -z "$ip" ]; then
        ip=$(ping -4 -c 1 "$domain" > /dev/null 2>&1 && echo "$domain" | sed -n 's/.*(\(.*\)).*/\1/p')
    fi
    echo "$ip"
}

get_http_code() {
    domain=$1
    curl -o /dev/null -s -w "%{http_code}" -L -A "mobile" "http://$domain" --connect-timeout 5 --max-time 10
}


# check_ip_range() {
#     ip=$1

#     # Try using ip command first
#     if command -v ip >/dev/null 2>&1; then
#         server_ips=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
#     elif command -v ifconfig >/dev/null 2>&1; then
#         server_ips=$(ifconfig | grep -oE 'inet (addr:)?([0-9]+\.){3}[0-9]+' | awk '{print $2}' | sed 's/addr://')
#     else
#         # Last resort: extract from /proc/net/fib_trie (kernel routing table)
#         server_ips=$(grep -A1 '32 host LOCAL' /proc/net/fib_trie | grep -oE '([0-9]+\.){3}[0-9]+')
#     fi

#     if echo "$server_ips" | grep -wq "$ip"; then
#         return 0
#     else
#         return 1
#     fi
# }

check_ip_range() {
    ip=$1
    server_ips=$(hostname -I 2>/dev/null)

    if echo "$server_ips" | grep -wq "$ip"; then
        return 0  # IP is in server range
    else
        return 1  # Not in range
    fi
}


draw_table() {
    if [ -n "$limit" ]; then
        domains=$(echo "$all_domains" | head -n "$limit")
    else
        domains="$all_domains"
    fi

    echo "+------------------------------+--------------------+----------------------+-----------+"
    echo "| Domain Name                 | IP Address         | In Server IP Range   | HTTP Code |"
    echo "+------------------------------+--------------------+----------------------+-----------+"

    while read -r domain; do
        domain_ip=$(get_ip "$domain" 2>/dev/null)
        if [ -z "$domain_ip" ]; then
            ip_disp="Not Pingable"; ip_color="$RED"
            in_range_disp="No"; range_color="$RED"
            raw_http_code="N/A"; http_code_disp="${RED}N/A${NC}"
            echo "$domain" >> "$out_of_range_file"
        else
            ip_disp="$domain_ip"; ip_color="$GREEN"
            if check_ip_range "$domain_ip"; then
                in_range_disp="Yes"; range_color="$GREEN"
                echo "$domain" >> "$in_range_file"
            else
                in_range_disp="No"; range_color="$RED"
                echo "$domain" >> "$out_of_range_file"
            fi
            raw_http_code=$(get_http_code "$domain")
            case "$raw_http_code" in
                200) http_color="$GREEN" ;;
                301|302) http_color="$ORANGE" ;;
                *) http_color="$RED" ;;
            esac
            padded_http=$(printf "%-9s" "$raw_http_code")
            http_code_disp="${http_color}${padded_http}${NC}"
        fi

        padded_domain=$(printf "%-28s" "$domain")
        padded_ip=$(printf "%-18s" "$ip_disp")
        padded_range=$(printf "%-20s" "$in_range_disp")

        printf "| %s | %b%s%b | %b%s%b | %b |\n" \
            "$padded_domain" \
            "$ip_color" "$padded_ip" "$NC" \
            "$range_color" "$padded_range" "$NC" \
            "$http_code_disp"
    done <<< "$domains"

    echo "+------------------------------+--------------------+----------------------+-----------+"

    total_tested=$(echo "$domains" | wc -l)
    total_in=$(wc -l < "$in_range_file")
    total_out=$(wc -l < "$out_of_range_file")
    echo
    echo "✅ Total domains tested: $total_tested"
    echo "✅ Domains in server IP range: $total_in"
    echo "❌ Domains not in range or not pingable: $total_out"
}

draw_table
echo "Results saved to $in_range_file (In range) and $out_of_range_file (Not in range or not pingable)"
