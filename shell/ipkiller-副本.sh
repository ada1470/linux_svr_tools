#!/bin/bash

# Configurable Variables
TOP_IP_COUNT=200  # Number of top IPs to analyze, change as needed (e.g., 20, 50, 200, 500)
TOP_IP_ANALYSE=10
TOP_RANGE_COUNT=20

LOG_DIR="/www/wwwlogs"
BACKUP_DIR="/home/www/backup/firewall"
SPIDER_WHITELIST_REGEX="baiduspider|sogouspider|bytespider|shenmaspider|hn.kd.ny.adsl|petal"
TMP_IP_LIST="/tmp/top_ips.txt"
# Temp files for storing annotated IPs and ranges
IPS_TO_BLOCK_FILE="/tmp/ips_to_block.txt"
RANGES_TO_BLOCK_FILE="/tmp/ranges_to_block.txt"

# Function to detect the server type (nginx or apache)
detect_server_type() {
    if pgrep -x "nginx" >/dev/null; then
        SERVER_TYPE="nginx"
    elif pgrep -x "httpd" >/dev/null || pgrep -x "apache2" >/dev/null; then
        SERVER_TYPE="apache"
    else
        echo "Unable to detect server type."
        exit 1
    fi
}

# Function to clean logs
clean_logs() {
    echo "Cleaning logs..."
    find "$LOG_DIR" -maxdepth 1 -type f \( -name "*.log" -o -name "*_log" \) -exec rm -v {} \;

    if [[ $SERVER_TYPE == "nginx" ]]; then
        echo "Restarting nginx..."
        systemctl restart nginx
        sleep 2
        if ! systemctl is-active --quiet nginx; then
            echo "Nginx restart failed. Attempting to start nginx..."
            systemctl start nginx
        fi

    elif [[ $SERVER_TYPE == "apache" ]]; then
        echo "Restarting apache..."
        systemctl restart httpd || systemctl restart apache2
        sleep 2
        if ! systemctl is-active --quiet httpd && ! systemctl is-active --quiet apache2; then
            echo "Apache restart failed. Attempting to start apache..."
            systemctl start httpd || systemctl start apache2
        fi
    fi
}


# Function to analyze logs and generate the list of top IPs and ranges
analyze_logs() {
     echo "Analyzing logs for $SERVER_TYPE..."

    # Clear previous data
    > "$IPS_TO_BLOCK_FILE"
    > "$RANGES_TO_BLOCK_FILE"
    
    
    if [[ $SERVER_TYPE == "nginx" ]]; then
        awk '{ print $1 }' "$LOG_DIR"/*.log | sort | uniq -c | sort -nr | head -n "$TOP_IP_COUNT" > "$TMP_IP_LIST"
    else
        awk '{ print $1 }' "$LOG_DIR"/*_log | sort | uniq -c | sort -nr | head -n "$TOP_IP_COUNT" > "$TMP_IP_LIST"
    fi
    
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
}

annotate_ip() {
    local ip="$1"
    local count="$2"
    local annotation=""

    if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        # local host_info=$(getent hosts "$ip" | grep -E "$SPIDER_WHITELIST_REGEX")

        # if [[ -n "$host_info" ]]; then
            # annotation=$(echo "$host_info" | grep -Eo "$SPIDER_WHITELIST_REGEX" | head -n 1)
            # annotation="$annotation (whitelisted spider)"
        if host_info=$(getent hosts "$ip"); then
            if echo "$host_info" | grep -Eiq "$SPIDER_WHITELIST_REGEX"; then
                annotation=$(echo "$host_info" | grep -Eo "$SPIDER_WHITELIST_REGEX" | head -n 1)
                annotation="$annotation (whitelisted spider)"
            else
                domain=$(echo "$host_info" | awk '{print $2}')
                annotation="$domain (unlisted spider)"
            fi

        else
            local range=$(echo "$ip" | sed -E 's#([0-9]+\.[0-9]+\.[0-9]+)\.[0-9]+#\1.0/24#')
            if firewall-cmd --list-rich-rules | grep -qE "$ip|$range"; then
                annotation="firewall whitelist"
            else
                annotation="UNKNOWN"
            fi
        fi

        echo "$count - $ip => $annotation" | tee -a "$IPS_TO_BLOCK_FILE"

    else
        local ip_base=$(echo "$ip" | cut -d'/' -f1 | cut -d. -f1-3)
        local sample_ip="$ip_base.1"
        annotation="UNKNOWN"

        if host_entry=$(getent hosts "$sample_ip"); then
            if echo "$host_entry" | grep -Eiq "$SPIDER_WHITELIST_REGEX"; then
                spider_name=$(echo "$host_entry" | grep -Eio "$SPIDER_WHITELIST_REGEX" | head -n 1)
                annotation="$spider_name (spider whitelist)"
            else
                # Extract the domain name for annotation
                domain=$(echo "$host_entry" | awk '{print $2}')
                annotation="$domain (unlisted spider)"
            fi
        elif firewall-cmd --list-rich-rules | grep -Eq "$ip"; then
            annotation="firewall whitelist"
        fi


        echo "$ip => $annotation" | tee -a "$RANGES_TO_BLOCK_FILE"
    fi
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
        ip=$(echo "$line" | awk '{print $3}')  # Corrected: $3 for the IP
        annotation=$(echo "$line" | awk '{print $NF}')

        if [[ "$annotation" == "UNKNOWN" || "$annotation" == *"unlisted spider"* ]]; then
            ips_to_block+=("$ip")
        fi
    done < "$IPS_TO_BLOCK_FILE"

    # Collect IP ranges from the file with annotation "UNKNOWN" or "unlisted spider"
    echo -e "\n== Collecting Annotated IP Ranges to Block =="

    while read -r range; do
        ip_base=$(echo "$range" | cut -d' ' -f1)
        annotation=$(echo "$range" | awk '{print $NF}')

        if [[ "$annotation" == "UNKNOWN" || "$annotation" == *"unlisted spider"* ]]; then
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
                firewall-cmd --permanent --add-rich-rule="rule family='ipv4' source address='$ip' drop"

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
                firewall-cmd --permanent --add-rich-rule="rule family='ipv4' source address='$range' drop"

                # Add to the firewall_ip table with the current timestamp
                sqlite3 /www/server/panel/data/db/firewall.db \
                    "INSERT INTO firewall_ip (types, address, brief, addtime, chain) VALUES ('drop', '$range', 'Blocked by script', strftime('%Y-%m-%d %H:%M:%S', 'now'), 'INPUT');"

                echo "Successfully blocked $range and logged in database."
            done
        fi
    fi

    # Reload firewall to apply changes
    echo -e "\nReloading firewall..."
    firewall-cmd --reload
}



# edit_firewall_ip_rules() {
#     echo "Editing firewall IP rules..."

#     # Show the current list of firewall rules with indexes
#     echo -e "\n== Current Firewall IP Rules =="
#     firewall-cmd --list-rich-rules | nl -s '. '

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
#             rules=$(firewall-cmd --list-rich-rules)

#             # Split rules into an array
#             IFS=$'\n' read -r -d '' -a rule_array <<< "$rules"

#             # Remove the selected range of rules
#             for ((i = start_index - 1; i < end_index; i++)); do
#                 rule=${rule_array[$i]}
#                 if [[ -n "$rule" ]]; then
#                     echo "Removing rule: $rule"
#                     firewall-cmd --permanent --remove-rich-rule="$rule"
#                 fi
#             done

#             # Reload the firewall to apply changes
#             echo -e "\nReloading firewall..."
#             firewall-cmd --reload
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
    firewall-cmd --list-rich-rules | nl -s '. '

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
            rules=$(firewall-cmd --list-rich-rules)

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
                    firewall-cmd --permanent --remove-rich-rule="$rule"

                    # Remove the corresponding entry from the database
                    sqlite3 /www/server/panel/data/db/firewall.db \
                        "DELETE FROM firewall_ip WHERE address = '$ip_or_range';"

                    echo "Removed rule for $ip_or_range from both firewall and database."
                fi
            done

            # Reload the firewall to apply changes
            echo -e "\nReloading firewall..."
            firewall-cmd --reload
            echo "Firewall rules updated successfully."
        else
            echo "Invalid range. The start index must be less than or equal to the end index."
        fi
    else
        echo "Invalid input. Please enter a valid range (e.g., 3-5)."
    fi
}


# Backup the firewall configuration
backup_firewall() {
    mkdir -p "$BACKUP_DIR"
    local filename="firewall_backup_$(date +%F_%H-%M-%S).txt"
    local fullpath="$BACKUP_DIR/$filename"
    echo "Backing up firewall config..."
    firewall-cmd --list-all > "$fullpath"
    echo "Backup saved to: $fullpath"
}


# Restore the firewall configuration from a backup
restore_firewall() {
    echo -e "\nAvailable backups:"
    mapfile -t backups < <(ls -t "$BACKUP_DIR"/*.txt 2>/dev/null)

    if [[ ${#backups[@]} -eq 0 ]]; then
        echo "No backup files found."
        return
    fi

    # Display numbered list
    for i in "${!backups[@]}"; do
        printf "%2d. %s\n" $((i+1)) "${backups[$i]}"
    done
    echo " 0. Return to menu"

    # Prompt for input
    echo -n "Enter number to view/restore backup: "
    read -r index

    if [[ "$index" == "0" ]]; then
        return
    fi

    if [[ "$index" =~ ^[0-9]+$ && "$index" -ge 1 && "$index" -le ${#backups[@]} ]]; then
        local selected="${backups[$((index-1))]}"
        echo -e "\nSelected backup: $selected"
        echo "Manual restoration required. Review the rules and apply as needed:"
        echo "----------------------------------------------------"
        cat "$selected"
        echo "----------------------------------------------------"
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
    "$PYTHON_CMD" -c '
import json
data = json.load(open("/www/server/btwaf/site.json"))
for site, config in data.items():
    print(f"{site}: {config.get(\"cc_mode\", \"\")}")
' | tee /tmp/btwaf_cc_mode_check.txt

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

# Function to strip ANSI color codes
strip_ansi() {
    echo -e "$1" | sed -r 's/\x1B\[[0-9;]*[mK]//g'
}

# Print line aligned to width, compensating for ANSI colors
print_line() {
    local raw="$1"
    local stripped=$(strip_ansi "$raw")
    local visible_length=${#stripped}
    local padding=$((width - 3 - visible_length))
    printf "│ %s%*s│\n" "$raw" "$padding" ""
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
    local server_line="Detected Server: $SERVER_TYPE  |  OS: $os_name"

    # Limit max width for consistency
    (( width > 80 )) && width=80

    # Build the border
    local border_line=$(printf '─%.0s' $(seq 1 $((width - 2))))
    local title_padding=$(( (width - 2 - ${#title}) / 2 ))
    local padded_title=$(printf "%*s%s%*s" "$title_padding" "" "$title" "$((width - 3 - title_padding - ${#title}))" "")

    # Detect Python version
    local python_ver
    if command -v python3 &>/dev/null; then
        python_ver="Python $(python3 --version 2>&1)"
    elif command -v python &>/dev/null; then
        python_ver="Python $(python --version 2>&1)"
    else
        python_ver="Python: Not found"
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
    local disk_read disk_write
    disk_read=$(iostat -dx sda | awk 'NR==4 {print $6}')   # rkB/s
    disk_write=$(iostat -dx sda | awk 'NR==4 {print $7}')  # wkB/s

    # Uptime and load averages
    local uptime_info load_avg
    uptime_info=$(uptime -p)  # e.g., "up 2 days, 4 hours"
    load_avg=$(uptime | awk -F'load average: ' '{print $2}')  # e.g., "0.12, 0.34, 0.56"
    # Get number of CPU cores
    core_count=$(nproc)
    
    # Extract load values
    IFS=',' read -r load1 load5 load15 <<< "$load_avg"
    load1=$(echo "$load1" | xargs)     # trim spaces
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
    
    # Final human-readable string
    load_display="${color}Load Avg: ${load1} (1m), ${load5} (5m), ${load15} (15m)  [Cores: ${core_count}, Status: ${status}]\e[0m"


    # Network stats (using RX-OK and TX-OK)
    local net_sent net_received
    net_sent=$(netstat -i | grep -E '^em1[[:space:]]' | awk '{print $7}')
    net_received=$(netstat -i | grep -E '^em1[[:space:]]' | awk '{print $3}')
    
    # Convert network stats to human-readable
    net_sent_hr=$(bytes_to_human "$net_sent")
    net_received_hr=$(bytes_to_human "$net_received")

   

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
    echo -e "\e[36m┌$border_line┐"
    print_line "$padded_title"
    echo -e "├$border_line┤\e[0m"
    print_line "$server_line"
    print_line "$python_ver"
    print_line "$php_ver"
    print_line "$(echo -e "${cpu_color}CPU Usage: $cpu_usage%\e[0m")"
    print_line "$(echo -e "${mem_color}Memory: ${mem_perc}% (${used}M/${total}M)\e[0m")"
    print_line "$(echo -e "${root_color}Root Disk: $root_used / $root_total ($root_perc)\e[0m")"
    print_line "$(echo -e "${home_color}Home Disk: $home_used / $home_total ($home_perc)\e[0m")"
    print_line "Uptime: $uptime_info"
    # print_line "Load Avg: $load_avg"
    print_line "$(echo -e "$load_display")"
    print_line "Disk Read: $disk_read KB/s"
    print_line "Disk Write: $disk_write KB/s"
    print_line "Network Sent: $net_sent_hr [TX since boot]"
    print_line "Network Received: $net_received_hr [RX since boot]"
    print_line "$(echo -e "${swap_color}Swap Usage: $swap_used / $swap_total MB (${swap_perc}%)\e[0m")"
    echo -e "\e[36m└$border_line┘\e[0m"


}


show_htop() {
    if ! command -v htop >/dev/null 2>&1; then
        echo "htop not found. Installing..."

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



main_menu() {
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
    echo "7. Show top programs/domains"
    echo "8. Check/Toggle CC-Defend Enhanced Mode"
    echo "9. Restart Web Server & Check Status"
    echo "10. Restart PHP"
    echo "11. Restart MySQL"
    echo "12. Show 'top'"
    echo "13. Show 'htop'"
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
        7) show_top_programs ;;
        8) check_cc_defend_mode ;;
        9) restart_web_server ;;
        10) restart_php ;;
        11) restart_mysql ;;
        12) top ;;
        13) show_htop ;;
        0) exit 0 ;;
        *) echo "Invalid option" ;;
    esac

}


# Main loop for the menu
while true; do
    main_menu
done
