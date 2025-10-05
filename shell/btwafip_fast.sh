#!/bin/bash

# Read and parse all IP entries at once using jq
jq -c '.[]' /www/server/btwaf/rule/ip_white.json |
awk '
function int2ip(ip,   a,b,c,d) {
    a = int(ip / 16777216) % 256
    b = int(ip / 65536) % 256
    c = int(ip / 256) % 256
    d = ip % 256
    return a "." b "." c "." d
}
{
    gsub(/[\[\]]/, "", $0)
    split($0, parts, ",")
    ip1 = int2ip(parts[1])
    ip2 = int2ip(parts[2])
    if (length(parts) == 3) {
        gsub(/"/, "", parts[3])
        printf "%s - %s (%s)\n", ip1, ip2, parts[3]
    } else {
        if (ip1 == ip2)
            print ip1
        else
            print ip1 " - " ip2
    }
}
'
