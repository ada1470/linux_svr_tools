#!/bin/bash

THRESHOLD_KB=$((1024 * 1024))  # 1GB
TIMEOUT_SEC=5
LOG_FILE="cache_scan_$(date +%Y%m%d_%H%M%S).log"

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
RESET="\033[0m"

declare -a RESULT_PATHS
declare -a RESULT_SIZES
declare -a RESULT_STATUS
declare -a RESULT_DOMAINS_ALERT

for cache_dir in /home/www/wwwroot/*/site/*/cache /home/www/wwwroot/*/public/site/*/cache; do
    [ -d "$cache_dir" ] || continue
    echo "Checking: $cache_dir"

    total_kb=0
    skip_this=0
    reason="OK"

    for subdir in "$cache_dir"/*/*; do
        [ -d "$subdir" ] || continue

        size_kb=$(timeout "$TIMEOUT_SEC" du -sk --max-depth=0 "$subdir" 2>/dev/null | awk '{print $1}')

        if [ -z "$size_kb" ]; then
            reason="TIMEOUT"
            skip_this=1
            break
        fi

        total_kb=$((total_kb + size_kb))

        if [ "$total_kb" -gt "$THRESHOLD_KB" ]; then
            reason="TOO LARGE"
            skip_this=1
            break
        fi
    done

    size_mb=$((total_kb / 1024))
    RESULT_PATHS+=("$cache_dir")
    RESULT_SIZES+=("${size_mb} MB")
    RESULT_STATUS+=("$reason")

    if [[ "$reason" == "TOO LARGE" || "$reason" == "TIMEOUT" ]]; then
        RESULT_DOMAINS_ALERT+=("$cache_dir")
    fi
done

# Print summary table
printf "\n%-60s | %-10s | %-10s\n" "CACHE DIR" "SIZE" "STATUS" | tee "$LOG_FILE"
printf "%s\n" "$(printf -- "-%.0s" {1..85})" | tee -a "$LOG_FILE"

for i in "${!RESULT_PATHS[@]}"; do
    path="${RESULT_PATHS[$i]}"
    size="${RESULT_SIZES[$i]}"
    status="${RESULT_STATUS[$i]}"

    case "$status" in
        OK)
            color=$GREEN
            ;;
        TOO\ LARGE)
            color=$RED
            ;;
        TIMEOUT)
            color=$YELLOW
            ;;
        *)
            color=$RESET
            ;;
    esac

    printf "%-60s | %-10s | ${color}%-10s${RESET}\n" "$path" "$size" "$status" | tee -a "$LOG_FILE"
done

# Print domains needing attention
if [ "${#RESULT_DOMAINS_ALERT[@]}" -gt 0 ]; then
    echo -e "\n${RED}Domains that are TOO LARGE or TIMEOUT:${RESET}" | tee -a "$LOG_FILE"
    for domain in "${RESULT_DOMAINS_ALERT[@]}"; do
        echo "$domain" | tee -a "$LOG_FILE"
    done
else
    echo -e "\n${GREEN}No domains exceeded size or timeout limits.${RESET}" | tee -a "$LOG_FILE"
fi

echo -e "\nLog saved to: $LOG_FILE"
