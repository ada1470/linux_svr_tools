#!/bin/bash

# Check if iostat is installed
if ! command -v iostat &> /dev/null; then
    echo "iostat not found. Installing sysstat..."
    sudo yum install -y sysstat || exit 1
fi

# Collect iostat output (2 samples, 1 second apart)
output=$(iostat -dx 1 2)

echo "==================== Disk I/O Status ===================="
printf "%-8s %-12s %-12s %-10s %-10s %-12s\n" "Device" "Read(KB/s)" "Write(KB/s)" "IOPS_r" "IOPS_w" "Latency(ms)"
echo "--------------------------------------------------------------"

# Parse the last section only (after the last 'Device:' header)
echo "$output" | awk '
BEGIN { header_found=0 }
/^Device:/ { header_found=1; next }
header_found && NF >= 12 {
    device=$1
    rkbs=$6
    wkbs=$7
    rps=$4
    wps=$5
    await=$10
    printf "%-8s %-12s %-12s %-10s %-10s %-12s\n", device, rkbs, wkbs, rps, wps, await
}'
