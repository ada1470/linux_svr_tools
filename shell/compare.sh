# #!/bin/bash

# # Optional flag to ignore missing files
# ignore_missing=false

# # Parse arguments
# for arg in "$@"; do
#     if [[ "$arg" == "--ignore-missing" ]]; then
#         ignore_missing=true
#     fi
# done

# # Download remote MD5 list
# # remote_list="/tmp/file_list_remote.txt"
# # curl -s -o "$remote_list" " http://162.209.200.138:59999/docs/file_list_md5_home.txt"
# remote_list="/tmp/file_list_md5_home.txt"
# curl -s -o "$remote_list" " http://ins.spxx.com.cn/docs/file_list_md5_home.txt"

#!/bin/bash

script_host="http://ins.spxx.com.cn"

# Default values
ignore_missing=false
scan_dir="home"


# Parse arguments
for arg in "$@"; do
    case "$arg" in
        --ignore-missing)
            ignore_missing=true
            ;;
        --scan-dir=*)
            scan_dir="${arg#*=}"
            ;;
    esac
done

# Determine the remote list based on scan_dir
case "$scan_dir" in
    root)
        remote_list="/tmp/file_list_md5_root.txt"
        remote_url="$script_host/docs/file_list_md5_root.txt"
        ;;
    *)
        remote_list="/tmp/file_list_md5_home.txt"
        remote_url="$script_host/docs/file_list_md5_home.txt"
        ;;
esac

# Download remote MD5 list
curl -s -o "$remote_list" "$remote_url"


# Check if file downloaded successfully
if [ ! -s "$remote_list" ]; then
    echo "Failed to download or empty remote file list."
    echo "Please add the file manually at: $remote_list"
    exit 1
fi

# Log file for mismatches
mismatch_log="/tmp/md5_mismatches.txt"
> "$mismatch_log"

# Count total number of files
total=$(wc -l < "$remote_list")
count=0

echo "🔍 Comparing $total files..."

# Compare each line with progress
while read -r hash path; do
    ((count++))
    printf "\r[%d/%d] Checking: %s" "$count" "$total" "$path"

    if [ -f "$path" ]; then
        current_hash=$(md5sum "$path" | awk '{print $1}')
        if [ "$current_hash" != "$hash" ]; then
            echo "MD5 mismatch: $path" >> "$mismatch_log"
        fi
    else
        if [ "$ignore_missing" = false ]; then
            echo "File missing: $path" >> "$mismatch_log"
        fi
    fi
done < "$remote_list"

# Newline after progress
echo ""

# Output result
if [ -s "$mismatch_log" ]; then
    echo -e "\n❌ Mismatched or missing files detected."
    echo "📄 Full report saved at: $mismatch_log"
else
    echo "✅ All files match."
fi
