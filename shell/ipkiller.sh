#!/bin/bash

# Configurable Variables
TOP_IP_COUNT=200  # Number of top IPs to analyze, change as needed (e.g., 20, 50, 200, 500)
TOP_IP_ANALYSE=10
TOP_RANGE_COUNT=20

LOG_DIR="/www/wwwlogs"
BACKUP_DIR="/home/www/backup/firewall"
SPIDER_WHITELIST_REGEX="baiduspider|sogouspider|shenmaspider|hn.kd.ny.adsl"
TMP_IP_LIST="/tmp/top_ips.txt"
# Temp files for storing annotated IPs and ranges
IPS_TO_BLOCK_FILE="/tmp/ips_to_block.txt"
RANGES_TO_BLOCK_FILE="/tmp/ranges_to_block.txt"
# Paths
CONFIG_FILE="/www/server/panel/config/config.json"
IP_FILE="/www/server/panel/data/iplist.txt"




# Detect OS and firewall type
if grep -qi "ubuntu" /etc/os-release; then
    OS_TYPE="ubuntu"
    FIREWALL_CMD="ufw"
elif grep -qi "centos\|rhel\|rocky\|almalinux" /etc/os-release; then
    OS_TYPE="centos"
    FIREWALL_CMD="firewalld"
else
    OS_TYPE="unknown"
    FIREWALL_CMD="none"
fi

if command -v python3 >/dev/null 2>&1; then
    PYTHON_CMD="python3"
elif command -v python >/dev/null 2>&1; then
    PYTHON_CMD="python"
elif command -v py >/dev/null 2>&1; then
    PYTHON_CMD="py"
else
    echo "Error: Python is not installed." >&2
    exit 1
fi

# PYTHON_CMD=$(command -v python3 || command -v python || command -v py)
# PYTHON_CMD=$(echo "$PYTHON_CMD" | tr -d '\r\n')

# if [[ -z "$PYTHON_CMD" ]]; then
#     echo "❌ No usable Python interpreter (python3, python or py) found"
#     exit 1
# fi

# Get title from JSON config
if [ -f "$CONFIG_FILE" ]; then
    # TITLE=$(grep -oP '"title"\s*:\s*"\K[^"]+' "$CONFIG_FILE")
    # TITLE=$(jq -r '.title' "$CONFIG_FILE" 2>/dev/null)
    # TITLE=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE')).get('title', 'Unknown'))" 2>/dev/null)
    TITLE=$($PYTHON_CMD - "$CONFIG_FILE" <<'EOF'
# -*- coding: utf-8 -*-
import json, sys, traceback

try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
    title = data.get('title') or data.get('panel', {}).get('title', 'Unknown')
    # Python 2 requires encode, Python 3 does not
    if sys.version_info[0] < 3:
        if isinstance(title, unicode):
            title = title.encode('utf-8')
    print(title)
except Exception:
    print("Unknown")
    traceback.print_exc(file=sys.stderr)
EOF
    )

else
    TITLE="Unknown"
fi

# Get first non-empty line from IP file
if [ -f "$IP_FILE" ]; then
    SERVER_IP=$(grep -m 1 -v '^$' "$IP_FILE" | xargs)
else
    SERVER_IP="Unknown"
fi


# echo "Using Python command: $PYTHON_CMD"
# You can now use $PYTHON_CMD in your script


run_firewall_cmd() {
    local action="$1"
    local rule="$2"

    if [[ "$FIREWALL_CMD" == "firewalld" ]]; then
        case "$action" in
            add) firewall-cmd --permanent --add-rich-rule="$rule" ;;
            remove) firewall-cmd --permanent --remove-rich-rule="$rule" ;;
            reload) firewall-cmd --reload ;;
            list) firewall-cmd --list-rich-rules ;;
            backup) firewall-cmd --list-all ;;
        esac

    elif [[ "$FIREWALL_CMD" == "ufw" ]]; then
        # Extract the IP or CIDR from the rule string
        ip=$(echo "$rule" | sed -n 's/.*address=["'\''"]\([^"'\'' ]*\).*/\1/p')
        case "$action" in
            add) ufw deny from "$ip" ;;
            remove) ufw delete deny from "$ip" ;;
            reload) ufw reload ;;
            list) ufw status numbered ;;
            backup) ufw status verbose ;;
        esac

    else
        echo "❌ Unsupported or unknown firewall system"
    fi
}



# Function to detect the server type (nginx or apache)
detect_server_type() {
    if pgrep -x "nginx" >/dev/null; then
        SERVER_TYPE="nginx"
    elif pgrep -x "httpd" >/dev/null || pgrep -x "apache2" >/dev/null; then
        SERVER_TYPE="apache"
    else
        echo "Unable to detect server type."
        systemctl status nginx || systemctl status httpd || systemctl status apache2
        service nginx status
        service httpd status
        
        read -p "Do you want to restart web server? [y/N]: " confirm
        confirm=${confirm,,}  # convert to lowercase

        if [[ "$confirm" == "y" || "$confirm" == "yes" ]]; then
            restart_web_server
        fi
        
        exit 1
    fi
}

if [[ "$SERVER_TYPE" == "nginx" ]]; then
    LOG_FILES="$LOG_DIR"/*.log
else
    LOG_FILES="$LOG_DIR"/*access_log
fi

# Check if no matching log files found
if [ -z "$(ls $LOG_FILES 2>/dev/null)" ]; then
    # Default to nginx style
    LOG_FILES="$LOG_DIR"/*.log
fi


# Function to clean logs
clean_logs() {
    echo "Cleaning logs..."
    find "$LOG_DIR" -maxdepth 1 -type f \( -name "*.log" -o -name "*_log" \) -exec rm -v {} \;

    restart_web_server
}


# Function to analyze logs and generate the list of top IPs and ranges
analyze_logs() {
     echo "Analyzing logs for $SERVER_TYPE..."

    # Clear previous data
    > "$IPS_TO_BLOCK_FILE"
    > "$RANGES_TO_BLOCK_FILE"
    
    
    # if [[ $SERVER_TYPE == "nginx" ]]; then
    #     awk '{ print $1 }' "$LOG_DIR"/*.log | sort | uniq -c | sort -nr | head -n "$TOP_IP_COUNT" > "$TMP_IP_LIST"
    # else
    #     awk '{ print $1 }' "$LOG_DIR"/*_log | sort | uniq -c | sort -nr | head -n "$TOP_IP_COUNT" > "$TMP_IP_LIST"
    # fi
    
    awk '{ print $1 }' $LOG_FILES | sort | uniq -c | sort -nr | head -n "$TOP_IP_COUNT" > "$TMP_IP_LIST"
    
    
    # Remove lines that don't contain a valid IPv4 address
    sed -i '/[0-9]\{1,3\}\(\.[0-9]\{1,3\}\)\{3\}/!d' "$TMP_IP_LIST"


    echo -e "\n== Annotating Top $TOP_IP_ANALYSE Individual IPs =="

    # Annotate top IPs and write to IPS_TO_BLOCK_FILE
    head -n "$TOP_IP_ANALYSE" "$TMP_IP_LIST" | while read -r count ip; do
        annotate_ip "$ip" "$count"
        # echo "$count - $ip => $(annotate_ip "$ip" "$count")"  # Display result on screen
    done

    echo -e "\nTop IP Ranges:"
    awk '$2 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ { print $1, $2 }' "$TMP_IP_LIST" | \
    awk '
    {
        split($2, ip, ".")
        range = ip[1]"."ip[2]"."ip[3]".0/24"
        count[range] += $1
        key = range "_" $2
        if (!seen[key]++) {
            unique_count[range]++
        }
    }
    END {
        for (r in count) {
            if (unique_count[r] > 1) {
                printf "%-18s %6d requests from %3d unique IPs\n", r, count[r], unique_count[r]
            }
        }
    }' | sort -k2 -nr | head -n "$TOP_RANGE_COUNT" | tee /tmp/ip_range_summary

    echo -e "\n== Annotating IP Ranges =="

    # Annotate IP ranges and write to RANGES_TO_BLOCK_FILE
    while read -r range; do
        annotate_ip "$range" "$count_line"
        # echo "$range => $(annotate_ip "$range" "$count_line")"  # Display result on screen
    done < <(cut -d' ' -f1 /tmp/ip_range_summary)
    
    echo -e "\n== Top Referer Domains =="
        
    awk -F'"' '{print $4}' $LOG_FILES | \
        awk -F/ '/^https?:\/\// {print $3}' | \
        grep -vE '^(-|localhost|127\.0\.0\.1)$' | \
        sort | uniq -c | sort -nr | head -n 20
        
    # echo -e "\n== Top Error IPs =="
    
}

# annotate_ip() {
#     local ip="$1"
#     local count="$2"
#     local annotation=""

#     # Check if IP is a full IPv4 address
#     if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
#         # First check if IP or its /24 range is in firewall whitelist
#         range=$(echo "$ip" | sed -E 's#([0-9]+\.[0-9]+\.[0-9]+)\.[0-9]+#\1.0/24#')

#         if run_firewall_cmd list | grep -qE "$ip|$range"; then
#             annotation="firewall listed"
#         elif host_info=$(getent hosts "$ip"); then
#             if echo "$host_info" | grep -Eiq "$SPIDER_WHITELIST_REGEX"; then
#                 annotation=$(echo "$host_info" | grep -Eo "$SPIDER_WHITELIST_REGEX" | head -n 1)
#                 annotation="$annotation (whitelisted spider)"
#             else
#                 domain=$(echo "$host_info" | awk '{print $2}')
#                 annotation="$domain (unlisted spider)"
#             fi
#         else
#             annotation="UNKNOWN"
#         fi


#         # Check write permission before writing
#         if [[ -w "$IPS_TO_BLOCK_FILE" || ! -e "$IPS_TO_BLOCK_FILE" && -w "$(dirname "$IPS_TO_BLOCK_FILE")" ]]; then
#             echo "$count - $ip => $annotation" | tee -a "$IPS_TO_BLOCK_FILE"
#         else
#             echo "ERROR: Cannot write to $IPS_TO_BLOCK_FILE" >&2
#         fi

#     else
#         local ip_base=$(echo "$ip" | cut -d'/' -f1 | cut -d. -f1-3)
#         local sample_ip="$ip_base.1"
#         annotation="UNKNOWN"

#         if host_entry=$(getent hosts "$sample_ip"); then
#             if echo "$host_entry" | grep -Eiq "$SPIDER_WHITELIST_REGEX"; then
#                 spider_name=$(echo "$host_entry" | grep -Eio "$SPIDER_WHITELIST_REGEX" | head -n 1)
#                 annotation="$spider_name (spider whitelist)"
#             else
#                 domain=$(echo "$host_entry" | awk '{print $2}')
#                 annotation="$domain (unlisted spider)"
#             fi
#         elif run_firewall_cmd list | grep -Eq "$ip"; then
#             annotation="firewall listed"
#         fi

#         # Check write permission before writing
#         if [[ -w "$RANGES_TO_BLOCK_FILE" || ! -e "$RANGES_TO_BLOCK_FILE" && -w "$(dirname "$RANGES_TO_BLOCK_FILE")" ]]; then
#             echo "$ip => $annotation" | tee -a "$RANGES_TO_BLOCK_FILE"
#         else
#             echo "ERROR: Cannot write to $RANGES_TO_BLOCK_FILE" >&2
#         fi
#     fi
# }

is_whitelisted_btwaf() {
    local ip="$1"

    ip_to_int() {
        local IFS=.
        read -r o1 o2 o3 o4 <<< "$1"
        echo $(( (o1 << 24) + (o2 << 16) + (o3 << 8) + o4 ))
    }

    is_ip_in_cidr() {
        local ip="$1"
        local cidr="$2"

        IFS=/ read -r subnet mask <<< "$cidr"
        ip_int=$(ip_to_int "$ip")
        subnet_int=$(ip_to_int "$subnet")
        mask_bits=$(( 0xFFFFFFFF << (32 - mask) & 0xFFFFFFFF ))

        if (( (ip_int & mask_bits) == (subnet_int & mask_bits) )); then
            return 0
        else
            return 1
        fi
    }

    ip_int=$(ip_to_int "$ip")

    for w in "${WHITELISTED_IPS[@]}"; do
        w=$(echo "$w" | xargs)  # trim spaces

        if [[ "$w" == *"/"* ]]; then
            # CIDR format
            if is_ip_in_cidr "$ip" "$w"; then
                return 0
            fi

        elif [[ "$w" == *"-"* ]]; then
            # IP range
            IFS='-' read -r start end <<< "$w"
            start=$(echo "$start" | xargs)
            end=$(echo "$end" | xargs)
            start_int=$(ip_to_int "$start")
            end_int=$(ip_to_int "$end")
            if (( ip_int >= start_int && ip_int <= end_int )); then
                return 0
            fi

        else
            # Single IP
            if [[ "$w" == "$ip" ]]; then
                return 0
            fi
        fi
    done

    return 1
}



annotate_ip() {
    local ip="$1"
    local count="$2"
    local annotation=""

    # is_whitelisted_btwaf() {
    #     for w in "${WHITELISTED_IPS[@]}"; do
    #         if [[ "$w" == "$ip" || "$w" == "$ip - $ip" ]]; then
    #             return 0
    #         fi
    #     done
    #     return 1
    # }

    # Check if IP is full IPv4
    if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        local range=$(echo "$ip" | sed -E 's#([0-9]+\.[0-9]+\.[0-9]+)\.[0-9]+#\1.0/24#')

        # if run_firewall_cmd list | grep -qE "$ip|$range"; then
        #     annotation="firewall listed"
        # Check if IP or its /24 range is in firewall rules
        firewall_entry=$(run_firewall_cmd list | grep -E "$ip|$range")
        
        if [[ -n "$firewall_entry" ]]; then
            if echo "$firewall_entry" | grep -qE '\baccept\b|\ballow\b'; then
                annotation="firewall [white] listed"
            elif echo "$firewall_entry" | grep -qE '\bdrop\b|\breject\b'; then
                annotation="firewall [black] listed"
            else
                annotation="firewall listed"
            fi
        elif is_whitelisted_btwaf "$ip"; then
            annotation="btwaf whitelisted"
        elif host_info=$(getent hosts "$ip"); then
            if echo "$host_info" | grep -Eiq "$SPIDER_WHITELIST_REGEX"; then
                annotation=$(echo "$host_info" | grep -Eo "$SPIDER_WHITELIST_REGEX" | head -n 1)
                annotation="$annotation (whitelisted spider)"
            else
                domain=$(echo "$host_info" | awk '{print $2}')
                annotation="$domain (unlisted spider)"
            fi
        else
            annotation="UNKNOWN"
        fi

        if [[ -w "$IPS_TO_BLOCK_FILE" || ! -e "$IPS_TO_BLOCK_FILE" && -w "$(dirname "$IPS_TO_BLOCK_FILE")" ]]; then
            echo "$count - $ip => $annotation" | tee -a "$IPS_TO_BLOCK_FILE"
        else
            echo "ERROR: Cannot write to $IPS_TO_BLOCK_FILE" >&2
        fi

    else
        local ip_base=$(echo "$ip" | cut -d'/' -f1 | cut -d. -f1-3)
        local sample_ip="$ip_base.1"
        annotation="UNKNOWN"

        # if run_firewall_cmd list | grep -q "$ip"; then
        #     annotation="firewall listed"
        # Check if IP or its /24 range is in firewall rules
        firewall_entry=$(run_firewall_cmd list | grep -E "$ip")
        
        if [[ -n "$firewall_entry" ]]; then
            if echo "$firewall_entry" | grep -qE '\baccept\b|\ballow\b'; then
                annotation="firewall allowed"
            elif echo "$firewall_entry" | grep -qE '\bdrop\b|\breject\b'; then
                annotation="firewall blocked"
            else
                annotation="firewall matched"
            fi
        elif is_whitelisted_btwaf "$ip"; then
            annotation="btwaf whitelisted"
        elif host_entry=$(getent hosts "$sample_ip"); then
            if echo "$host_entry" | grep -Eiq "$SPIDER_WHITELIST_REGEX"; then
                spider_name=$(echo "$host_entry" | grep -Eio "$SPIDER_WHITELIST_REGEX" | head -n 1)
                annotation="$spider_name (spider whitelist)"
            else
                domain=$(echo "$host_entry" | awk '{print $2}')
                annotation="$domain (unlisted spider)"
            fi
        fi

        if [[ -w "$RANGES_TO_BLOCK_FILE" || ! -e "$RANGES_TO_BLOCK_FILE" && -w "$(dirname "$RANGES_TO_BLOCK_FILE")" ]]; then
            echo "$ip => $annotation" | tee -a "$RANGES_TO_BLOCK_FILE"
        else
            echo "ERROR: Cannot write to $RANGES_TO_BLOCK_FILE" >&2
        fi
    fi
}

# check_and_load_btwaf_whitelist() {
#     local whitelist_file="/www/server/btwaf/rule/ip_white.json"

#     # Check for jq first
#     if ! command -v jq >/dev/null 2>&1; then
#         echo "❌ 'jq' is not installed."
#         read -p "Do you want to install jq? [y/N]: " confirm
#         confirm=${confirm,,}
#         if [[ "$confirm" != "y" && "$confirm" != "yes" ]]; then
#             echo "Skipping whitelist check."
#             return
#         fi

#         echo "Installing jq..."

#         if [ -f /etc/redhat-release ]; then
#             sudo yum install jq -y
#         elif [ -f /etc/debian_version ]; then
#             sudo apt update && sudo apt install jq -y
#         else
#             echo "⚠️ Unknown OS. Please install jq manually."
#             return
#         fi
#     fi

#     if [[ ! -s "$whitelist_file" ]]; then
#         echo "⚠️ Whitelist file not found or empty: $whitelist_file"
#         return
#     fi

#     # echo "== Loading IP Whitelist from BTWAF =="

#     # Read and parse whitelist into a bash array (globals: WHITELISTED_IPS)
#     WHITELISTED_IPS=()

#     jq -c '.[]' "$whitelist_file" | awk '
#     function int2ip(ip,   a,b,c,d) {
#         a = int(ip / 16777216) % 256
#         b = int(ip / 65536) % 256
#         c = int(ip / 256) % 256
#         d = ip % 256
#         return a "." b "." c "." d
#     }
#     {
#         gsub(/[\[\]]/, "", $0)
#         split($0, parts, ",")
#         ip1 = int2ip(parts[1])
#         ip2 = int2ip(parts[2])
#         if (ip1 == ip2)
#             print ip1
#         else
#             print ip1 " - " ip2
#     }' > /tmp/btwaf_ip_whitelist.txt

#     mapfile -t WHITELISTED_IPS < /tmp/btwaf_ip_whitelist.txt
# }

# check_and_load_btwaf_whitelist() {
#     local whitelist_file="/www/server/btwaf/rule/ip_white.json"

#     if [[ ! -s "$whitelist_file" ]]; then
#         echo "⚠️ Whitelist file not found or empty: $whitelist_file"
#         return
#     fi

#     # echo "== Loading IP Whitelist from BTWAF =="

#     WHITELISTED_IPS=()

#     python3 - <<EOF
# import json
# import socket
# import struct

# def int2ip(ip):
#     return socket.inet_ntoa(struct.pack('!I', ip))

# try:
#     with open("$whitelist_file") as f:
#         data = json.load(f)

#     with open("/tmp/btwaf_ip_whitelist.txt", "w") as out:
#         for item in data:
#             if isinstance(item, list) and len(item) == 2:
#                 ip1 = int2ip(item[0])
#                 ip2 = int2ip(item[1])
#                 if ip1 == ip2:
#                     out.write(f"{ip1}\n")
#                 else:
#                     out.write(f"{ip1} - {ip2}\n")
# except Exception as e:
#     print(f"❌ Failed to parse whitelist: {e}")
# EOF

#     mapfile -t WHITELISTED_IPS < /tmp/btwaf_ip_whitelist.txt
# }

check_and_load_btwaf_whitelist() {
    local whitelist_file="/www/server/btwaf/rule/ip_white.json"

    if [[ ! -s "$whitelist_file" ]]; then
        echo "⚠️ Whitelist file not found or empty: $whitelist_file"
        return
    fi

    # echo "== Loading IP Whitelist from BTWAF =="

    WHITELISTED_IPS=()

    "$PYTHON_CMD" - <<EOF
# -*- coding: utf-8 -*-
import json
import socket
import struct
import sys

def int_to_ip(ip):
    return socket.inet_ntoa(struct.pack("!I", ip))

def list_to_ip(octets):
    return ".".join(str(i) for i in octets)

try:
    with open("$whitelist_file") as f:
        data = json.load(f)

    with open("/tmp/btwaf_ip_whitelist.txt", "w") as out:
        for entry in data:
            if isinstance(entry, list) and len(entry) == 2:
                start, end = entry[0], entry[1]

                # Case: [int, int]
                if isinstance(start, int) and isinstance(end, int):
                    ip1 = int_to_ip(start)
                    ip2 = int_to_ip(end)

                # Case: [[x,x,x,x], [x,x,x,x]]
                elif (
                    isinstance(start, list) and len(start) == 4 and
                    isinstance(end, list) and len(end) == 4
                ):
                    ip1 = list_to_ip(start)
                    ip2 = list_to_ip(end)

                else:
                    continue  # unsupported entry format

                if ip1 == ip2:
                    out.write(ip1 + "\n")
                else:
                    out.write(ip1 + " - " + ip2 + "\n")

except Exception as e:
    sys.stderr.write("Failed to parse whitelist: %s\n" % e)
EOF


    mapfile -t WHITELISTED_IPS < /tmp/btwaf_ip_whitelist.txt
}

# Function to block suspicious IPs based on the analysis
block_ip() {
    echo "Blocking high request IPs not whitelisted..."

    # Gather the list of IPs and ranges to block
    ips_to_block=()
    ranges_to_block=()

    # Collect IPs from the file with annotation "UNKNOWN" or "unlisted spider"
    echo -e "\n== Collecting Annotated Individual IPs to Block =="

    while read -r line; do
        ip=$(echo "$line" | awk '{print $3}')
        annotation=$(echo "$line" | cut -d'>' -f2- | sed 's/^ *//')
    
        if [[ "$annotation" == *"UNKNOWN"* || "$annotation" == *"unlisted spider"* ]]; then
            ips_to_block+=("$ip")
        fi
    done < "$IPS_TO_BLOCK_FILE"


    # Collect IP ranges from the file with annotation "UNKNOWN" or "unlisted spider"
    echo -e "\n== Collecting Annotated IP Ranges to Block =="

    while read -r line; do
        ip_base=$(echo "$line" | awk '{print $1}')
        annotation=$(echo "$line" | cut -d'>' -f2- | sed 's/^ *//')
    
        if [[ "$annotation" == *"UNKNOWN"* || "$annotation" == *"unlisted spider"* ]]; then
            ranges_to_block+=("$ip_base")
        fi
    done < "$RANGES_TO_BLOCK_FILE"


    # Show IPs and Ranges to block and ask for confirmation
    if [[ ${#ips_to_block[@]} -gt 0 ]]; then
        echo -e "\n== IPs to Block: =="
        for ip in "${ips_to_block[@]}"; do
            echo "$ip"
        done

        echo -e "\nBlock these IPs? [y/N]: "
        read -r confirm_ips
        if [[ "$confirm_ips" =~ ^[Yy]$ ]]; then
            for ip in "${ips_to_block[@]}"; do
                # Block the IP using firewall-cmd
                echo "Blocking IP: $ip"
                run_firewall_cmd add "rule family='ipv4' source address='$ip' drop"

                # Add to the firewall_ip table with the current timestamp
                sqlite3 /www/server/panel/data/db/firewall.db \
                    "INSERT INTO firewall_ip (types, address, brief, addtime, chain) VALUES ('drop', '$ip', 'Blocked by script', strftime('%Y-%m-%d %H:%M:%S', 'now'), 'INPUT');"

                echo "Successfully blocked $ip and logged in database."
            done
        fi
    fi

    if [[ ${#ranges_to_block[@]} -gt 0 ]]; then
        echo -e "\n== IP Ranges to Block: =="
        for range in "${ranges_to_block[@]}"; do
            echo "$range"
        done

        echo -e "\nBlock these IP ranges? [y/N]: "
        read -r confirm_ranges
        if [[ "$confirm_ranges" =~ ^[Yy]$ ]]; then
            for range in "${ranges_to_block[@]}"; do
                # Block the range using firewall-cmd
                echo "Blocking Range: $range"
                run_firewall_cmd add "rule family='ipv4' source address='$range' drop"

                # Add to the firewall_ip table with the current timestamp
                sqlite3 /www/server/panel/data/db/firewall.db \
                    "INSERT INTO firewall_ip (types, address, brief, addtime, chain) VALUES ('drop', '$range', 'Blocked by script', strftime('%Y-%m-%d %H:%M:%S', 'now'), 'INPUT');"

                echo "Successfully blocked $range and logged in database."
            done
        fi
    fi

    # Reload firewall to apply changes
    echo -e "\nReloading firewall..."
    run_firewall_cmd reload
}



# edit_firewall_ip_rules() {
#     echo "Editing firewall IP rules..."

#     # Show the current list of firewall rules with indexes
#     echo -e "\n== Current Firewall IP Rules =="
#     run_firewall_cmd list | nl -s '. '

#     echo -e "\nEnter the range of indexes to remove (e.g., 3-5 to remove rules from index 3 to index 5):"
#     read -r index_range

#     # Validate the input format
#     if [[ "$index_range" =~ ^[0-9]+-[0-9]+$ ]]; then
#         # Parse the start and end indexes
#         start_index=$(echo "$index_range" | cut -d'-' -f1)
#         end_index=$(echo "$index_range" | cut -d'-' -f2)

#         # Validate indexes
#         if [[ $start_index -le $end_index ]]; then
#             echo -e "\nRemoving rules from index $start_index to $end_index..."

#             # List all the rich rules with indexes
#             rules=$(run_firewall_cmd list)

#             # Split rules into an array
#             IFS=$'\n' read -r -d '' -a rule_array <<< "$rules"

#             # Remove the selected range of rules
#             for ((i = start_index - 1; i < end_index; i++)); do
#                 rule=${rule_array[$i]}
#                 if [[ -n "$rule" ]]; then
#                     echo "Removing rule: $rule"
#                     run_firewall_cmd remove "$rule"
#                 fi
#             done

#             # Reload the firewall to apply changes
#             echo -e "\nReloading firewall..."
#             run_firewall_cmd reload
#             echo "Firewall rules updated successfully."
#         else
#             echo "Invalid range. The start index must be less than or equal to the end index."
#         fi
#     else
#         echo "Invalid input. Please enter a valid range (e.g., 3-5)."
#     fi
# }

edit_firewall_ip_rules() {
    echo "Editing firewall IP rules..."

    # Show the current list of firewall rules with indexes
    echo -e "\n== Current Firewall IP Rules =="
    run_firewall_cmd list | nl -s '. '

    echo -e "\nEnter the range of indexes to remove (e.g., 3-5 to remove rules from index 3 to index 5):"
    read -r index_range

    # Validate the input format
    if [[ "$index_range" =~ ^[0-9]+-[0-9]+$ ]]; then
        # Parse the start and end indexes
        start_index=$(echo "$index_range" | cut -d'-' -f1)
        end_index=$(echo "$index_range" | cut -d'-' -f2)

        # Validate indexes
        if [[ $start_index -le $end_index ]]; then
            echo -e "\nRemoving rules from index $start_index to $end_index..."

            # List all the rich rules with indexes
            rules=$(run_firewall_cmd list)

            # Split rules into an array
            IFS=$'\n' read -r -d '' -a rule_array <<< "$rules"

            # Remove the selected range of rules
            for ((i = start_index - 1; i < end_index; i++)); do
                rule=${rule_array[$i]}
                if [[ -n "$rule" ]]; then
                    echo "Removing rule: $rule"
                    
                    # Extract the IP or range from the rule
                    ip_or_range=$(echo "$rule" | sed -n 's/.*source address="\([^"]*\)".*/\1/p')


                    # Remove the rule from the firewall
                    run_firewall_cmd remove "$rule"

                    # Remove the corresponding entry from the database
                    sqlite3 /www/server/panel/data/db/firewall.db \
                        "DELETE FROM firewall_ip WHERE address = '$ip_or_range';"

                    echo "Removed rule for $ip_or_range from both firewall and database."
                fi
            done

            # Reload the firewall to apply changes
            echo -e "\nReloading firewall..."
            run_firewall_cmd reload
            echo "Firewall rules updated successfully."
        else
            echo "Invalid range. The start index must be less than or equal to the end index."
        fi
    else
        echo "Invalid input. Please enter a valid range (e.g., 3-5)."
    fi
}

sync_firewall_ip_rules() {
    echo "Preparing to sync IP rules from firewall.db to firewalld..."

    # Get current rich rules
    current_rules=$(run_firewall_cmd list)

    # Query all IP rules from DB
    mapfile -t ip_entries < <(sqlite3 /www/server/panel/data/db/firewall.db \
        "SELECT types, address FROM firewall_ip WHERE address != ''")

    declare -a rules_to_add

    echo -e "\n== Candidate Rules to Add =="

    for entry in "${ip_entries[@]}"; do
        types=$(echo "$entry" | cut -d'|' -f1)
        ip=$(echo "$entry" | cut -d'|' -f2)

        [[ -z "$ip" ]] && continue

        # Determine action: drop or accept
        if [[ "$types" == "drop" ]]; then
            action="drop"
        else
            action="accept"
        fi

        rule="rule family=\"ipv4\" source address=\"$ip\" $action"

        # Check if rule already exists
        if ! grep -Fxq "$rule" <<< "$current_rules"; then
            echo "$rule"
            rules_to_add+=("$rule")
        fi
    done

    if [[ ${#rules_to_add[@]} -eq 0 ]]; then
        echo "✅ All IP rules from DB are already present in firewalld."
        return
    fi

    echo -e "\n${#rules_to_add[@]} rule(s) will be added. Continue? (y/n): "
    read -r confirm

    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        for rule in "${rules_to_add[@]}"; do
            echo "➕ Adding: $rule"
            run_firewall_cmd add "$rule"
        done

        echo -e "\nReloading firewall to apply changes..."
        run_firewall_cmd reload
        echo "✅ Sync complete. ${#rules_to_add[@]} rule(s) added."
    else
        echo "❌ Sync cancelled by user."
    fi
}


# Backup the firewall configuration
backup_firewall() {
    mkdir -p "$BACKUP_DIR"
    local filename="firewall_backup_$(date +%F_%H-%M-%S).txt"
    local fullpath="$BACKUP_DIR/$filename"
    echo "Backing up firewall config..."
    run_firewall_cmd backup > "$fullpath"
    echo "Backup saved to: $fullpath"
}


# Restore the firewall configuration from a backup
# restore_firewall() {
#     echo -e "\nAvailable backups:"
#     mapfile -t backups < <(ls -t "$BACKUP_DIR"/*.txt 2>/dev/null)

#     if [[ ${#backups[@]} -eq 0 ]]; then
#         echo "No backup files found."
#         return
#     fi

#     # Display numbered list
#     for i in "${!backups[@]}"; do
#         printf "%2d. %s\n" $((i+1)) "${backups[$i]}"
#     done
#     echo " 0. Return to menu"

#     # Prompt for input
#     echo -n "Enter number to view/restore backup: "
#     read -r index

#     if [[ "$index" == "0" ]]; then
#         return
#     fi

#     if [[ "$index" =~ ^[0-9]+$ && "$index" -ge 1 && "$index" -le ${#backups[@]} ]]; then
#         local selected="${backups[$((index-1))]}"
#         echo -e "\nSelected backup: $selected"
#         echo "Manual restoration required. Review the rules and apply as needed:"
#         echo "----------------------------------------------------"
#         cat "$selected"
#         echo "----------------------------------------------------"
#     else
#         echo "Invalid selection."
#     fi
# }

restore_firewall() {
    echo -e "\nAvailable backups:"
    mapfile -t backups < <(ls -t "$BACKUP_DIR"/*.txt 2>/dev/null)

    if [[ ${#backups[@]} -eq 0 ]]; then
        echo "No backup files found."
        return
    fi

    for i in "${!backups[@]}"; do
        printf "%2d. %s\n" $((i+1)) "${backups[$i]}"
    done
    echo " 0. Return to menu"

    echo -n "Enter number to view/restore backup: "
    read -r index

    if [[ "$index" == "0" ]]; then
        return
    fi

    if [[ "$index" =~ ^[0-9]+$ && "$index" -ge 1 && "$index" -le ${#backups[@]} ]]; then
        local selected="${backups[$((index-1))]}"
        echo -e "\nSelected backup: $selected"
        
        echo "Parsing ports and rich rules..."
        ports=$(grep -oP 'ports: \K.*' "$selected")
        mapfile -t rich_rules < <(grep -oP '^\s*rule.*' "$selected")

        echo -e "\nPorts in backup:\n  $ports"
        echo -e "\nRich rules in backup:"
        for rule in "${rich_rules[@]}"; do
            echo "  $rule"
        done

        echo -e "\nProceed to restore missing rules only? (y/n): "
        read -r confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            echo -e "\nChecking and restoring missing rich rules..."

            # Get current firewall rich rules
            current_rules=$(run_firewall_cmd list)

            for rule in "${rich_rules[@]}"; do
                if grep -Fxq "$rule" <<< "$current_rules"; then
                    echo "✓ Rule already exists: $rule"
                else
                    echo "➕ Adding rule: $rule"
                    run_firewall_cmd add "$rule"
                fi
            done

            echo -e "\nReloading firewall to apply changes..."
            run_firewall_cmd reload
            echo "Firewall restored successfully (only missing rules applied)."
        else
            echo "Restoration cancelled."
        fi
    else
        echo "Invalid selection."
    fi
}


show_top_programs() {
    echo "Showing top accessed programs/domains from logs..."

    local log_pattern
    if [[ $SERVER_TYPE == "nginx" ]]; then
        log_pattern="$LOG_DIR/*.log"
    else
        log_pattern="$LOG_DIR/*_log"
    fi

    echo -e "\n== Top Accessed Programs / Domains =="

    awk '{ 
        gsub(/\/www\/wwwlogs\//, "", FILENAME);
        gsub(/\.log$/, "", FILENAME);
        print $1, FILENAME 
    }' $log_pattern | sort | uniq -c | sort -nr | head -n 20
}

check_cc_defend_mode() {
    local btwaf_file="/www/server/btwaf/site.json"

    echo -e "\n== Checking CC-Defend Enhanced Mode Status (cc_mode) =="

    if [[ ! -f "$btwaf_file" ]]; then
        echo "Error: $btwaf_file not found."
        return 1
    fi

    # Detect available python executable
    PYTHON_CMD=""
    for cmd in python3 python py; do
        if command -v "$cmd" >/dev/null 2>&1; then
            PYTHON_CMD="$cmd"
            break
        fi
    done

    if [[ -z "$PYTHON_CMD" ]]; then
        echo "Error: No Python interpreter found."
        return 1
    fi

    # Show all site cc_mode values
    SITE_JSON="/www/server/btwaf/site.json"
    
    if [[ -s "$SITE_JSON" ]]; then
        if [[ $(grep -o '[^[:space:]]' "$SITE_JSON" | tr -d '\n') == '{}' ]]; then
            echo "⚠️  File is logically empty (contains only {})."
            return 1
        else
            "$PYTHON_CMD" -c 'import json, sys; d=json.load(open("'"$SITE_JSON"'")); [sys.stdout.write("%s: %s\n" % (k, v.get("cc_mode", ""))) for k,v in d.items()]' \
            | tee /tmp/btwaf_cc_mode_check.txt
        fi
    else
        echo "⚠️  File not found or is completely empty: $SITE_JSON"
        return 1
    fi




    # Check if any site is set to 4
    if grep -q ': 4' /tmp/btwaf_cc_mode_check.txt; then
        echo -e "\nSome sites are using Enhanced CC-Defend Mode (cc_mode = 4)."
        echo -n "Would you like to turn off Enhanced Mode for all (set to cc_mode = 1)? [y/N]: "
        read -r confirm

        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            "$PYTHON_CMD" -c '
import json
p = "/www/server/btwaf/site.json"
d = json.load(open(p))
for k in d:
    if d[k].get("cc_mode") == 4:
        d[k]["cc_mode"] = 1
json.dump(d, open(p, "w"), indent=4)
print("Updated all cc_mode 4 to 1.")
'
        else
            echo "No changes made."
        fi
    else
        echo "No site is currently using cc_mode = 4."
    fi
}

bytes_to_human() {
    local bytes=$1
    local kib=$((1024))
    local mib=$((1024 * kib))
    local gib=$((1024 * mib))
    local tib=$((1024 * gib))

    if (( bytes >= tib )); then
        printf "%.2f TiB" "$(bc -l <<< "$bytes/$tib")"
    elif (( bytes >= gib )); then
        printf "%.2f GiB" "$(bc -l <<< "$bytes/$gib")"
    elif (( bytes >= mib )); then
        printf "%.2f MiB" "$(bc -l <<< "$bytes/$mib")"
    elif (( bytes >= kib )); then
        printf "%.2f KiB" "$(bc -l <<< "$bytes/$kib")"
    else
        printf "%d B" "$bytes"
    fi
}


# get_net_usage() {
#     for iface in em{1..9}; do
#         stats=$(netstat -i | awk -v iface="$iface" '$1 == iface {print $3, $7}')
#         if [[ -n "$stats" ]]; then
#             read -r net_received net_sent <<< "$stats"
#             if [[ "$net_received" -ne 0 || "$net_sent" -ne 0 ]]; then
#                 # echo "Interface: $iface"
#                 # echo "Received: $net_received"
#                 # echo "Sent: $net_sent"
#                 return 0
#             fi
#         fi
#     done

#     echo "No active interface found among em1 to em9."
#     return 1
# }

# get_net_usage() {
#     # Get all interface names from netstat output except 'Iface' header and 'lo' (loopback)
#     interfaces=$(netstat -I | awk 'NR>2 && $1 != "lo" {print $1}')

#     for iface in $interfaces; do
#         stats=$(netstat -I "$iface" | awk 'NR==3 {print $4, $10}')  
#         # $4 = RX-OK, $10 = TX-OK from netstat -I iface output
#         if [[ -n "$stats" ]]; then
#             read -r net_received net_sent <<< "$stats"
#             if [[ "$net_received" -ne 0 || "$net_sent" -ne 0 ]]; then
#                 echo "Interface: $iface"
#                 echo "Received: $net_received"
#                 echo "Sent: $net_sent"
#                 return 0
#             fi
#         fi
#     done

#     net_received=0
#     net_sent=0
#     echo "No active interface found."
#     return 1
# }

get_net_usage() {
    # Read the netstat -i output skipping header (first 2 lines)
    # Columns: Iface MTU RX-OK RX-ERR RX-DRP RX-OVR TX-OK TX-ERR TX-DRP TX-OVR Flg
    while read -r iface mtu rx_ok rx_err rx_drp rx_ovr tx_ok tx_err tx_drp tx_ovr flags; do
        # Skip the header lines
        [[ "$iface" == "Iface" ]] && continue
        [[ -z "$iface" ]] && continue
        [[ "$iface" == "lo" ]] && continue  # skip loopback

        if (( rx_ok > 0 || tx_ok > 0 )); then
            net_received=$rx_ok
            net_sent=$tx_ok
            # echo "Interface: $iface"
            # echo "Received: $net_received"
            # echo "Sent: $net_sent"
            return 0
        fi
    done < <(netstat -i)

    net_received=0
    net_sent=0
    echo "No active interface found."
    return 1
}

get_net_state() {

    # # Detect active interface (exclude loopback and down interfaces)
    # IFACE=$(ip -o link show | awk -F': ' '{print $2}' | grep -v '^lo$' | while read i; do
    #     RX=$(cat /sys/class/net/$i/statistics/rx_bytes)
    #     TX=$(cat /sys/class/net/$i/statistics/tx_bytes)
    #     [[ $RX -gt 0 || $TX -gt 0 ]] && echo "$i" && break
    # done)
    
    # if [[ -z "$IFACE" ]]; then
    #     echo "No active network interface found."
    #     # exit 1
    # fi
    
    # Detect active (non-loopback, with traffic) interface without using `ip`
    IFACE=$(ls /sys/class/net | grep -v '^lo$' | while read i; do
        # Skip interfaces that are down
        if [[ ! -d "/sys/class/net/$i" || ! -e "/sys/class/net/$i/operstate" ]]; then
            continue
        fi
    
        STATE=$(cat /sys/class/net/$i/operstate)
        RX=$(cat /sys/class/net/$i/statistics/rx_bytes)
        TX=$(cat /sys/class/net/$i/statistics/tx_bytes)
    
        if [[ "$STATE" == "up" && ( $RX -gt 0 || $TX -gt 0 ) ]]; then
            echo "$i"
            break
        fi
    done)
    
    if [[ -z "$IFACE" ]]; then
        echo "❌ No active interface found."
    # else
        # echo "✅ Active interface: $IFACE"
    fi
    
    # Read RX/TX before sleep
    RX1=$(cat /sys/class/net/$IFACE/statistics/rx_bytes)
    TX1=$(cat /sys/class/net/$IFACE/statistics/tx_bytes)
    sleep 1
    # Read RX/TX after 1 second
    RX2=$(cat /sys/class/net/$IFACE/statistics/rx_bytes)
    TX2=$(cat /sys/class/net/$IFACE/statistics/tx_bytes)
    
    # Calculate difference in KB
    RX_RATE=$(( (RX2 - RX1) / 1024 ))
    TX_RATE=$(( (TX2 - TX1) / 1024 ))
    
    # echo "Interface: $IFACE"
    # echo "Inbound : $RX_RATE KB/s"
    # echo "Outbound: $TX_RATE KB/s"

}

# Function to strip ANSI color codes
strip_ansi() {
    echo -e "$1" | sed -r 's/\x1B\[[0-9;]*[mK]//g'
}

# Print line aligned to width, compensating for ANSI colors
# print_line() {
#     local raw="$1"
#     local stripped=$(strip_ansi "$raw")
#     local visible_length=${#stripped}
#     local padding=$((width - 3 - visible_length))
#     printf "│ %s%*s│\n" "$raw" "$padding" ""
# }

# print_line() {
#     local label="$1"
#     local value="$2"
#     printf "│ %-22s : %-51s │\n" "$label" "$value"
# }


get_disk_io() {
    local dev="$1"
    local read1 write1 read2 write2

    read1=$(awk -v dev=$dev '$3 == dev {print $6}' /proc/diskstats)
    write1=$(awk -v dev=$dev '$3 == dev {print $10}' /proc/diskstats)
    sleep 1
    read2=$(awk -v dev=$dev '$3 == dev {print $6}' /proc/diskstats)
    write2=$(awk -v dev=$dev '$3 == dev {print $10}' /proc/diskstats)

    local read_kBps=$(( (read2 - read1) * 512 / 1024 ))
    local write_kBps=$(( (write2 - write1) * 512 / 1024 ))
    
    disk_read=$read_kBps
    disk_write=$write_kBps

    # echo "$dev - Read: ${read_kBps} kB/s, Write: ${write_kBps} kB/s"
}


print_menu_header() {
    local width=$(tput cols)
    local title="Server Maintenance Menu"
    # local server_line="Detected Server: $SERVER_TYPE"
    # Detect OS Name
    local os_name="Unknown OS"
    if [ -f /etc/os-release ]; then
        os_name=$(awk -F= '/^PRETTY_NAME/{gsub(/"/, "", $2); print $2}' /etc/os-release)
    elif [ -f /etc/redhat-release ]; then
        os_name=$(cat /etc/redhat-release)
    elif [ -f /etc/debian_version ]; then
        os_name="Debian $(cat /etc/debian_version)"
    fi
    local server_line="Web Server: $SERVER_TYPE  |  OS: $os_name"

    # Limit max width for consistency
    (( width > 80 )) && width=80

    # Build the border
    local border_line=$(printf '─%.0s' $(seq 1 $((width - 2))))
    local title_padding=$(( (width - 2 - ${#title}) / 2 ))
    local padded_title=$(printf "%*s%s%*s" "$title_padding" "" "$title" "$((width - 3 - title_padding - ${#title}))" "")

    # Detect Python version
    local python_ver
    if command -v python3 &>/dev/null; then
        python_ver="$(python3 --version 2>&1)"
    elif command -v python &>/dev/null; then
        python_ver="$(python --version 2>&1)"
    else
        python_ver="Not found"
    fi

    # Detect PHP version
    local php_ver
    php_ver=$(php -v 2>/dev/null | head -n 1 || echo "PHP: Not found")

    # CPU usage
    local cpu_usage
    cpu_usage=$(top -bn1 | awk '/%Cpu/{print 100 - $8}' | awk '{printf "%.1f", $1}')

    local cpu_color="\e[0m"
    (( ${cpu_usage%.*} >= 90 )) && cpu_color="\e[31m"
    (( ${cpu_usage%.*} >= 80 && ${cpu_usage%.*} < 90 )) && cpu_color="\e[33m"

    # Memory usage
    read total used <<< $(free -m | awk '/Mem:/ {print $2, $3}')
    local mem_perc=$(( used * 100 / total ))
    local mem_color="\e[0m"
    (( mem_perc >= 90 )) && mem_color="\e[31m"
    (( mem_perc >= 80 && mem_perc < 90 )) && mem_color="\e[33m"

    # Disk info
    local root_used root_total root_perc home_used home_total home_perc
    read root_used root_total root_perc <<< $(df -h / | awk 'NR==2 {print $3, $2, $5}')
    read home_used home_total home_perc <<< $(df -h /home 2>/dev/null | awk 'NR==2 {print $3, $2, $5}')
    [[ -z "$home_used" ]] && home_used="-" && home_total="-" && home_perc="-"

    root_perc_val=${root_perc%\%}
    home_perc_val=${home_perc%\%}

    local root_color="\e[0m"
    (( root_perc_val >= 90 )) && root_color="\e[31m"
    (( root_perc_val >= 80 && root_perc_val < 90 )) && root_color="\e[33m"

    local home_color="\e[0m"
    (( home_perc_val >= 90 )) && home_color="\e[31m"
    (( home_perc_val >= 80 && home_perc_val < 90 )) && home_color="\e[33m"

    # Disk I/O stats (taking from sda device)
    # local disk_read disk_write
    # disk_read=$(iostat -dx sda | awk 'NR==4 {print $6}')   # rkB/s
    # disk_write=$(iostat -dx sda | awk 'NR==4 {print $7}')  # wkB/s
    
    get_disk_io sda

    # Uptime and load averages
    local uptime_info load_avg
    uptime_info=$(uptime -p)  # e.g., "up 2 days, 4 hours"
    load_avg=$(uptime | awk -F'load average: ' '{print $2}')  # e.g., "0.12, 0.34, 0.56"
    # Get number of CPU cores
    core_count=$(nproc)
   
    # Extract load values
    IFS=',' read -r load1 load5 load15 <<< "$load_avg"
    load1=$(echo "$load1" | xargs)      # trim spaces
    load5=$(echo "$load5" | xargs)
    load15=$(echo "$load15" | xargs)
   
    # Convert to float for comparison
    status="Normal"
    color="\e[0m"
   
    if (( $(echo "$load15 > $core_count * 1.5" | bc -l) )); then
        status="🔴 HIGH"
        color="\e[31m"
    elif (( $(echo "$load15 > $core_count" | bc -l) )); then
        status="🟠 Elevated"
        color="\e[33m"
    else
        status="🟢 Normal"
        color="\e[32m"
    fi
    
    # load_perc=$(printf "%.1f", $(bc -l <<< "($load15/$core_count) * 100"))
   
    # Final human-readable string
    # load_display="${color}Load Avg: ${load1} (1m), ${load5} (5m), ${load15} (15m)  [Cores: ${core_count}, Status: ${status}]\e[0m"
    load_display="${color}${load1} (1m), ${load15} (15m) [Cores: ${core_count}, Status: ${status}]\e[0m"


    # Network stats (using RX-OK and TX-OK)
    # local net_sent net_received
    # Try to get from em1
    # net_sent=$(netstat -i | awk '$1=="em1" {print $7}')
    # net_received=$(netstat -i | awk '$1=="em1" {print $3}')
    
    # If values are empty or zero, fallback to lo
    # if [[ -z "$net_sent" || "$net_sent" == "0" ]] && [[ -z "$net_received" || "$net_received" == "0" ]]; then
    #     net_sent=$(netstat -i | awk '$1=="lo" {print $7}')
    #     net_received=$(netstat -i | awk '$1=="lo" {print $3}')
    # fi
    
    # get_net_usage
   
    # Convert network stats to human-readable
    # net_sent_hr=$(bytes_to_human "$net_sent")
    # net_received_hr=$(bytes_to_human "$net_received")

    get_net_state

    # Swap usage
    local swap_total swap_used
    read swap_total swap_used <<< $(free -m | awk '/Swap:/ {print $2, $3}')
    swap_perc=$(awk "BEGIN { printf \"%.1f\", ($swap_used / $swap_total) * 100 }")
   
    swap_color="\e[0m"
    if (( $(echo "$swap_perc >= 90" | bc -l) )); then
        swap_color="\e[31m"  # red
    elif (( $(echo "$swap_perc >= 80" | bc -l) )); then
        swap_color="\e[33m"  # yellow/darkorange
    fi


   
    # Print the menu box
        # Box drawing
    # echo -e "\e[36m┌$border_line┐"
    # print_line "📋 $padded_title" ""
    # echo -e "├$border_line┤\e[0m"
   
    echo -e "\e[36m┌$border_line┐"
    print_line "📋  $title" ""
    echo -e "├$border_line┤\e[0m"
   
    print_line "⏳  Uptime" "$uptime_info"
    print_line "🖥️  Server Type" "$server_line"
    print_line "🐍  Python Version" "$python_ver"
    print_line "💻  PHP Version" "$php_ver"

    # 🔹 Subsection break line (matches box width)
    echo -e "\e[36m├$border_line┤\e[0m"

    print_line "📉  Load Avg" "$(echo -e "$load_display")"
    print_line "⚡  CPU Usage" "$(echo -e "${cpu_color}${cpu_usage}%\e[0m")"
    print_line "🧠  Memory Usage" "$(echo -e "${mem_color}${mem_perc}% (${used}M/${total}M)\e[0m")"
    print_line "💾  Root Disk" "$(echo -e "${root_color}${root_used} / ${root_total} (${root_perc})\e[0m")"
    print_line "📂  Home Disk" "$(echo -e "${home_color}${home_used} / ${home_total} (${home_perc})\e[0m")"
    
    
    print_line "📚  Disk Read" "$disk_read KB/s"
    print_line "📖  Disk Write" "$disk_write KB/s"
    # print_line "📤  Net Sent" "$net_sent_hr [TX]"
    # print_line "📥  Net Received" "$net_received_hr [RX]"
    print_line "⬇️  Inbound" "$RX_RATE KB/s"
    print_line "⬆️  Outbound" "$TX_RATE KB/s"
    
    print_line "💤  Swap Usage" "$(echo -e "${swap_color}${swap_used} / ${swap_total} MB (${swap_perc}%)\e[0m")"
   
    echo -e "\e[36m└$border_line┘\e[0m"


}

print_line() {
    local label="$1"
    local value="$2"
    local total_width=$(($(tput cols) - 2))
    [[ $total_width -gt 80 ]] && total_width=78

    local label_width=24
    local value_width=$((total_width - label_width - 1))

    # Calculate visible length of label (without ANSI codes)
    local visible_label_length=$(strip_ansi "$label" | wc -m)

    if [[ -z "$value" ]]; then
        # Title line
        local title_length=$(strip_ansi "$label" | wc -m)
        local padding_left=$(( (total_width - title_length) / 2 ))
        local padding_right=$(( total_width - title_length - padding_left + 1 ))
        printf "\e[36m│%*s%s%*s\e[0m\n" $padding_left "" "$label" $padding_right ""
    else
        # Label and Value line
        printf "\e[36m│ %-${label_width}s: %-${value_width}s \e[0m\n" "$label" "$value"
    fi
}

# Function to strip ANSI color codes
strip_ansi() {
    echo -e "$1" | sed -r 's/\x1B\[[0-9;]*[mK]//g'
}

# print_line() {
#     local label="$1"
#     local value="$2"
#     local total_width=$(($(tput cols) - 2))  # Total width inside the box
#     [[ $total_width -gt 80 ]] && total_width=78 #max box width 80

#     local label_width=24 # Set a fixed width for the label column
#     local value_width=$((total_width - label_width - 3)) # Width for the value column

#     if [[ -z "$value" ]]; then
#         # Title line — center it
#         local title_length=${#label}
#         local padding_left=$(( (total_width - title_length) / 2 ))
#         local padding_right=$(( total_width - title_length - padding_left ))
#         printf "\e[36m│%*s%s%*s│\e[0m\n" $padding_left "" "$label" $padding_right ""
#     else
#         # Normal label + value line with fixed width columns
#         printf "\e[36m│ %-${label_width}s: %-${value_width}s │\e[0m\n" "$label" "$value"
#     fi
# }

# print_line() {
#     local label="$1"
#     local value="$2"
#     local total_width=${#border_line}  # total width inside the box

#     if [[ -z "$value" ]]; then
#         # Title line — center it
#         local title_length=${#label}
#         local padding_left=$(( (total_width - title_length) / 2 ))
#         local padding_right=$(( total_width - title_length - padding_left ))
#         printf "\e[36m│%*s%s%*s│\e[0m\n" $padding_left "" "$label" $padding_right ""
#     else
#         # Normal label + value line
#         local line=" $label: $value"
#         local line_length=${#line}
#         local padding=$(( total_width - line_length ))
#         printf "\e[36m│%s%*s│\e[0m\n" "$line" $padding ""
#     fi
# }

show_htop() {
    if ! command -v htop >/dev/null 2>&1; then
        echo "htop is not installed."

        read -p "Do you want to install htop? [y/N]: " confirm
        confirm=${confirm,,}  # convert to lowercase

        if [[ "$confirm" != "y" && "$confirm" != "yes" ]]; then
            echo "Skipping htop installation."
            return
        fi

        echo "Installing htop..."

        if [ -f /etc/redhat-release ]; then
            echo "Detected CentOS/RHEL. Installing with yum..."
            sudo yum install htop -y
        elif [ -f /etc/debian_version ]; then
            echo "Detected Debian/Ubuntu. Installing with apt..."
            sudo apt update && sudo apt install htop -y
        else
            echo "Unknown OS. Please install htop manually."
            return
        fi
    fi

    htop
}


restart_web_server() {
    if [[ $SERVER_TYPE == "nginx" ]]; then
        echo "Restarting nginx..."
        systemctl restart nginx
        sleep 15
        if ! systemctl is-active --quiet nginx; then
            echo "Nginx restart failed. Attempting to start nginx..."
            systemctl start nginx
        fi
        systemctl status nginx | grep Active
        service nginx status

    elif [[ $SERVER_TYPE == "apache" ]]; then
        echo "Restarting apache..."
        systemctl restart httpd || systemctl restart apache2
        sleep 15
        if ! systemctl is-active --quiet httpd && ! systemctl is-active --quiet apache2; then
            echo "Apache restart failed. Attempting to start apache..."
            systemctl start httpd || systemctl start apache2
        fi
        systemctl status httpd | grep Active || systemctl status apache2 | grep Active
        service httpd status|| service apache2 status
    else 
        echo "Try to start any web server"
        
        systemctl start nginx || systemctl start httpd || systemctl start apache2
    fi
}

restart_php() {
    echo "Restarting php..."
    systemctl restart php-fpm-74 || systemctl restart php-fpm-72
    systemctl status php-fpm-74 || systemctl status php-fpm-72
}

restart_mysql() {
    echo "Restarting mysql..."
    systemctl restart mysql
    systemctl status mysql
}

show_top_processes() {
    ps aux --sort=-%$1 | head -n 10
}

main_menu() {
    # Output
    echo "----------------------------------------------------"
    echo "Panel Title: $TITLE"
    echo "Server IP: $SERVER_IP"
    detect_server_type
    # echo "┌───────────────────────────────────────────────────────┐"
    # echo "│               Server Maintenance Menu                 │"
    # echo "├───────────────────────────────────────────────────────┤"
    # echo "│ Detected Server: $(printf "%-42s" "$SERVER_TYPE") │"
    # echo "└───────────────────────────────────────────────────────┘"
    print_menu_header

   echo -e "\nMenu:"
    echo "1. Clean logs"
    echo "2. Analyze logs"
    echo "3. Block suspicious IPs"
    echo "4. Backup firewall config"
    echo "5. Restore firewall config"
    echo "6. Edit firewall IP rules"
    # echo "7. Show top programs/domains"
    echo "7. Sync firewall IP rules/domains"
    echo "8. Check/Toggle CC-Defend Enhanced Mode"
    echo "9. Restart Web Server"
    echo "10. Restart PHP"
    echo "11. Restart MySQL"
    echo "12. Show 'top'"
    echo "13. Show 'htop'"
    echo "14. Show 'netstat'"
    echo "15. Show top 10 CPU usage processes"
    echo "16. Show top 10 MEM usage processes"
    echo "0. Exit"
    echo -n "Choose an option: "
    read -r choice
    
    case "$choice" in
        1) clean_logs ;;
        2) analyze_logs ;;
        3) block_ip ;;
        4) backup_firewall ;;
        5) restore_firewall ;;
        6) edit_firewall_ip_rules ;;
        # 7) show_top_programs ;;
        7) sync_firewall_ip_rules ;;
        8) check_cc_defend_mode ;;
        9) restart_web_server ;;
        10) restart_php ;;
        11) restart_mysql ;;
        12) top ;;
        13) show_htop ;;
        14) netstat ;;
        15) show_top_processes cpu ;;
        15) show_top_processes mem ;;
        0) exit 0 ;;
        *) echo "Invalid option" ;;
    esac

}

check_and_load_btwaf_whitelist  # Loads WHITELISTED_IPS array

# Main loop for the menu
while true; do
    main_menu
done
