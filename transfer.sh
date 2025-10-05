#!/bin/bash

# Accept dest_ip:port as optional argument
if [[ -n "$1" ]]; then
    dest_input="$1"
else
    # Get destination server IP and port
    read -p "Enter destination server (format ip:port): " dest_input
fi

# Extract IP and port
dest_svr_ip=$(echo "$dest_input" | cut -d':' -f1)
dest_svr_port=$(echo "$dest_input" | cut -d':' -f2)

# Validate
if [[ -z "$dest_svr_ip" || -z "$dest_svr_port" ]]; then
    echo "Invalid format. Please use ip:port format."
    exit 1
fi

# dest_pass=""
# read -p "Enter destination server password: " dest_pass

# Generate SSH key if not exists
if [[ ! -f "$HOME/.ssh/id_rsa" ]]; then
    echo "No SSH key found. Generating one..."
    ssh-keygen -t rsa -b 4096 -N "" -f "$HOME/.ssh/id_rsa"
else
    echo "SSH key already exists at ~/.ssh/id_rsa"
fi

# Upload SSH key to remote server
echo "Uploading SSH key to $dest_user@$dest_svr_ip ..."
ssh-copy-id -p "$dest_svr_port" "root@$dest_svr_ip"

# Test SSH connection
echo "Testing SSH connection..."
if ssh -o BatchMode=yes -p "$dest_svr_port" "root@$dest_svr_ip" true; then
    echo "Passwordless SSH confirmed."
else
    echo "Passwordless SSH setup failed. Please check and try again."
    exit 1
fi

# RSYNC_CMD="rsync -av -e 'ssh -p $dest_svr_port'"

dest_dir="wwwroot"
dest_path="/home/www/$dest_dir"

setup_dir_name() {
    
    read -p "Enter destination server dir name: " dest_dir
    echo "All files will be transfered to $dest_svr_ip:$dest_svr_port/home/www/$dest_dir"
    dest_path="/home/www/$dest_dir"
    ssh -p $dest_svr_port root@$dest_svr_ip "mkdir -p $dest_path"
}

main_menu() {
    echo "-----------------------------------------------------------------------------"
    echo "Current SSH Connection: " $SSH_CONNECTION
    echo "-----------------------------------------------------------------------------"
    echo "Current server IP: $(hostname -I | awk '{print $1}')"
    echo "Destination address: $dest_svr_ip:$dest_svr_port"
    echo "-----------------------------------------------------------------------------"
    echo "Select transfer option:"
    echo "1) Transfer all program in /home/www/wwwroot/ (with cache and compressed files)"
    echo "2) Transfer program excluding site/*/cache, runtime, log (with config files)"
    echo "3) Transfer program excluding site/*/cache, runtime, log (no config files)"
    echo "4) Transfer selected program folders (>1.10KB)"
    echo "5) Transfer caiji programs"
    echo "6) Transfer database files"
    echo "7) Transfer Baota panel data files"
    echo "8) Transfer large compressed or .sql files from /home/www/"
    echo "9) Set up a specific folder (for backup purpose)"
    echo "10) Transfer all site configs (config.php) to $dest_path"
    echo "0) Exit"
    read -p "Enter your choice: " choice
    case "$choice" in
        1) transfer_all_with_cache ;;
        2) transfer_program_exclude_cache_with_config ;;
        3) transfer_program_only ;;
        4) transfer_selected_program ;;
        5) transfer_caiji ;;
        6) transfer_database ;;
        7) transfer_baota_menu ;;
        8) transfer_large_files ;;
        9) setup_dir_name ;;
        10) transfer_site_config ;;
        0) exit 0 ;;
        *) echo "Invalid choice" ;;
    esac
}

transfer_site_config() {
    echo "Transferring all site config (config.php) under /home/www/wwwroot/"
    rsync -av -e "ssh -p $dest_svr_port" --exclude='site/*/cache' --relative /home/www/wwwroot/*/site root@$dest_svr_ip:/home/www/$dest_dir/
    rsync -av -e "ssh -p $dest_svr_port" --exclude='site/*/cache' --relative /home/www/wwwroot/*/public/site root@$dest_svr_ip:/home/www/$dest_dir/
}

transfer_all_with_cache() {
    echo "Transferring everything under /home/www/wwwroot/ (with cache & compressed files)..."
    rsync -av --progress -e "ssh -p $dest_svr_port" /home/www/wwwroot/ root@$dest_svr_ip:/home/www/$dest_dir/
}


transfer_program_exclude_cache_with_config() {
    rsync --exclude='site/*/cache' --exclude='runtime' --exclude='log' -av -e "ssh -p $dest_svr_port" /home/www/wwwroot/ root@$dest_svr_ip:/home/www/$dest_dir/
}

transfer_program_only() {
    echo "Transferring program only (excluding cache/logs/config), but keeping site/default..."

    rsync -av --progress \
        --exclude='site/*' \
        --include='site/' \
        --include='site/default/***' \
        --exclude='runtime' \
        --exclude='log' \
        --exclude='*.conf' \
        --exclude='*.cnf' \
        -e "ssh -p $dest_svr_port" \
        /home/www/wwwroot/ root@$dest_svr_ip:/home/www/$dest_dir/
}


transfer_selected_program() {
    echo "Scanning folders (excluding compressed files)..."

    parent_dir="/home/www/wwwroot"
    exclude_dirs=("cache" "log" "runtime")
    min_size_kb=2  # 1.10KB ≈ 2 blocks
    folder_list=()

    # Loop through top-level directories and list them with numbers
    index=1
    for dir in "$parent_dir"/*; do
        [ -d "$dir" ] || continue
        dirname=$(basename "$dir")

        # Skip excluded folder names
        for excl in "${exclude_dirs[@]}"; do
            if [[ "$dirname" == "$excl" ]]; then
                continue 2
            fi
        done

        # Calculate size excluding compressed files
        size_kb=$(find "$dir" -maxdepth 2 -type f \
            ! -iname "*.zip" \
            ! -iname "*.tar.gz" \
            ! -iname "*.tgz" \
            ! -iname "*.gz" \
            ! -iname "*.rar" \
            ! -iname "*.7z" \
            ! -iname "*.bz2" \
            -exec du -b {} + 2>/dev/null | awk '{sum+=$1} END {print int(sum/1024)}')

        # Show only if size is meaningful
        if (( size_kb >= min_size_kb )); then
            echo "$index) $dirname - Size: ${size_kb}KB"
            folder_list+=("$dirname")  # Add valid folder to list
            ((index++))
        fi
    done

    # Let the user select folder by number
    echo
    read -p "Enter the number of the folder to transfer: " folder_index
    if [[ "$sel" == "0" ]]; then
        echo "Canceled."
        return
    fi
    selected_folder="${folder_list[$folder_index-1]}"  # Get folder name by index

    # Proceed with transfer if valid folder is selected
    if [ -n "$selected_folder" ]; then
        full_path="$parent_dir/$selected_folder"
        echo "Transferring $selected_folder..."
        rsync -av --progress \
            --exclude='runtime' \
            --exclude='site' \
            --exclude='*.tar.gz' \
            --exclude='*.sql' \ 
            -e "ssh -p $dest_svr_port" "$full_path" root@$dest_svr_ip:/home/www/$dest_dir/
    else
        echo "❌ Invalid selection."
    fi
}



transfer_collection() {
    echo "Searching for collection program directories..."
    collection_dirs=()
    index=1
    while IFS= read -r dir; do
        echo "$index) $dir"
        collection_dirs+=("$dir")
        ((index++))
    done < <(find /home -mindepth 1 -maxdepth 2 -type d \( -name "caiji" -o -iname "*caiji*" \))

    if [[ ${#collection_dirs[@]} -eq 0 ]]; then
        echo "No collection program directories found."
        return
    fi

    echo
    read -p "Enter the directory number to transfer (enter 0 to cancel): " sel
    if [[ "$sel" == "0" ]]; then
        echo "Selection cancelled."
        return
    fi

    selected_dir="${collection_dirs[$((sel-1))]}"
    if [ -n "$selected_dir" ]; then
        echo "Transferring: $selected_dir"
        rsync -av --progress -e "ssh -p $dest_svr_port" "$selected_dir" root@$dest_svr_ip:"$selected_dir"
    else
        echo "❌ Invalid selection."
    fi
}


# transfer_database() {
#     echo "Searching for the latest DB backup..."

#     backup_dir="/home/www/backup/database/mysql/crontab_backup"
#     backup_files=($(find "$backup_dir" -type f \( -iname "*.sql.gz" -o -iname "*.tar.gz" \) -print 2>/dev/null))

#     if [ ${#backup_files[@]} -gt 0 ]; then
#         # Sort the files by modification time (newest first)
#         latest_backup=$(ls -t "${backup_files[@]}" | head -n 1)

#         echo "✅ Latest backup found: $latest_backup"

#         # Extract relative subdirectory (e.g., /filmxa)
#         relative_subdir="${latest_backup#$backup_dir}"     # remove base dir
#         relative_subdir_dir=$(dirname "$relative_subdir")  # just the path, no filename

#         # Create matching path on the destination server
#         echo "Creating remote path: /home/www/backup/database/mysql/crontab_backup$relative_subdir_dir"
#         ssh -p $dest_svr_port root@$dest_svr_ip "mkdir -p /home/www/backup/database/mysql/crontab_backup$relative_subdir_dir"

#         # Perform the transfer using rsync
#         echo "Transferring backup to destination..."
#         rsync -av --progress -e "ssh -p $dest_svr_port" "$latest_backup" root@$dest_svr_ip:/home/www/backup/database/mysql/crontab_backup$relative_subdir_dir/

#     else
#         echo "❌ No backup found. Please backup manually via the panel."
#     fi
# }

transfer_database() {
    echo "Searching for the latest DB backup..."

    backup_dir="/home/www/backup/database/mysql/crontab_backup"
    backup_files=($(find "$backup_dir" -type f \( -iname "*.sql.gz" -o -iname "*.tar.gz" \) -print 2>/dev/null))

    if [ ${#backup_files[@]} -gt 0 ]; then
        # Sort the files by modification time (newest first)
        latest_backup=$(ls -t "${backup_files[@]}" | head -n 1)

        echo "✅ Latest backup found: $latest_backup"

        # Extract relative subdirectory (e.g., /filmxa)
        relative_subdir="${latest_backup#$backup_dir}"     # remove base dir
        relative_subdir_dir=$(dirname "$relative_subdir")  # just the path, no filename

        # Create matching path on the destination server
        echo "Creating remote path: /home/www/backup/database/mysql/crontab_backup$relative_subdir_dir"
        ssh -p $dest_svr_port root@$dest_svr_ip "mkdir -p /home/www/backup/database/mysql/crontab_backup$relative_subdir_dir"

        # Perform the transfer using rsync
        echo "Transferring backup to destination..."
        rsync -av --progress -e "ssh -p $dest_svr_port" "$latest_backup" root@$dest_svr_ip:/home/www/backup/database/mysql/crontab_backup$relative_subdir_dir/

    else
        echo "❌ No backup found. Would you like to export all databases now? (y/N)"
        read -r answer
        if [[ "$answer" =~ ^[Yy]$ ]]; then
            export_all_databases
        else
            echo "Cancelled. Please backup manually via the panel."
        fi
    fi
}

export_all_databases() {
    echo "Exporting all databases..."

    # Check if python3 exists
    # if ! command -v python3 >/dev/null 2>&1; then
    #     echo "❌ python3 is not installed. Cannot retrieve MySQL password."
    #     return 1
    # fi

    # Retrieve MySQL root password using Python
    mysql_root_pwd=$(/www/server/panel/pyenv/bin/python -c '
import sys
sys.path.insert(0, "/www/server/panel/class")
import db
sql = db.Sql()
pwd = sql.table("config").where("id=?", (1,)).getField("mysql_root")
print(pwd)
' 2>/dev/null)

    # Check if password is retrieved
    if [ -z "$mysql_root_pwd" ]; then
        echo "❌ Failed to get MySQL root password from panel DB."
        return 1
    fi

    export_dir="/home/www/backup/database/mysql/crontab_backup/manual_export"
    mkdir -p "$export_dir"
    export_file="$export_dir/all_databases_$(date +%F_%H-%M-%S).sql.gz"

    # Export with separate command so we can check return status correctly
    tmp_file=$(mktemp /tmp/all_db_XXXX.sql)

    # mysqldump -uroot -p"$mysql_root_pwd" --all-databases > "$tmp_file"
    
    # Start dump in background
    mysqldump -uroot -p"$mysql_root_pwd" --all-databases > "$tmp_file" &
    dump_pid=$!
    
    # Monitor progress
    while kill -0 $dump_pid 2>/dev/null; do
        filesize=$(du -h "$tmp_file" | awk '{print $1}')
        echo -ne "⏳ Dumping... Current size: $filesize\r"
        sleep 2
    done
    
    wait $dump_pid
    dump_status=$?
    echo ""
    

    if [ $? -ne 0 ]; then
        echo "❌ mysqldump failed. Aborting."
        rm -f "$tmp_file"
        return 1
    fi

    gzip "$tmp_file"
    mv "$tmp_file.gz" "$export_file"
    echo "✅ Exported all databases successfully to $export_file"

    echo "Transfer the exported backup to destination server? (y/N)"
    read -r ans2
    if [[ "$ans2" =~ ^[Yy]$ ]]; then
        ssh -p $dest_svr_port root@$dest_svr_ip "mkdir -p $export_dir"
        rsync -av --progress -e "ssh -p $dest_svr_port" "$export_file" root@$dest_svr_ip:"$export_dir/"
    fi
}



transfer_large_files() {
    echo "🔍 Scanning for large files (*.sql, compressed) in /home/www/ (maxdepth 2)..."

    mapfile -t large_files < <(find /home/www/ -maxdepth 2 -type f \( -iname "*.sql" -o -iname "*.gz" -o -iname "*.zip" -o -iname "*.tar" -o -iname "*.tar.gz" -o -iname "*.7z" -o -iname "*.rar" \) -size +1M 2>/dev/null)

    if [ ${#large_files[@]} -eq 0 ]; then
        echo "❌ No large compressed or SQL files found."
        return
    fi

    echo
    echo "📄 Large files found:"
    index=1
    for file in "${large_files[@]}"; do
        size=$(du -h "$file" | cut -f1)
        echo "$index) $file [$size]"
        ((index++))
    done

    echo
    read -p "Enter the number of the file to transfer: " selected_index
    if [[ "$sel" == "0" ]]; then
        echo "Canceled."
        return
    fi
    selected_file="${large_files[$selected_index-1]}"

    if [ -f "$selected_file" ]; then
        remote_dir=$(dirname "$selected_file")
        ssh -p $dest_svr_port root@$dest_svr_ip "mkdir -p \"$remote_dir\""

        echo "🚀 Transferring $selected_file to $dest_svr_ip..."
        rsync -ah --progress -e "ssh -p $dest_svr_port" "$selected_file" root@$dest_svr_ip:"$selected_file"
    else
        echo "❌ Invalid selection or file no longer exists."
    fi
}


transfer_baota_all() {
    echo "Transferring ALL Baota panel data files..."

   
}


transfer_baota_menu() {
    $dest_path
    echo "Select Baota transfer option:"
    echo "1) Transfer ALL Baota data"
    echo "2) Transfer SELECTED Baota files"
    echo "3) Transfer All Baota data to the backup folder '$dest_path'"
    read -p "Choice: " baota_choice
    case "$baota_choice" in
        1)
            rsync -av -e "ssh -p $dest_svr_port" /www/server/panel/vhost/ root@$dest_svr_ip:/www/server/panel/vhost/
            rsync -av -e "ssh -p $dest_svr_port" /www/server/panel/data/db/ root@$dest_svr_ip:/www/server/panel/data/db/
            ;;
        2)
            rsync -av -e "ssh -p $dest_svr_port" /www/server/panel/vhost/ root@$dest_svr_ip:/www/server/panel/vhost/
            rsync -av -e "ssh -p $dest_svr_port" /www/server/panel/data/db/site.db root@$dest_svr_ip:/www/server/panel/data/db/
            rsync -av -e "ssh -p $dest_svr_port" /www/server/panel/data/db/backup.db root@$dest_svr_ip:/www/server/panel/data/db/
            rsync -av -e "ssh -p $dest_svr_port" /www/server/panel/data/db/crontab.db root@$dest_svr_ip:/www/server/panel/data/db/
            rsync -av -e "ssh -p $dest_svr_port" /www/server/panel/data/db/database.db root@$dest_svr_ip:/www/server/panel/data/db/
            ;;
        3)
            rsync -av -e "ssh -p $dest_svr_port" --relative /www/server/panel/vhost/ root@$dest_svr_ip:$dest_path/
            rsync -av -e "ssh -p $dest_svr_port" --relative /www/server/panel/data/db/ root@$dest_svr_ip:$dest_path/
            ;;
        *)
            echo "Invalid choice."
            ;;
    esac
}

# Loop the menu
while true; do
    main_menu
done
