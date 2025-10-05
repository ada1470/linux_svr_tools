#!/bin/bash

NGINX_BIN="/www/server/nginx/sbin/nginx"
APACHE_BIN="/www/server/apache/bin/httpd"
MD5_DIR="/home/md5"

mkdir -p "$MD5_DIR"

# Detect if nginx or apache is installed
detect_web_server() {
    if pgrep nginx > /dev/null 2>&1 && [ -x "$NGINX_BIN" ]; then
        echo "nginx"
    elif pgrep httpd > /dev/null 2>&1 && [ -x "$APACHE_BIN" ]; then
        echo "apache"
    else
        echo "unknown"
    fi
}

# Get version functions
get_nginx_version() {
    "$NGINX_BIN" -v 2>&1 | awk -F/ '{print $2}'
}

get_apache_version() {
    "$APACHE_BIN" -v 2>/dev/null | grep "Server version" | awk -F/ '{print $2}' | awk '{print $1}'
}

# Save MD5
save_md5() {
    local bin_path=$1
    local name=$2
    local version_func=$3

    local version=$($version_func)
    local date_str=$(date +"%Y%m%d_%H%M%S")
    local md5=$(md5sum "$bin_path" | awk '{print $1}')
    local out_file="$MD5_DIR/${name}_${version}_${date_str}.txt"

    echo "$md5" > "$out_file"
    echo "[$name] MD5 saved to: $out_file"
}

# Compare MD5
compare_md5() {
    local bin_path=$1
    local name=$2

    latest_file=$(ls -t "$MD5_DIR/${name}_"*.txt 2>/dev/null | head -n 1)
    if [ -z "$latest_file" ]; then
        echo "No saved MD5 files found for [$name] in $MD5_DIR"
        return 1
    fi

    saved_md5=$(cat "$latest_file")
    current_md5=$(md5sum "$bin_path" | awk '{print $1}')

    echo "[$name] Latest saved MD5: $saved_md5"
    echo "[$name] Current binary MD5: $current_md5"

    if [ "$saved_md5" == "$current_md5" ]; then
        echo "✔ [$name] MD5 Match: Binary is unchanged."
    else
        echo "✘ [$name] MD5 Mismatch: Binary may have been modified!"
    fi
}

# MAIN
server_type=$(detect_web_server)

case "$server_type" in
    nginx)
        echo "[Detected] Web Server: NGINX"
        echo "1. Save nginx MD5"
        echo "2. Compare nginx MD5"
        read -rp "Choose an option: " choice
        if [ "$choice" == "1" ]; then
            save_md5 "$NGINX_BIN" "nginx" get_nginx_version
        elif [ "$choice" == "2" ]; then
            compare_md5 "$NGINX_BIN" "nginx"
        else
            echo "Invalid option."
        fi
        ;;
    apache)
        echo "[Detected] Web Server: APACHE"
        echo "1. Save apache MD5"
        echo "2. Compare apache MD5"
        read -rp "Choose an option: " choice
        if [ "$choice" == "1" ]; then
            save_md5 "$APACHE_BIN" "apache" get_apache_version
        elif [ "$choice" == "2" ]; then
            compare_md5 "$APACHE_BIN" "apache"
        else
            echo "Invalid option."
        fi
        ;;
    *)
        echo "⚠ No supported web server detected (nginx/apache)"
        ;;
esac
