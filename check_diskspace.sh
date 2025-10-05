#!/bin/bash

# Color codes
RESET="\033[0m"
ORANGE="\033[38;5;214m"
RED="\033[1;31m"
YELLOW="\033[1;33m"
BOLD="\033[1m"

# Paths to check
paths=(
    "/www/wwwlogs"
    "/www/server/total/logs"
    "/.Recycle_bin"
    "/www/server/disk_analysis/data"
    "/www/server/disk_analysis/scan"
    "/www/wwwlogs/btwaf"
    "/www/server/btwaf/drop_ip.log"
    "/www/server/btwaf/totla_db/"
    "/www/backup/panel"
    "/www/server/panel/logs"
    "/www/server/monitor/data/dbs"
    "/www/server/data/HK2203.err"
    "/www/server/data/mysql-slow.log"
    "/var/log/"
    "/run/log/journal"
    "/www/server/panel/data/ssh"
    "/usr/local/usranalyse/logs/log"
)

echo -e "${BOLD}Checking directory sizes...${RESET}"
total_size=0
largest_size=0
largest_path=""
declare -A dir_sizes

# Check sizes
for path in "${paths[@]}"; do
    if [ -e "$path" ]; then
        size=$(du -sb "$path" 2>/dev/null | awk '{print $1}')
        size_gb=$(echo "$size / 1073741824" | bc -l)
        dir_sizes["$path"]=$size

        color="$RESET"
        if (( $(echo "$size_gb > 10" | bc -l) )); then
            color=$RED
        elif (( $(echo "$size_gb > 1" | bc -l) )); then
            color=$ORANGE
        fi

        printf "${color}%-50s : %.2f GB${RESET}\n" "$path" "$size_gb"

        total_size=$((total_size + size))
        if [ "$size" -gt "$largest_size" ]; then
            largest_size=$size
            largest_path=$path
        fi
    else
        echo -e "${YELLOW}$path : [Not Found]${RESET}"
    fi
done

total_size_gb=$(echo "$total_size / 1073741824" | bc -l)
largest_size_gb=$(echo "$largest_size / 1073741824" | bc -l)

echo "------------------------------------------------------------"
echo -e "${BOLD}TOTAL SIZE:${RESET} ${total_size_gb} GB"
echo -e "${BOLD}LARGEST:${RESET} ${largest_path} (${largest_size_gb} GB)"

# Alert if /www/backup/panel is not empty
if [ -d "/www/backup/panel" ] && [ "$(ls -A /www/backup/panel 2>/dev/null)" ]; then
    echo -e "${YELLOW}⚠️ [WARNING] /www/backup/panel is not empty."
    echo -e "Please change Baota backup path to: /home/www/backup/panel${RESET}"
fi

# If total < 50GB, ask to scan /
threshold=$((50 * 1073741824))
if [ "$total_size" -lt "$threshold" ]; then
    read -p "Total is below 50GB. Do you want to scan / (exclude /proc /home)? [y/N]: " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        echo "Scanning / (excluding /proc /home)..."
        du -h --max-depth=1 --exclude=/proc --exclude=/home / | \
            awk '$1 ~ /[0-9\.]+[G]/ {print}' | \
            sort -hr
    else
        echo "Scan aborted by user."
    fi
fi

# Collect dirs >1GB
echo
echo -e "${BOLD}Directories >1GB:${RESET}"
to_clean=()
for path in "${!dir_sizes[@]}"; do
    size=${dir_sizes["$path"]}
    size_gb=$(echo "$size / 1073741824" | bc -l)
    if (( $(echo "$size_gb > 1" | bc -l) )); then
        to_clean+=("$path ($size_gb GB)")
    fi
done

if [ ${#to_clean[@]} -eq 0 ]; then
    echo "No directories >1GB found."
else
    for item in "${to_clean[@]}"; do
        echo -e "${ORANGE}$item${RESET}"
    done

    echo
    read -p "Do you want to clean these directories? [y/N]: " clean_confirm
    if [[ "$clean_confirm" =~ ^[Yy]$ ]]; then
        echo "Cleaning directories..."
        for item in "${to_clean[@]}"; do
            dir=$(echo "$item" | awk '{print $1}')
            echo -e "Deleting ${dir} ..."
            rm -rf "$dir"
        done
        echo "Cleanup complete."
    else
        echo "No directories were cleaned."
    fi
fi
