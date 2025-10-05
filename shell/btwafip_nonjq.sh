#!/bin/bash

python - <<'EOF'
import json
import socket
import struct

def int_to_ip(ip):
    return socket.inet_ntoa(struct.pack("!I", ip))

with open('/www/server/btwaf/rule/ip_white.json') as f:
    data = json.load(f)

for item in data:
    start = item[0]
    end = item[1]
    for ip in xrange(start, end + 1):
        print int_to_ip(ip)
EOF
