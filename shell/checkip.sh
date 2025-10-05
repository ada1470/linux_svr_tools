#!/bin/bash

# Get IPs from hostname -I
ip_list=($(hostname -I))

# Print table header
printf "\n┌%-20s┬%-15s┐\n" "--------------------" "---------------"
printf "│ %-18s │ %-13s │\n" "IP Address" "Response Time"
printf "├%-20s┼%-15s┤\n" "--------------------" "---------------"

# Check each IP using curl
for ip in "${ip_list[@]}"; do
    # Try HTTP request to IP (port 80), only HEAD, max time 10s
    result=$(curl -s -o /dev/null -w "%{time_total}" --max-time 10 "http://$ip")

    # Check if curl succeeded
    if [ $? -eq 0 ]; then
        # Convert response time to ms
        ms=$(awk "BEGIN {printf \"%.0f\", $result * 1000}")
        printf "│ %-18s │ \e[32m%4s ms\e[0m       │\n" "$ip" "$ms"
    else
        printf "│ %-18s │ \e[31mTimeout\e[0m        │\n" "$ip"
    fi
done

# Footer
printf "└%-20s┴%-15s┘\n" "--------------------" "---------------"
