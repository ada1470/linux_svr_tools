#!/bin/bash

# ==========================
# Malware/Trojan Scanner Menu
# ==========================

# --- Functions (empty stubs for now) ---

scan_wwwlogs() {
    echo ">>> Scanning wwwlogs..."
    # TODO: add scanning logic
    grep -E "wget |eval\(|atob\(|shell_exec|passwd|base64| decode|_REQUEST|password|urldecode|curl_exec" -r /www/wwwlogs/ \
  | grep -v "/btwaf/" \
  | grep -v "/request/"

}

scan_application() {
    echo ">>> Scanning application..."
    # TODO: add scanning logic
        grep -E "base64_decode|str_rot13|hex2bin|gzinflate|create_function|stream_context_create|str_ireplace|error_reporting\(0\)|curl_exec|\$_REQUEST|eval\(|call_user_func|chmod|fwrite|rmdir|ob_end_flush" \
-r /home/www/wwwroot/*/application/ \
--exclude=common.php \
--exclude=Update.php \
--exclude=Upload.php \
--exclude=Collect.php \
--exclude=Addon.php \
--exclude-dir=extend \
--exclude-dir=controller \
--exclude-dir=util \
--exclude-dir=command \
--exclude='*bak*' \
--exclude='*tmp*' \
--exclude-dir='*bak*'

}

scan_php() {
    echo ">>> Scanning PHP files..."
    # TODO: add scanning logic
    start=$(date +%s)
grep -nr -E "base64_decode|str_rot13|hex2bin|bindec|gzinflate|create_function|stream_context_create|str_ireplace|error_reporting\(0\)|curl_exec|\$_REQUEST|eval\(|chmod|ob_end_flush" \
--exclude=common.php \
--exclude=Update.php \
--exclude=Upload.php \
--exclude=Collect.php \
--exclude=Addon.php \
--exclude=pics.php \
--exclude-dir=extend \
--exclude-dir=controller \
--exclude-dir=util \
--exclude-dir=command \
--exclude-dir=runtime \
--exclude-dir=cache \
--exclude-dir=vendor \
--exclude-dir=upload \
--exclude-dir=push \
--exclude-dir=img.com \
--exclude='*bak*' \
--exclude='*tmp*' \
--exclude='*.tar.gz' \
--exclude='*.sql' \
--exclude='*.js' \
--exclude='*.html' \
--exclude='*.css' \
--exclude='*.jpg' \
--exclude='*.jpeg' \
--exclude='*.png' \
--exclude-dir='*bak*' \
/home/www/wwwroot/
end=$(date +%s) && runtime=$((end - start)) && echo "⏱️ Scan completed in ${runtime} seconds"

}

scan_js() {
    echo ">>> Scanning JavaScript files..."
    # TODO: add scanning logic
    start=$(date +%s)
grep -nEr --color=always "atob|p,a,c,k,e,r|eval\(|window.history|location.replace|setCookie|system.win|writeln|document.write|window.open|window.document.cookie" \
  --include="*.js" \
  --exclude-dir=runtime \
  --exclude-dir=cache \
  --exclude-dir=upload \
  --exclude=home.js \
  --exclude=player.js \
  --exclude=function.js \
  --exclude='*bak*' \
  --exclude='*tmp*' \
  --exclude-dir='*bak*' \
  /home/www/wwwroot/ \
  | perl -pe 's/^(.{1024}).*/$1.../ if length > 1024'
end=$(date +%s) && runtime=$((end - start)) && echo "⏱️ Scan completed in ${runtime} seconds"

}

scan_runtime_cache() {
    echo ">>> Scanning runtime and cache (slow)..."
    # TODO: add scanning logic
    start=$(date +%s)

PATTERN='str_rot13|hex2bin|eval\(|gzuncompress|substr|chr\(|atob\(|charCodeAt|fromCharCode|decodeURIComponent|p,a,c,k,e,r|eval\(|location.replace|setCookie|system.win|writeln|document.write|window.open|window.document.cookie|localStorage|userAgent|location.href|xxSJRox|jump_isFromBaidu|_x_jump|binaryString|jquecy|aHR0cHM6Ly9jb2RlLmpxdWVjeS5jb20vanF1ZXJ5Lm1pbi0zLjYuOC5qcw'

files_checked=0
matches_found=0

# === 1. Site cache (latest 5 per domain, last 1 min) ===
# Enable recursive globbing (optional for future use)
shopt -s globstar

for sitecache in /home/www/wwwroot/*/site/*/cache; do
    [ -d "$sitecache" ] || continue
    echo "🔎 Checking site cache: $sitecache"

    # --- Level 1: latest 5 dirs under cache ---
    for lvl1 in $(ls -td "$sitecache"/* 2>/dev/null | head -n 5); do
        [ -d "$lvl1" ] || continue

        # --- Level 2: pick latest 1 dir ---
        lvl2=$(ls -td "$lvl1"/* 2>/dev/null | head -n 1)
        [ -d "$lvl2" ] || continue

        # --- Level 3: pick latest 1 dir ---
        lvl3=$(ls -td "$lvl2"/* 2>/dev/null | head -n 1)
        [ -d "$lvl3" ] || continue

        # --- Bottom level: pick latest 5 PHP files ---
        for f in $(ls -t "$lvl3"/*.php 2>/dev/null | head -n 1); do
            [ -n "$f" ] || continue
            mtime=$(date -d @"$(stat -c %Y "$f")" "+%Y-%m-%d %H:%M:%S")
            echo "Checking site cache file: $f (modified: $mtime)"
            ((files_checked++))
            match_count=$(grep -nE --color=always "$PATTERN" "$f" \
                | perl -pe 's/^(.{1024}).*/$1.../ if length > 1024' | tee /dev/tty | wc -l)
            ((matches_found+=match_count))
        done
    done
done





# === 2. Runtime cache (latest 5 subfolders, 1 file each, last 1 min) ===
for program in /home/www/wwwroot/*/runtime/cache; do
    [ -d "$program" ] || continue
  echo "🔎 Checking runtime cache for program: $program"
    # get latest 5 subfolders
    for subdir in $(ls -td "$program"/* 2>/dev/null | head -n 5); do
        [ -d "$subdir" ] || continue
        f=$(ls -t "$subdir"/*.php 2>/dev/null | head -n 1)
        if [ -n "$f" ] && [ $(( $(date +%s) - $(stat -c %Y "$f") )) -le 60 ]; then
            echo "Checking runtime cache file: $f"
            ((files_checked++))
            match_count=$(grep -nE --color=always "$PATTERN" "$f" \
                | perl -pe 's/^(.{1024}).*/$1.../ if length > 1024' | tee /dev/tty | wc -l)
            ((matches_found+=match_count))
        fi
    done
done

end=$(date +%s)
runtime=$((end - start))

echo "⏱️ Scan completed in ${runtime} seconds"
echo "📂 Files checked: $files_checked"
echo "⚠️ Matches found: $matches_found"


}

scan_runtime_cache_fast() {
    echo ">>> Fast check runtime/cache (filename length < 32)..."

    paths=(
        "/home/www/wwwroot/*/runtime/cache"
        "/home/www/wwwroot/*/site/*/cache"
    )

    # Build find arguments for existing paths only
    find_args=()
    for p in "${paths[@]}"; do
        # expand globs but only add if they exist
        for real in $p; do
            [[ -e "$real" ]] || continue
            find_args+=("$real")
        done
    done

    if [ ${#find_args[@]} -eq 0 ]; then
        echo "No runtime/cache paths found to scan."
        return 0
    fi

    matches=0
    echo "Scanning ${#find_args[@]} path(s)..."
    # Use -print0 to handle weird filenames safely
    while IFS= read -r -d '' file; do
        name=$(basename "$file")
        len=${#name}
        if (( len < 32 )); then
            printf "FOUND: %s (len=%d)\n" "$file" "$len"
            ((matches++))
        fi
    done < <(find "${find_args[@]}" -type f -print0 2>/dev/null)

    if (( matches == 0 )); then
        echo "No files with basename length < 32 were found."
    else
        echo "Total matches: $matches"
    fi
}


scan_php_in_img() {
    echo ">>> Scanning PHP files in image directories..."
    # Example search command (you can modify inside function later)
    find /home/www/wwwroot/*/template/ \
         /home/www/wwwroot/*/upload/ \
         /home/www/wwwroot/img.com/ \
         -type f -name "*.php"
    # TODO: add extra scanning logic
}

# --- Menu ---
while true; do
    clear
    echo "==============================="
    echo "   🚨 Malware Scan Menu"
    echo "==============================="
    echo "1) Scan wwwlogs"
    echo "2) Scan application"
    echo "3) Scan PHP"
    echo "4) Scan JavaScript"
    echo "5) Scan runtime/cache (slow)"
    echo "6) Fast check runtime/cache (filename < 32)"
    echo "7) Scan PHP files in img dirs"
    echo "0) Exit"
    echo "-------------------------------"
    read -p "Select an option: " choice

    case "$choice" in
        1) scan_wwwlogs ;;
        2) scan_application ;;
        3) scan_php ;;
        4) scan_js ;;
        5) scan_runtime_cache ;;
        6) scan_runtime_cache_fast ;;
        7) scan_php_in_img ;;
        0) echo "Bye!"; exit 0 ;;
        *) echo "❌ Invalid option"; sleep 1 ;;
    esac

    echo
    read -p "Press Enter to continue..."
done
