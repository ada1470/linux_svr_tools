#!/bin/bash

# Directory where vhost configurations are stored
vhost_dir="/www/server/panel/vhost"  # Modify as needed
# Files to store results
in_range_file="in_range_domains.txt"
out_of_range_file="out_of_range_domains.txt"

# Clear previous result files
> "$in_range_file"
> "$out_of_range_file"


# Color variables
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

# Function to extract domains from vhost config files
extract_domains() {
    # echo "Extracting domains from vhost configuration..."
    grep -r -h -E '^\s*Server(Name|Alias)' "$vhost_dir"/*/*.conf \
    | awk '{ for(i=2; i<=NF; i++) print $i }' \
    | sed -E 's/^(www\.|\*\.)//' \
    | sort | uniq
}

# Function to get the IP address of the domain
get_ip() {
    domain=$1
    # Try getting the first IPv4 address using getent (or fallback to ping if necessary)
    ip=$(getent ahostsv4 "$domain" | awk '{print $1; exit}')
    if [ -z "$ip" ]; then
        ip=$(ping -4 -c 1 "$domain" > /dev/null 2>&1 && echo "$domain" | sed -n 's/.*(\(.*\)).*/\1/p')
    fi
    echo "$ip"
}

# Function to draw a table with borders and save results to files
# draw_table() {
#     # Extract domains
#     domains=$(extract_domains)

#     # Print table header
#     echo "+----------------------------+------------------+--------------------+"
#     echo "| Domain Name               | IP Address       | In Server IP Range |"
#     echo "+----------------------------+------------------+--------------------+"

#     # Loop through each domain and check if its IP is in the server's IP range
#     while read -r domain; do
#         # Get the domain IP using the get_ip function
#         domain_ip=$(get_ip "$domain")

#         # Check if the domain's IP is pingable
#         if [ -z "$domain_ip" ]; then
#             domain_ip="Not Pingable"
#             in_range="No"
#         else
#             # Check if the domain's IP is in the server's IP range
#             if check_ip_range "$domain_ip"; then
#                 in_range="Yes"
#                 echo "$domain" >> "$in_range_file"
#             else
#                 in_range="No"
#                 echo "$domain" >> "$out_of_range_file"
#             fi
#         fi

#         # Print the domain info in the table row
#         # printf "| %-26s | %-16s | %-18s |\n" "$domain" "$domain_ip" "$in_range"
        
#         # Apply colors based on conditions
#         if [ "$domain_ip" == "Not Pingable" ]; then
#             ip_colored="${RED}${domain_ip}${NC}"
#         else
#             ip_colored="${GREEN}${domain_ip}${NC}"
#         fi
        
#         if [ "$in_range" == "Yes" ]; then
#             range_colored="${GREEN}${in_range}${NC}"
#         else
#             range_colored="${RED}${in_range}${NC}"
#         fi
        
#         # Print colorized row
#         printf "| %-26s | %-16b | %-18b |\n" "$domain" "$ip_colored" "$range_colored"

#     done <<< "$domains"

#     # Print table footer
#     echo "+----------------------------+------------------+--------------------+"
# }

# ANSI color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to draw a table with color and proper alignment
draw_table() {
    domains=$(extract_domains)

    # Print table header
    echo "+------------------------------+--------------------+----------------------+"
    echo "| Domain Name                 | IP Address         | In Server IP Range   |"
    echo "+------------------------------+--------------------+----------------------+"

    while read -r domain; do
        domain_ip=$(get_ip "$domain" 2>/dev/null)

        if [ -z "$domain_ip" ]; then
            ip_disp="Not Pingable"
            ip_color="${RED}"
            in_range_disp="No"
            range_color="${RED}"
            echo "$domain" >> "$out_of_range_file"
        else
            ip_disp="$domain_ip"
            ip_color="${GREEN}"
            if check_ip_range "$domain_ip"; then
                in_range_disp="Yes"
                range_color="${GREEN}"
                echo "$domain" >> "$in_range_file"
            else
                in_range_disp="No"
                range_color="${RED}"
                echo "$domain" >> "$out_of_range_file"
            fi
        fi

        # Pad fields first, then apply colors
        padded_domain=$(printf "%-28s" "$domain")
        padded_ip=$(printf "%-18s" "$ip_disp")
        padded_range=$(printf "%-20s" "$in_range_disp")

        printf "| %s | %b%s%b | %b%s%b |\n" \
            "$padded_domain" \
            "$ip_color" "$padded_ip" "$NC" \
            "$range_color" "$padded_range" "$NC"
    done <<< "$domains"

    echo "+------------------------------+--------------------+----------------------+"
}


# Function to check if an IP is in the server's IP range
check_ip_range() {
    ip=$1
    server_ips=$(ip addr | grep -E 'inet ' | grep -v '127.0.0.1' | awk '{print $2}' | cut -d'/' -f1)

    if echo "$server_ips" | grep -wq "$ip"; then
        return 0  # IP is in the range
    else
        return 1  # IP is not in the range
    fi
}

# Run the function to draw the table
draw_table

echo "Results saved to $in_range_file (In range) and $out_of_range_file (Not in range or not pingable)"
