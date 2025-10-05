#!/bin/bash

# Directory where vhost configurations are stored
vhost_dir="/home/1panel/apps/openresty/openresty/conf/conf.d"  # Modify as needed
# Files to store results
in_range_file="in_range_domains.txt"
out_of_range_file="out_of_range_domains.txt"

# Clear previous result files
> "$in_range_file"
> "$out_of_range_file"

# Function to extract domains from vhost config files
extract_domains() {
    # echo "Extracting domains from vhost configuration..."
    grep -r -h -E '^\s*server_name' "$vhost_dir"/*.conf \
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
draw_table() {
    # Extract domains
    domains=$(extract_domains)

    # Print table header
    echo "+----------------------------+------------------+--------------------+"
    echo "| Domain Name               | IP Address       | In Server IP Range |"
    echo "+----------------------------+------------------+--------------------+"

    # Loop through each domain and check if its IP is in the server's IP range
    while read -r domain; do
        # Get the domain IP using the get_ip function
        domain_ip=$(get_ip "$domain")

        # Check if the domain's IP is pingable
        if [ -z "$domain_ip" ]; then
            domain_ip="Not Pingable"
            in_range="No"
        else
            # Check if the domain's IP is in the server's IP range
            if check_ip_range "$domain_ip"; then
                in_range="Yes"
                echo "$domain" >> "$in_range_file"
            else
                in_range="No"
                echo "$domain" >> "$out_of_range_file"
            fi
        fi

        # Print the domain info in the table row
        printf "| %-26s | %-16s | %-18s |\n" "$domain" "$domain_ip" "$in_range"
    done <<< "$domains"

    # Print table footer
    echo "+----------------------------+------------------+--------------------+"
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
