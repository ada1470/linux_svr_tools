#!/bin/bash

BACKUP_DIR="/home/www/backup/siteconfig/www/server/panel/vhost/rewrite"
REWRITE_DIR="/www/server/panel/vhost/rewrite"
APACHE_HTACCESS_DIR="/home/www/wwwroot"
BLOCK_BOTS="Amazonbot|ClaudeBot|bingbot|facebook|TridentBot|GoogleBot|GPTBot|SemrushBot|MJ12bot|DotBot|BLEXBot"
WHITELIST_MOBILE="mobile|Baiduspider|SogouSpider|Sogou\ Web\ Spider|360Spider|YisouSpider|Bytespider"

SERVER_TYPE=""

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Detect Web Server Type
detect_server() {
    if command -v apachectl &> /dev/null || [ -f /etc/httpd/conf/httpd.conf ] || [ -f /etc/apache2/apache2.conf ]; then
        echo -e "${GREEN}Server detected: Apache${NC}"
        SERVER_TYPE="apache"
    elif command -v nginx &> /dev/null || [ -f /etc/nginx/nginx.conf ]; then
        echo -e "${GREEN}Server detected: Nginx${NC}"
        SERVER_TYPE="nginx"
    else
        echo -e "${RED}Unable to detect web server. Exiting.${NC}"
        exit 1
    fi
}

# Backup function
backup_rewrite() {
    echo -e "${YELLOW}Backing up current rewrite files...${NC}"
    mkdir -p "$BACKUP_DIR"
    rsync -a --delete "$REWRITE_DIR/" "$BACKUP_DIR/"
    echo -e "${GREEN}Backup completed at: $BACKUP_DIR${NC}"
}

# Restore function
restore_rewrite() {
    echo -e "${YELLOW}Restoring rewrite files from backup...${NC}"
    rsync -a "$BACKUP_DIR/" "$REWRITE_DIR/"
    echo -e "${GREEN}Restore completed!${NC}"
}

# Modify rewrite .conf files
modify_rewrite() {
    echo -e "${YELLOW}Modifying rewrite .conf files...${NC}"
    cd "$REWRITE_DIR" || exit

    find . -type f -name '*.conf' ! -name 'datacenter.com.conf' | while read -r file; do
        modified=false

        # runtime|application|thinkphp handling
        if grep -qE 'runtime\|application\|thinkphp' "$file"; then
            echo -e "${YELLOW}Skipped (already contains runtime|application|thinkphp):${NC} $file"
        elif grep -qE 'runtime\|application' "$file"; then
            sed -i 's/runtime|application/runtime|application|thinkphp|extend|addons/g' "$file"
            echo -e "${GREEN}Updated (expanded condition):${NC} $file"
            modified=true
        else
            sed -i '1i location ~* (runtime|application|thinkphp|extend|addons)/{\n    return 403;\n}\n' "$file"
            echo -e "${GREEN}Inserted (new location block):${NC} $file"
            modified=true
        fi

        # bot blocking
        if grep -qE '\$http_user_agent ~\* [("]' "$file"; then
            sed -i -r 's#(\$http_user_agent ~\* ["(])[^")]+([")])#\1'"$BLOCK_BOTS"'\2#' "$file"
            echo -e "${GREEN}Updated (bot block UA list):${NC} $file"
            modified=true
        else
            sed -i '$ a\\nif (\$http_user_agent ~* ('"$BLOCK_BOTS"')) {\n    return 403;\n}\n' "$file"
            echo -e "${GREEN}Appended (bot block):${NC} $file"
            modified=true
        fi

        # POST/PUT method block
        if ! grep -qE '\$request_method ~\* \(POST\|PUT\)' "$file"; then
            sed -i '$ a\\nif (\$request_method ~* (POST|PUT)) {\n    return 405;\n}\n' "$file"
            echo -e "${GREEN}Appended (POST/PUT block):${NC} $file"
            modified=true
        else
            echo -e "${YELLOW}Skipped (already has POST/PUT block):${NC} $file"
        fi

        # /admin/ URI block
        if ! grep -qE '\$request_uri ~\* "/admin/"' "$file"; then
            sed -i '$ a\\nif (\$request_uri ~* "/admin/") {\n    return 403;\n}\n' "$file"
            echo -e "${GREEN}Appended (/admin/ block):${NC} $file"
            modified=true
        else
            echo -e "${YELLOW}Skipped (already has /admin/ block):${NC} $file"
        fi

        if [ "$modified" = false ]; then
            echo -e "${YELLOW}No changes needed:${NC} $file"
        fi
    done
}

# Modify Apache .htaccess files (new improved)
modify_htaccess() {
    echo -e "${YELLOW}Modifying .htaccess files for Apache...${NC}"
    for htaccess in "$APACHE_HTACCESS_DIR"/*/.htaccess "$APACHE_HTACCESS_DIR"/*/public/.htaccess; do
        [ -f "$htaccess" ] || continue
        modified=false

        # Add rewrite condition for runtime/application/thinkphp/etc
        if ! grep -qE "runtime|application|thinkphp" "$htaccess"; then
            echo -e "RewriteCond %{REQUEST_URI} /(runtime|application|thinkphp|extend|addons)/ [NC]\nRewriteRule .* - [F]" | cat - "$htaccess" > temp && mv temp "$htaccess"
            echo -e "${GREEN}Added runtime block:${NC} $htaccess"
            modified=true
        fi

        # Block bad bots by User-Agent
        if grep -qE "RewriteCond %{HTTP_USER_AGENT} (mobile|baidu|bingbot)" "$htaccess"; then
            sed -i -r "s#(RewriteCond %{HTTP_USER_AGENT} ).*#\1($BLOCK_BOTS) [NC]#" "$htaccess"
            echo -e "${GREEN}Updated bot block:${NC} $htaccess"
            modified=true
        else
            echo -e "\nRewriteCond %{HTTP_USER_AGENT} ($BLOCK_BOTS) [NC]\nRewriteRule .* - [F]" >> "$htaccess"
            echo -e "${GREEN}Appended bot block:${NC} $htaccess"
            modified=true
        fi

        if [ "$modified" = false ]; then
            echo -e "${YELLOW}No changes needed:${NC} $htaccess"
        fi
    done
}

# Restrict Mobile only + Whitelist Spiders
restrict_mobile() {
    echo -e "${YELLOW}Applying mobile-only and spider-whitelist rules...${NC}"

    # Nginx conf files first
    cd "$REWRITE_DIR" || exit

    find . -type f -name '*.conf' ! -name 'datacenter.com.conf' | while read -r file; do
        modified=false

        if grep -qE '\$http_user_agent ~\* \([^)]*(mobile|baidu)[^)]*\)' "$file"; then
            sed -i -r 's#(\$http_user_agent ~\* \()[^)]*(\))#\1'"$WHITELIST_MOBILE"'\2#' "$file"
            echo -e "${GREEN}Updated (Nginx - replaced old whitelist):${NC} $file"
            modified=true
        else
            sed -i '$ a\\nif ($http_user_agent !~* ('"$WHITELIST_MOBILE"')) {\n    return 403;\n}\n' "$file"
            echo -e "${GREEN}Appended (Nginx - new mobile whitelist):${NC} $file"
            modified=true
        fi

        if [ "$modified" = false ]; then
            echo -e "${YELLOW}No changes needed (Nginx):${NC} $file"
        fi
    done

    # Apache .htaccess files
    if [ "$SERVER_TYPE" = "apache" ]; then
        echo -e "${YELLOW}Applying mobile whitelist to Apache .htaccess files...${NC}"
        for htaccess in "$APACHE_HTACCESS_DIR"/*/.htaccess "$APACHE_HTACCESS_DIR"/*/public/.htaccess; do
            [ -f "$htaccess" ] || continue
            modified=false

            if grep -qE "RewriteCond %{HTTP_USER_AGENT} (mobile|baidu)" "$htaccess"; then
                # Replace old mobile|baidu whitelist
                sed -i -r "s#(RewriteCond %{HTTP_USER_AGENT} ).*#\1($WHITELIST_MOBILE) [NC]#" "$htaccess"
                echo -e "${GREEN}Updated (Apache - replaced old whitelist):${NC} $htaccess"
                modified=true
            else
                # Add new mobile whitelist rule
                echo -e "\nRewriteCond %{HTTP_USER_AGENT} !($WHITELIST_MOBILE) [NC]\nRewriteRule .* - [F]" >> "$htaccess"
                echo -e "${GREEN}Appended (Apache - new mobile whitelist):${NC} $htaccess"
                modified=true
            fi

            if [ "$modified" = false ]; then
                echo -e "${YELLOW}No changes needed (Apache):${NC} $htaccess"
            fi
        done
    fi
}


# Test server config
test_server_config() {
    if [ "$SERVER_TYPE" = "nginx" ]; then
        echo -e "${YELLOW}Testing Nginx configuration...${NC}"
        if nginx -t 2>&1 | grep -q 'syntax is ok'; then
            echo -e "${GREEN}Nginx configuration syntax is OK.${NC}"
        else
            echo -e "${RED}Nginx configuration test FAILED!${NC}"
            nginx -t  # Show full error
        fi
    elif [ "$SERVER_TYPE" = "apache" ]; then
        echo -e "${YELLOW}Testing Apache configuration...${NC}"
        if apachectl configtest 2>&1 | grep -q 'Syntax OK'; then
            echo -e "${GREEN}Apache configuration syntax is OK.${NC}"
        else
            echo -e "${RED}Apache configuration test FAILED!${NC}"
            apachectl configtest  # Show full error
        fi
    fi
}


# Menu
main_menu() {
    clear
    detect_server
    echo ""
    echo "============== MENU =============="
    echo "1) Backup"
    echo "2) Modify the rewrite files (Block paths, bots, POST|PUT, admin)"
    echo "3) Restore the previous backup"
    echo "4) Restrict mobile only and whitelist spiders only"
    echo "0) Cancel/Exit"
    echo "==================================="
    read -rp "Enter your choice: " choice

    case "$choice" in
        1)
            backup_rewrite
            ;;
        2)
            modify_rewrite
            if [ "$SERVER_TYPE" = "apache" ]; then
                modify_htaccess
            fi
            test_server_config
            ;;
        3)
            restore_rewrite
            test_server_config
            ;;
        4)
            restrict_mobile
            test_server_config
            ;;
        0)
            echo -e "${YELLOW}Exit.${NC}"
            exit 0
            ;;
        *)
            echo -e "${RED}Invalid choice, please select 1, 2, 3 or 0.${NC}"
            ;;
    esac

}

main_menu
