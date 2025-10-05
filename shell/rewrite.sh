#!/bin/bash

BACKUP_DIR="/home/www/backup/siteconfig/www/server/panel/vhost/rewrite"
REWRITE_DIR="/www/server/panel/vhost/rewrite"
APACHE_HTACCESS_DIR="/home/www/wwwroot"
BLOCK_BOTS="Amazonbot|ClaudeBot|bingbot|facebook|TridentBot|GoogleBot|GPTBot|SemrushBot|MJ12bot|DotBot|BLEXBot|Bytespider"
WHITELIST_MOBILE="mobile|Baiduspider|SogouSpider|Sogou Web Spider|360Spider|YisouSpider"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

SERVER_TYPE=""

# Detect server type
detect_server() {
    if pgrep -x "nginx" >/dev/null || [ -x /www/server/nginx/sbin/nginx ]; then
        echo -e "${GREEN}Server detected: Nginx${NC}"
        SERVER_TYPE="nginx"
    elif pgrep -x "httpd" >/dev/null || [ -x /www/server/apache/bin/httpd ]; then
        echo -e "${GREEN}Server detected: Apache${NC}"
        SERVER_TYPE="apache"
    else
        echo -e "${RED}Unable to detect web server. Exiting.${NC}"
        exit 1
    fi
}


# Backup function
backup_rewrite() {
    echo -e "${YELLOW}Backing up rewrite files...${NC}"
    mkdir -p "$BACKUP_DIR"
    rsync -a --delete "$REWRITE_DIR/" "$BACKUP_DIR/"
    echo -e "${GREEN}Backup completed to:$NC $BACKUP_DIR"
}

# Restore function
restore_rewrite() {
    echo -e "${YELLOW}Restoring from backup...${NC}"
    rsync -a "$BACKUP_DIR/" "$REWRITE_DIR/"
    echo -e "${GREEN}Restore completed!${NC}"
}

# Test server config
test_server_config() {
    if [ "$SERVER_TYPE" = "nginx" ]; then
        echo -e "${YELLOW}Testing Nginx configuration...${NC}"
        if nginx -t 2>&1 | grep -q 'syntax is ok'; then
            echo -e "${GREEN}Nginx configuration syntax is OK.${NC}"
        else
            echo -e "${RED}Nginx configuration test FAILED!${NC}"
            nginx -t
        fi
    elif [ "$SERVER_TYPE" = "apache" ]; then
        echo -e "${YELLOW}Testing Apache configuration...${NC}"
        if apachectl configtest 2>&1 | grep -q 'Syntax OK'; then
            echo -e "${GREEN}Apache configuration syntax is OK.${NC}"
        else
            echo -e "${RED}Apache configuration test FAILED!${NC}"
            apachectl configtest
        fi
    fi
}

# Modify rewrite .conf files
modify_rewrite() {
    echo -e "${YELLOW}Modifying rewrite files...${NC}"
    cd "$REWRITE_DIR" || exit
    find . -type f -name '*.conf' ! -name 'datacenter.com.conf' | while read -r file; do
        modified=false

        # Block runtime etc
        if grep -qE 'runtime\|application\|thinkphp' "$file"; then
            echo -e "${YELLOW}Skipped (already has runtime|application|thinkphp):${NC} $file"
        elif grep -qE 'runtime\|application' "$file"; then
            sed -i 's/runtime|application/runtime|application|thinkphp|extend|addons/g' "$file"
            echo -e "${GREEN}Expanded runtime block:${NC} $file"
            modified=true
        else
            sed -i '1i location ~* (runtime|application|thinkphp|extend|addons)/{\n    return 403;\n}\n' "$file"
            echo -e "${GREEN}Inserted runtime block:${NC} $file"
            modified=true
        fi

        # Block bots
        if grep -qE '\$http_user_agent ~\* [("]' "$file"; then
            sed -i -r 's#(\$http_user_agent ~\* ["(])[^")]+([")])#\1'"$BLOCK_BOTS"'\2#' "$file"
            echo -e "${GREEN}Updated bot block list:${NC} $file"
            modified=true
        else
            sed -i '$ a\\nif ($http_user_agent ~* "'"$BLOCK_BOTS"'") {\n    return 403;\n}\n' "$file"
            echo -e "${GREEN}Appended bot block:${NC} $file"
            modified=true
        fi

        # Block POST/PUT
        if ! grep -qE '\$request_method ~\* \(POST\|PUT\)' "$file"; then
            sed -i '$ a\\nif ($request_method ~* (POST|PUT)) {\n    return 405;\n}\n' "$file"
            echo -e "${GREEN}Appended POST/PUT block:${NC} $file"
            modified=true
        else
            echo -e "${YELLOW}Skipped POST/PUT block:${NC} $file"
        fi

        # Block /admin/
        if ! grep -q '\$request_uri ~\* "/admin/"' "$file"; then
            sed -i '$ a\\nif ($request_uri ~* "/admin/") {\n    return 403;\n}\n' "$file"
            echo -e "${GREEN}Appended /admin/ block:${NC} $file"
            modified=true
        else
            echo -e "${YELLOW}Skipped /admin/ block:${NC} $file"
        fi

        [ "$modified" = false ] && echo -e "${YELLOW}No changes needed:${NC} $file"
    done
}

# Modify .htaccess files for Apache
modify_htaccess() {
    echo -e "${YELLOW}Modifying Apache .htaccess files...${NC}"
    for htaccess in "$APACHE_HTACCESS_DIR"/*/.htaccess "$APACHE_HTACCESS_DIR"/*/public/.htaccess; do
        [ -f "$htaccess" ] || continue
        modified=false

        if ! grep -qE "runtime|application|thinkphp" "$htaccess"; then
            echo -e "RewriteCond %{REQUEST_URI} /(runtime|application|thinkphp|extend|addons)/ [NC]\nRewriteRule .* - [F]" | cat - "$htaccess" > temp && mv temp "$htaccess"
            echo -e "${GREEN}Inserted runtime block:${NC} $htaccess"
            modified=true
        fi

        # Check if any part of the bot list exists in .htaccess
        if grep -qE "RewriteCond %{HTTP_USER_AGENT}.*(Amazonbot|ClaudeBot|bingbot|facebook|TridentBot)" "$htaccess"; then
            # Replace entire line with full BLOCK_BOTS list
            sed -i -r "s#(RewriteCond %{HTTP_USER_AGENT} ).*#\1($BLOCK_BOTS) [NC]#" "$htaccess"
            echo -e "${GREEN}Updated bot block (expanded list):${NC} $htaccess"
            modified=true
        else
            # Append if not found at all
            echo -e "\nRewriteCond %{HTTP_USER_AGENT} ($BLOCK_BOTS) [NC]\nRewriteRule .* - [F]" >> "$htaccess"
            echo -e "${GREEN}Appended bot block:${NC} $htaccess"
            modified=true
        fi


        [ "$modified" = false ] && echo -e "${YELLOW}No changes needed:${NC} $htaccess"
    done
}

# Restrict to mobile/spiders
restrict_mobile() {
    echo -e "${YELLOW}Applying mobile whitelist...${NC}"

    # Nginx
    cd "$REWRITE_DIR" || exit
    find . -type f -name '*.conf' ! -name 'datacenter.com.conf' | while read -r file; do
        modified=false
        if grep -qE '\$http_user_agent ~\* \([^)]*(mobile|baidu)[^)]*\)' "$file"; then
            sed -i -r 's#(\$http_user_agent ~\* \()[^)]*(\))#\1'"$WHITELIST_MOBILE"'\2#' "$file"
            echo -e "${GREEN}Updated mobile whitelist:${NC} $file"
            modified=true
        else
            sed -i '$ a\\nif ($http_user_agent !~* "'"$WHITELIST_MOBILE"'") {\n    return 403;\n}\n' "$file"
            echo -e "${GREEN}Appended mobile whitelist:${NC} $file"
            modified=true
        fi
        [ "$modified" = false ] && echo -e "${YELLOW}No changes needed:${NC} $file"
    done

    # Apache
    if [ "$SERVER_TYPE" = "apache" ]; then
        for htaccess in "$APACHE_HTACCESS_DIR"/*/.htaccess "$APACHE_HTACCESS_DIR"/*/public/.htaccess; do
            [ -f "$htaccess" ] || continue
            modified=false

            if grep -qE "RewriteCond %{HTTP_USER_AGENT} (mobile|baidu)" "$htaccess"; then
                sed -i -r "s#(RewriteCond %{HTTP_USER_AGENT} ).*#\1!($WHITELIST_MOBILE) [NC]#" "$htaccess"
                echo -e "${GREEN}Updated mobile whitelist:${NC} $htaccess"
                modified=true
            else
                echo -e "\nRewriteCond %{HTTP_USER_AGENT} !($WHITELIST_MOBILE) [NC]\nRewriteRule .* - [F]" >> "$htaccess"
                echo -e "${GREEN}Appended mobile whitelist:${NC} $htaccess"
                modified=true
            fi

            [ "$modified" = false ] && echo -e "${YELLOW}No changes needed:${NC} $htaccess"
        done
    fi
}

# Main menu
main_menu() {
    clear
    detect_server
    echo ""
    echo "============== MENU =============="
    echo "1) Backup current rewrite files"
    echo "2) Modify rewrite files (add firewall rules)"
    echo "3) Restrict mobile only and whitelist spiders"
    echo "4) Restore previous backup"
    echo "0) Exit"
    echo "==================================="
    read -rp "Enter your choice: " choice

    case "$choice" in
        1)
            backup_rewrite
            ;;
        2)
            modify_rewrite
            [ "$SERVER_TYPE" = "apache" ] && modify_htaccess
            test_server_config
            ;;
        3)
            restrict_mobile
            test_server_config
            ;;
        4)
            restore_rewrite
            test_server_config
            ;;
        0)
            echo -e "${YELLOW}Exit.${NC}"
            exit 0
            ;;
        *)
            echo -e "${RED}Invalid option.${NC}"
            ;;
    esac
}

main_menu
