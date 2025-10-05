#!/bin/bash

BACKUP_DIR="/home/www/backup"
SITECONFIG_DIR="$BACKUP_DIR/siteconfig"
SITECONFIG_TAR="$BACKUP_DIR/siteconfig.tar.gz"
PANEL_PATH="/www/server/panel"
AUTO_BACKUP_DIR="$BACKUP_DIR/panel"

print_menu() {
    echo "===================="
    echo " Panel Backup Menu"
    echo "===================="
    echo "1) Backup"
    echo "2) Restore"
    echo "0) Exit"
    echo "===================="
}

print_restore_menu() {
    echo "========================"
    echo " Restore Options"
    echo "========================"
    echo "1) From manual backup"
    echo "2) From auto backup"
    echo "0) Back to main menu"
    echo "========================"
}

confirm() {
    read -rp "Confirm to proceed? (y/n): " choice
    [[ "$choice" == "y" || "$choice" == "Y" ]]
}

backup_panel() {
    echo "Starting panel backup..."
    mkdir -p "$BACKUP_DIR"

    rsync -av --relative "$PANEL_PATH/vhost" "$SITECONFIG_DIR"
    rsync -av --relative "$PANEL_PATH/data/db" "$SITECONFIG_DIR"
    rm -rfv "$SITECONFIG_DIR/www/server/panel/data/db/script.db"
    rsync -av --exclude='site/*/cache' --relative /home/www/wwwroot/*/site "$SITECONFIG_DIR"
    rsync -av --exclude='site/*/cache' --relative /home/www/wwwroot/*/public/site "$SITECONFIG_DIR"

    tar -czvf "$SITECONFIG_TAR" -C "$BACKUP_DIR" siteconfig
    echo "Backup completed: $SITECONFIG_TAR"
}

restore_manual() {
    echo "Restoring from manual backup..."

    if [[ ! -f "$SITECONFIG_TAR" ]]; then
        echo "Backup file not found: $SITECONFIG_TAR"
        return
    fi

    if confirm; then
        tar -xzvf "$SITECONFIG_TAR" -C "$BACKUP_DIR"
        rsync -av "$SITECONFIG_DIR/www/server/panel/" "$PANEL_PATH/"
        echo "Restore complete from manual backup."
    else
        echo "Restore cancelled."
    fi
}

restore_auto() {
    echo "Restoring from auto backup..."

    if [[ ! -d "$AUTO_BACKUP_DIR" ]]; then
        echo "Auto backup directory not found: $AUTO_BACKUP_DIR"
        return
    fi

    latest_file=$(find "$AUTO_BACKUP_DIR" -maxdepth 1 -type f -printf "%T@ %p\n" | sort -nr | head -n 1 | cut -d' ' -f2-)

    if [[ -z "$latest_file" || ! -f "$latest_file" ]]; then
        echo "No backup file found in $AUTO_BACKUP_DIR"
        return
    fi

    latest_filename=$(basename "$latest_file")
    echo "Latest file: $latest_filename"

    if confirm; then
        unzip -o "$latest_file" -d "$AUTO_BACKUP_DIR"
        filename_no_ext="${latest_filename%.*}"
        echo "Filename without extension: $filename_no_ext"
        rsync -av "$AUTO_BACKUP_DIR/$filename_no_ext/" "$PANEL_PATH/"
        echo "Restore complete from auto backup."
    else
        echo "Restore cancelled."
    fi
}

handle_restore_menu() {
    while true; do
        print_restore_menu
        read -rp "Select a restore option: " sub_opt
        case "$sub_opt" in
            1) restore_manual ;;
            2) restore_auto ;;
            0) break ;;
            *) echo "Invalid selection, please choose again." ;;
        esac
    done
}

# Main loop
while true; do
    print_menu
    read -rp "Select an option: " opt
    case "$opt" in
        1) backup_panel ;;
        2) handle_restore_menu ;;
        0) echo "Exiting."; break ;;
        *) echo "Invalid selection, please choose again." ;;
    esac
done
