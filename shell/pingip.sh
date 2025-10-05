#!/bin/bash

# Get IP list
ip_list=($(hostname -I))

# Header
printf "\n┌%-20s┬%-10s┐\n" "--------------------" "----------"
printf "│ %-18s │ %-8s │\n" "IP Address" "Status"
printf "├%-20s┼%-10s┤\n" "--------------------" "----------"

# Check each IP
for ip in "${ip_list[@]}"; do
    # Use timeout of 10 seconds for ping
    if timeout 10 ping -c 1 -W 1 "$ip" > /dev/null 2>&1; then
        printf "│ %-18s │ \e[32m%-8s\e[0m │\n" "$ip" "OK"
    else
        printf "│ %-18s │ \e[31m%-8s\e[0m │\n" "$ip" "Timeout"
    fi
done

# Footer
printf "└%-20s┴%-10s┘\n" "--------------------" "----------"
