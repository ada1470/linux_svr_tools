#!/bin/bash

# yum install jq -y

# Path to your JSON file
file="/www/server/btwaf/rule/ip_white.json"

# Convert integer to IP function
int_to_ip() {
    local ip dec=$1
    for i in {1..4}; do
        ip=$((dec % 256))${ip:+.}$ip
        dec=$((dec / 256))
    done
    echo "$ip"
}

# Read and process each IP entry
jq -c '.[]' "$file" | while read -r line; do
    # Extract start and end IP and optional comment
    start=$(echo "$line" | jq '.[0]')
    end=$(echo "$line" | jq '.[1]')
    comment=$(echo "$line" | jq -r '.[2] // empty')

    ip_start=$(int_to_ip "$start")
    ip_end=$(int_to_ip "$end")

    if [[ "$ip_start" == "$ip_end" ]]; then
        printf "%s" "$ip_start"
    else
        printf "%s - %s" "$ip_start" "$ip_end"
    fi

    [[ -n "$comment" ]] && printf " (%s)" "$comment"
    echo
done
