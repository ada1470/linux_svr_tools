#!/bin/bash

LOG_FILE="/tmp/trojan_scan.log"
RED='\033[1;31m'
ORANGE='\033[38;5;208m'  # True orange
NC='\033[0m'

# Clear log
> "$LOG_FILE"

# Rule format: <path>:<keywords> OR <path> (trojan)
readarray -t rule_list <<EOF

/etc/rc.d/rc.local:curl
/etc/systemd/system/python.service
/home/www/wwwroot/*/*.php(max-depth=2):base64|$_SESSION|error_reporting\(0
/home/www/wwwroot/*/addons/adminloginbg/index.php:error_reporting\(0
/home/www/wwwroot/*/addons/dplayer/config/config.php:base64
/home/www/wwwroot/*/application/admin/controller/*.php:error_reporting\(0|eval\(|file_get_contents
/home/www/wwwroot/*/application/admin/controller/index.php:file_put_contents|curl_init
/home/www/wwwroot/*/application/common.php:include|pack
/home/www/wwwroot/*/application/common/extend/upload/default.php:error_reporting\(0
/home/www/wwwroot/*/application/extra/addons.php:gzuncompress
/home/www/wwwroot/*/application/extra/bind.php:hex2bin
/home/www/wwwroot/*/application/route.php:display_errors|eval\(|file_get_contents|base64
/home/www/wwwroot/*/application/lang/mysql.php:adminer
/home/www/wwwroot/*/common.php:substr|eval\(
/home/www/wwwroot/*/common/model/Upload.php:base64
/home/www/wwwroot/*/dplayer/dplayer.php:base64
/home/www/wwwroot/*/public/config.php
#/home/www/wwwroot/*/seo/tpl/*/*:document.write|window.location.href
/home/www/wwwroot/*/static/js/playerconfig.js:https
/home/www/wwwroot/*/static/player/*.js:window.location.href|setCookie
#/home/www/wwwroot/*/template/*/html/*/*:setCookie|document.cookie|document.write|window.location.href|eval\(|atob|createElement
/home/www/wwwroot/*/thinkphp/base.php:ob_en_clean|base64|substr|eval\(|file_get_contents|window.location.href
/home/www/wwwroot/*/thinkphp/library/think/Cache.php:base64|call_user_func
/home/www/wwwroot/*/thinkphp/library/think/Loader.php:file_get_contents|base64
/home/www/wwwroot/*/thinkphp/library/think/Route.php:file_get_contents|base64
/home/www/wwwroot/*/thinkphp/library/think/view/driver/Map.php:error_reporting\(0
/home/www/wwwroot/*/thinkphp/library/think/Session.php:samesite
/home/www/wwwroot/*/upload/*.php
# for xsite
/home/www/wwwroot/*/*.js:setCookie|window.location.href
/home/www/wwwroot/*/MDassets/js/MDsystem.js
/home/www/wwwroot/*/static/assets/js/home.js:setCookie|window.location.href
/home/www/wwwroot/*/static/assets/js/main.js:userAgent|localStorage|SameSite
/home/www/wwwroot/*/static/js/jquery.js:write
/home/www/wwwroot/*/static/jsui/js/jquery.min.js
# system
/tmp/*.py
/tmp/*.sh
#/tmp/*:error_reporting\(0\(0|base64|eval\(
/usr/gotohttp
/var/lib/*.sh(max-depth=2)
/var/lib/*:setCookie|header\(|eval\(
/var/lib/linux
/var/lib/python.sh
/var/lib/stateless/stateless:setCookie|header
/www/server/*.lua:is_mobile
/www/server/btwaf/public/public.lua:btwaf_ip:set
/www/server/cron/*:eval\(|curl
/www/server/nginx/conf/mime.types:document.cookie|atob|createElement|window.location.href|<script
/www/server/nginx/conf/proxy.conf:document.cookie|atob|createElement|window.location.href|<script
/www/server/nginx/conf/rewrite/*:decode_base64
/www/server/nginx/lib/lua/ngx/procese.lua:agent
/www/server/panel/script/*.sh:curl
/www/server/panel/vhost/nginx/0.default.conf:document.cookie|atob|createElement|window.location.href|
/www/wwwlogs/mynginx/btwaf.lua
EOF

readarray -t whitelist_raw <<EOF
[*]: /tmp/trojan_scan.log
# php
[error_reporting]: /index.php
[error_reporting]: /home/www/wwwroot/instruction.com/wp-load.php
[file_get_contents]: /application/admin/controller/System.php
[file_get_contents]: /application/admin/controller/Update.php
[file_get_contents]: /application/admin/controller/Template.php
[file_get_contents]: /application/admin/controller/Cj.php
[file_get_contents]: /application/admin/controller/Base.php
[file_get_contents]: /application/admin/controller/Vodplayer.php
[file_get_contents]: /application/admin/controller/Domain.php

[base64]: /application/common.php
[substr]: /application/common.php
[include]: /application/common.php
[substr]: /include/common.php

# html
[window.location.href;]: /play.html
[window.location.href;]: /detail.html
[window.location.href;]: /foot.html
[window.location.href;]: /head.html
[window.location.href;]: /index.html

# cron
/www/server/cron/*:curl*/timming/*

EOF

declare -A whitelist

# Populate whitelist associative array correctly
# for line in "${whitelist_raw[@]}"; do
#     [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue  # skip comments/blanks
#     key="${line%%]: *}"
#     key="${key#[}"
#     path="${line#*: }"
#     whitelist["$key|$path"]=1
# done
for entry in "${whitelist_raw[@]}"; do
    wl_path_pattern="${entry%%:*}"
    wl_keyword_pattern="${entry#*:}"

    # Match file path with glob pattern
    if [[ "$file" == $wl_path_pattern ]]; then
        # Split keyword pattern on '/'
        match_all=true
        IFS='/' read -ra parts <<< "$wl_keyword_pattern"
        for sub in "${parts[@]}"; do
            if [[ -n "$sub" && "$keyword" != *"$sub"* ]]; then
                match_all=false
                break
            fi
        done

        if $match_all; then
            echo "✅ Whitelist matched: $entry"
            continue 2
        fi
    fi
done

all_files=()
matched_files=()

for entry in "${rule_list[@]}"; do
    [[ -z "$entry" || "$entry" =~ ^# ]] && continue

    raw_path="${entry%%:*}"
    echo "📦 Collecting files from rule: $raw_path"
    
    if [[ "$raw_path" =~ \(max-depth=([0-9]+)\) ]]; then
        depth="${BASH_REMATCH[1]}"
        path="${raw_path/\(max-depth=$depth\)/}"
        find_args=(-maxdepth "$depth")
    else
        path="$raw_path"
        find_args=()
    fi

    eval_paths=$(eval echo "$(dirname "$path")")
    basename_pattern="$(basename "$path")"
    
    for d in $eval_paths; do
        [[ ! -d "$d" ]] && continue
        echo "📁 Indexing: $d/$(basename "$path")"
        find_cmd=(find "$d")
        [[ -n "$depth" ]] && find_cmd+=(-maxdepth "$depth")
        find_cmd+=(-type f -name "$basename_pattern")

        while IFS= read -r f; do
            [[ -n "$f" ]] && all_files+=("$f|$entry")
        done < <("${find_cmd[@]}" 2>/dev/null)
    done
done

total=${#all_files[@]}
count=0
DEBUG_LOG="/tmp/debug_scan_trojan.log"  # Change this path as needed
for item in "${all_files[@]}"; do
    ((count++))
    IFS='|' read -r file entry <<< "$item"

    echo -ne "\r📂 $file\n🔍 Scanning: $count/$total\r"

    if [[ -z "$file" ]]; then
        echo -e "${RED}❌ Warning: empty file path encountered at rule: $entry${NC}"
        continue
    fi

    raw_path="${entry%%:*}"
    raw_pattern="${entry#*:}"
    [[ "$entry" == "$raw_path" ]] && raw_pattern="__MARKED_AS_TROJAN__"

    filename=$(basename "$file")
    extension="${filename##*.}"
    is_extensionless=false
    [[ "$filename" == "$extension" ]] && is_extensionless=true

    matched=false

    # TROJAN check block
    if [[ "$raw_pattern" == "__MARKED_AS_TROJAN__" ]]; then
        # For trojan, keyword is fixed as "TROJAN" for whitelist key
        # wl_key="TROJAN|$file"

        # if [[ -n "${whitelist["$wl_key"]}" ]]; then
        #     # Whitelisted trojan file, skip silently
        #     continue
        # fi
        for wkey in "${!whitelist[@]}"; do
            wl_keyword="${wkey%%|*}"
            wl_path="${wkey#*|}"
            if [[ "$wl_keyword" == "$keyword" && "$file" == *"$wl_path" ]]; then
                # Found match by suffix path
                continue 2  # exit 2 loops (keyword loop and file loop)
            fi
        done


        if $is_extensionless; then
            echo -e "${ORANGE}🟧 [NO EXT] Trojan file: \"$file\"${NC}"
            echo "[$(date)] ORANGE NOEXT TROJAN: $file" >> "$LOG_FILE"
        else
            echo -e "${RED}🚨 [TROJAN] $file${NC}"
            echo "[$(date)] TROJAN: $file" >> "$LOG_FILE"
        fi
        matched_files+=("$file")
        continue
    fi
    
    
    # Keyword pattern matching
    IFS='|' read -ra patterns <<< "$raw_pattern"
    for keyword in "${patterns[@]}"; do
        [[ -z "$keyword" ]] && continue

        # Use fixed string grep to avoid regex issues
        if grep -Fq "$keyword" "$file"; then
            # wl_key="$keyword|$file"
            # echo "DEBUG: Checking whitelist for [$wl_key]"
            # if [[ -n "${whitelist["$wl_key"]}" ]]; then
            #     # Whitelisted, skip silently
            #     matched=true
            #     break
            # fi
            for wkey in "${!whitelist[@]}"; do
    wl_keyword="${wkey%%|*}"
    wl_path="${wkey#*|}"

    # Normalize both: trim trailing semicolons, commas, spaces
    clean_keyword="${keyword//[;, ]/}"
    clean_wl_keyword="${wl_keyword//[;, ]/}"

    {
        echo "🔍 DEBUG: Comparing"
        echo "      Match keyword       = '$keyword'"
        echo "      Cleaned keyword     = '$clean_keyword'"
        echo "      Whitelist keyword   = '$wl_keyword'"
        echo "      Cleaned WL keyword  = '$clean_wl_keyword'"
        echo "      File                = '$file'"
        echo "      Whitelist path      = '$wl_path'"
    } >> "$DEBUG_LOG"

    if [[ "$clean_keyword" == "$clean_wl_keyword" && "$file" == *"$wl_path" ]]; then
        echo "✅ DEBUG: Whitelist matched → skipping this result" >> "$DEBUG_LOG"
        continue 2
    else
        echo "❌ DEBUG: No match on this whitelist entry" >> "$DEBUG_LOG"
    fi
done




            if $is_extensionless; then
                echo -e "${ORANGE}🟧 [NO EXT] Matched [$keyword] in $file${NC}"
                echo "[$(date)] ORANGE NOEXT MATCH [$keyword]: $file" >> "$LOG_FILE"
            else
                echo -e "${RED}🚨 Matched [$keyword] in $file${NC}"
                echo "[$(date)] MATCH [$keyword]: $file" >> "$LOG_FILE"
            fi

            matched_files+=("$file")
            matched=true
            break
        fi
    done

done

if [[ ${#matched_files[@]} -gt 0 ]]; then
    echo -e "\n🧾 Matched files:"
    for f in "${matched_files[@]}"; do
        echo " - $f"
    done
else
    echo -e "\n✅ No suspicious matches found."
fi

echo -e "\n📄 Log file saved: $LOG_FILE"
