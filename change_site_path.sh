#!/bin/bash
# bt_sitepath_manager.sh
# Manage Baota (BT Panel) site paths in Nginx/Apache configs and site.db
# Supports backup, restore, replace (single/all/list), rollback, logging, summary, table display

# ====== CONFIG ======
NGINX_DIR="/www/server/panel/vhost/nginx"
APACHE_DIR="/www/server/panel/vhost/apache"
DB_PATH="/www/server/panel/data/db/site.db"
BACKUP_DIR="/home/www/backup/siteconfig"
LOG_FILE="/var/log/bt_sitepath_manager.log"

# ====== COLORS ======
RED="\033[31m"; GREEN="\033[32m"; YELLOW="\033[33m"; CYAN="\033[36m"; RESET="\033[0m"

# ====== LOG FUNCTION ======
log() {
    local level="$1"
    local msg="$2"
    local ts=$(date "+%F %T")
    case "$level" in
        INFO)  echo -e "${GREEN}[$ts] [INFO] $msg${RESET}" ;;
        WARN)  echo -e "${YELLOW}[$ts] [WARN] $msg${RESET}" ;;
        ERROR) echo -e "${RED}[$ts] [ERROR] $msg${RESET}" ;;
        *)     echo -e "[$ts] $msg" ;;
    esac
    echo "[$ts] [$level] $msg" >> "$LOG_FILE"
}

# ====== BACKUP ======
backup_configs() {
    log "INFO" "Backing up site configs and database..."
    mkdir -p "$BACKUP_DIR"
    rsync -a --relative "$NGINX_DIR" "$APACHE_DIR" "$BACKUP_DIR" 2>/dev/null
    rsync -a --relative "$DB_PATH" "$BACKUP_DIR"
    log "INFO" "Backup completed at $BACKUP_DIR"
}

# ====== RESTORE ======
restore_configs() {
    log "WARN" "Restoring configs and DB from backup..."
    rsync -a "$BACKUP_DIR/" /
    log "INFO" "Restore completed"
    restart_webserver
}

# ====== DETECT SERVER ======
detect_webserver() {
    if pgrep -x "nginx" >/dev/null; then
        echo "nginx"
    elif pgrep -x "httpd" >/dev/null || pgrep -x "apache2" >/dev/null; then
        echo "apache"
    else
        echo "unknown"
    fi
}

# ====== SHOW PATHS TABLE ======
show_paths_table() {
    local order="$1"
    order=${order:-id}  # default by id
    printf "\n%-5s %-25s %-50s\n" "ID" "Domain" "Path"
    printf "%-5s %-25s %-50s\n" "----" "------------------------" "--------------------------------------------------"

    while IFS=$'\t' read -r id name path; do
        [[ -z "$id" ]] && continue
        local f_ng="$NGINX_DIR/$name.conf"
        local f_ap="$APACHE_DIR/$name.conf"
        if [[ ! -f $f_ng && ! -f $f_ap ]]; then
            printf "%-5s %-25b %-50b\n" "$id" "$(echo -e "${RED}$name${RESET}")" "$path"
        else
            printf "%-5s %-25s %-50s\n" "$id" "$name" "$path"
        fi
    done < <(sqlite3 -separator $'\t' "$DB_PATH" "select id,name,path from sites order by $order;")
    echo
}

# ====== REPLACEMENT FUNCTIONS WITH COLOR HIGHLIGHT ======
replace_site_path() {
    local domain="$1" old="$2" new="$3"
    local f_ng="$NGINX_DIR/$domain.conf"
    local f_ap="$APACHE_DIR/$domain.conf"
    local updated=0

    [[ -f $f_ng ]] && { sed -i "s#$old#$new#g" "$f_ng"; log "INFO" "Updated $f_ng"; updated=1; } 
    [[ -f $f_ap ]] && { sed -i "s#$old#$new#g" "$f_ap"; log "INFO" "Updated $f_ap"; updated=1; }

    sqlite3 "$DB_PATH" "UPDATE sites SET path=REPLACE(path, '$old', '$new') WHERE name='$domain';"

    if [[ $updated -eq 1 ]]; then
        echo -e "${GREEN}Updated $domain:${RESET} ${RED}$old${RESET} → ${GREEN}$new${RESET}"
    else
        echo -e "${RED}$domain config missing, not updated${RESET}"
    fi
}

replace_all_paths() {
    local old="$1" new="$2"
    find "$NGINX_DIR" "$APACHE_DIR" -type f -exec sed -i "s#$old#$new#g" {} + -print
    sqlite3 "$DB_PATH" "UPDATE sites SET path=REPLACE(path, '$old', '$new') WHERE path LIKE '$old%';"
    log "INFO" "Replaced all paths from $old to $new"

    # Summary table
    printf "\n%-25s %-50s %-50s %-10s\n" "Domain" "Old Path" "New Path" "Status"
    printf "%-25s %-50s %-50s %-10s\n" "------------------------" "--------------------------------------------------" "--------------------------------------------------" "----------"

    local updated=0 missing=0
    while IFS=$'\t' read -r id name path; do
        [[ -z "$id" ]] && continue
        if [[ -f $NGINX_DIR/$name.conf || -f $APACHE_DIR/$name.conf ]]; then
            printf "%-25s %-50b %-50b %-10s\n" "$name" "$(echo -e "${RED}$old${RESET}")" "$(echo -e "${GREEN}$new${RESET}")" "✅"
            ((updated++))
        else
            printf "%-25s %-50s %-50s %-10b\n" "$name" "$old" "$new" "$(echo -e "${RED}MISSING${RESET}")"
            ((missing++))
        fi
    done < <(sqlite3 -separator $'\t' "$DB_PATH" 'select id,name,path from sites;')
    echo -e "\nUpdated: $updated domains, Missing configs: $missing\n"
}

replace_multi_sites() {
    local domains="$1" old="$2" new="$3"
    for d in $domains; do
        replace_site_path "$d" "$old" "$new"
    done

    # Summary table for selected domains
    printf "\n%-25s %-50s %-50s %-10s\n" "Domain" "Old Path" "New Path" "Status"
    printf "%-25s %-50s %-50s %-10s\n" "------------------------" "--------------------------------------------------" "--------------------------------------------------" "----------"

    local updated=0 missing=0
    for d in $domains; do
        if [[ -f $NGINX_DIR/$d.conf || -f $APACHE_DIR/$d.conf ]]; then
            printf "%-25s %-50b %-50b %-10s\n" "$d" "$(echo -e "${RED}$old${RESET}")" "$(echo -e "${GREEN}$new${RESET}")" "✅"
            ((updated++))
        else
            printf "%-25s %-50s %-50s %-10b\n" "$d" "$old" "$new" "$(echo -e "${RED}MISSING${RESET}")"
            ((missing++))
        fi
    done
    echo -e "\nUpdated: $updated domains, Missing configs: $missing\n"
}

# ====== CONFIG CHECK ======
check_config() {
    local server=$(detect_webserver)
    if [[ $server == "nginx" ]]; then nginx -t
    elif [[ $server == "apache" ]]; then apachectl configtest
    else log "ERROR" "Webserver not detected"; return 1; fi
}

# ====== RESTART WEB SERVER WITH ROLLBACK ======
restart_webserver() {
    local server=$(detect_webserver)
    if check_config; then
        log "INFO" "Config check OK, restarting $server"
        if [[ $server == "nginx" ]]; then
            systemctl restart nginx
            systemctl status nginx --no-pager -l | head -n 10
        else
            systemctl restart httpd 2>/dev/null || systemctl restart apache2
            systemctl status httpd --no-pager -l 2>/dev/null | head -n 10 || systemctl status apache2 --no-pager -l | head -n 10
        fi
    else
        log "ERROR" "Config check failed! Webserver not restarted."
        echo -e "${YELLOW}Rollback to last backup? (y/n)${RESET}"
        read rollback
        [[ "$rollback" == "y" ]] && { log "WARN" "User chose rollback"; restore_configs; } || log "WARN" "Rollback skipped, broken config remains"
    fi
}

# ====== MENU DISPLAY ======
show_menu() {
    clear
    local server_type=$(detect_webserver)
    local now=$(date "+%F %T")
    echo -e "${CYAN}┌───────────────────────────────────────────────┐${RESET}"
    echo -e "${CYAN}│   🛠️  BT SitePath Manager                     │${RESET}"
    echo -e "${CYAN}│   🌐 Webserver: $server_type                   │${RESET}"
    echo -e "${CYAN}│   📅 $now                                   │${RESET}"
    echo -e "${CYAN}└───────────────────────────────────────────────┘${RESET}"
    echo
    echo "1) Backup site configs"
    echo "2) Show current site paths (table, order by id/name/path)"
    echo "3) Replace path for single site"
    echo "4) Replace path for all sites"
    echo "5) Replace path for multiple sites"
    echo "6) Restore last backup"
    echo "7) Restart webserver"
    echo "0) Exit"
    echo
}

# ====== MAIN LOOP ======
while true; do
    show_menu
    read -p "Select option: " choice
    case "$choice" in
        1) backup_configs ;;
        2)
            echo "Order by (id/name/path)? [default: path]: "
            read order
            order=${order:-path}
            show_paths_table "$order"
            ;;
        3)
            read -p "Enter domain: " domain
            read -p "Old path: " old
            read -p "New path: " new
            echo -e "${YELLOW}Do you want to backup first? (y/n)${RESET}"
            read ans
            [[ "$ans" == "y" ]] && backup_configs || { log "WARN" "Backup skipped"; echo -e "${RED}Replacement cancelled${RESET}"; continue; }
            replace_site_path "$domain" "$old" "$new"
            restart_webserver
            ;;
        4)
            read -p "Old path: " old
            read -p "New path: " new
            echo -e "${YELLOW}Do you want to backup first? (y/n)${RESET}"
            read ans
            [[ "$ans" == "y" ]] && backup_configs || { log "WARN" "Backup skipped"; echo -e "${RED}Replacement cancelled${RESET}"; continue; }
            replace_all_paths "$old" "$new"
            restart_webserver
            ;;
        5)
            read -p "Enter domains (space separated): " domains
            read -p "Old path: " old
            read -p "New path: " new
            echo -e "${YELLOW}Do you want to backup first? (y/n)${RESET}"
            read ans
            [[ "$ans" == "y" ]] && backup_configs || { log "WARN" "Backup skipped"; echo -e "${RED}Replacement cancelled${RESET}"; continue; }
            replace_multi_sites "$domains" "$old" "$new"
            restart_webserver
            ;;
        6) restore_configs ;;
        7) restart_webserver ;;
        0) log "INFO" "Exit"; exit 0 ;;
        *) echo -e "${RED}Invalid choice${RESET}" ;;
    esac
    read -p "Press Enter to continue..." tmp
done
