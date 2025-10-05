#!/bin/bash

# Define the file path for your vhost configurations
vhost_dir="/www/server/panel/vhost"

# Function to get IP address of the domain
get_ip() {
    domain=$1
    # Try getting the first IPv4 address using getent (or fallback to ping if necessary)
    ip=$(getent ahostsv4 "$domain" | awk '{print $1; exit}')
    if [ -z "$ip" ]; then
        ip=$(ping -4 -c 1 "$domain" | sed -n 's/.*(\(.*\)).*/\1/p')
    fi
    echo "$ip"
}

# Get the server's IP range dynamically
get_server_ip_range() {
    # Get the primary IP address and subnet using ip addr
    ip_addr=$(ip addr | grep -E 'inet ' | grep -v '127.0.0.1' | awk '{print $2}' | head -n 1)
    if [ -z "$ip_addr" ]; then
        echo "No IP address found!"
        exit 1
    fi

    # Extract the network and subnet (e.g., 192.168.1.0/24)
    server_ip_range=$(echo $ip_addr | cut -d'/' -f1)
    subnet_mask=$(echo $ip_addr | cut -d'/' -f2)

    # Calculate the network range (optional: if needed)
    network_range=$(ipcalc -n -s $server_ip_range/$subnet_mask | grep Network | awk '{print $2}')
    echo "$network_range"
}

# Check if the IP is in the server's IP range
check_ip_range() {
    ip=$1
    network_range=$2
    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        if [[ "$ip" =~ $network_range ]]; then
            echo "Yes"
        else
            echo "No"
        fi
    else
        echo "Invalid IP"
    fi
}

# Output table header
printf "%-30s %-20s %-20s %-20s\n" "Domain" "Resolved IP" "IP in Range" "Server IP Range"
printf "%-30s %-20s %-20s %-20s\n" "------" "-----------" "-----------" "----------------"

# Extract domain names from the vhost configuration files
echo "Extracting domains from vhost configuration..."
grep -r -h -E '^\s*Server(Name|Alias)' "$vhost_dir"/*/*.conf \
| awk '{ for(i=2; i<=NF; i++) print $i }' \
| sed -E 's/^(www\.|\*\.)//' \
| sort | uniq \
| while read -r domain; do
    # Get IP for the domain
    ip=$(get_ip "$domain")
    if [ -n "$ip" ]; then
        # Get the server's IP range dynamically
        server_ip_range=$(get_server_ip_range)
        # Check if the IP is within the server IP range
        in_range=$(check_ip_range "$ip" "$server_ip_range")
        # Output the result in a table format
        printf "%-30s %-20s %-20s %-20s\n" "$domain" "$ip" "$in_range" "$server_ip_range"
    else
        # Output result if IP resolution failed
        printf "%-30s %-20s %-20s %-20s\n" "$domain" "N/A" "N/A" "N/A"
    fi
done
