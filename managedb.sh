#!/bin/bash

PYTHON_BIN="/www/server/panel/pyenv/bin/python"

# Get MySQL root password from BT Panel
get_mysql_pwd() {
    $PYTHON_BIN - <<'EOF'
import sys
sys.path.insert(0, '/www/server/panel/class')
import db
sql = db.Sql()
pwd = sql.table('config').where('id=?', (1,)).getField('mysql_root')
print(pwd)
EOF
}

# Function to import SQL file with spinner
import_mysql() {
    local file="$1"
    local db="$2"
    local pwd="$3"
    local pid=0

    if [[ "$file" == *.gz ]]; then
        # Run gunzip + mysql in background
        ( gunzip -c "$file" | mysql -uroot -p"$pwd" "$db" ) &
        pid=$!
    else
        # Run plain mysql import in background
        ( mysql -uroot -p"$pwd" "$db" < "$file" ) &
        pid=$!
    fi

    # Spinner animation
    spinner='|/-\'
    i=0
    echo -n "Importing $file "

    while kill -0 "$pid" 2>/dev/null; do
        printf "\b${spinner:i++%${#spinner}:1}"
        sleep 0.2
    done

    wait "$pid"
    echo -e "\b✅ Done!"
}

#!/bin/bash

# export_mysql() {
#     local dbname="$1"
#     local outfile="$2"
#     local pwd="$3"

#     echo -e "\n📦 Exporting database [$dbname]..."

#     # Start export in background
#     ( mysqldump -uroot -p"$pwd" "$dbname" | gzip > "$outfile" ) &
#     local pid=$!

#     # Spinner
#     spinner='|/-\'
#     i=0
#     echo -n "Export in progress "

#     # Start timer
#     start_time=$(date +%s)

#     while kill -0 "$pid" 2>/dev/null; do
#         printf "\b${spinner:i++%${#spinner}:1}"
#         sleep 0.2
#     done

#     wait "$pid"

#     # Calculate elapsed time
#     end_time=$(date +%s)
#     elapsed=$((end_time - start_time))

#     echo -e "\b✅ Export complete: $outfile (Elapsed: ${elapsed}s)"
# }

export_mysql() {
    local dbname="$1"
    local outfile="$2"
    local pwd="$3"

    # Get DB size
    local db_size_bytes=$(mysql -uroot -p"$pwd" -N -e "
    SELECT SUM(data_length + index_length) 
    FROM information_schema.tables 
    WHERE table_schema='$dbname';
    ")
    local db_size_mb=$((db_size_bytes / 1024 / 1024))
    local estimated_time=$((db_size_mb / 33))  # seconds

    # Format time
    current_time=$(date +"%H:%M:%S")
    finish_time=$(date -d "+$estimated_time seconds" +"%H:%M:%S")
    
    echo -e "\n📦 Exporting database [$dbname] (~${db_size_mb} MB, estimated ${estimated_time}s)..."
    echo "⏰ Start: $current_time"
    echo "✅ Estimated finish: $finish_time"


    # Start export in background
    ( mysqldump -uroot -p"$pwd" "$dbname" | gzip > "$outfile" ) &
    local pid=$!

    # Spinner
    spinner='|/-\'
    i=0
    echo -n "Export in progress "

    # Start timer
    local start_time=$(date +%s)

    while kill -0 "$pid" 2>/dev/null; do
        printf "\b${spinner:i++%${#spinner}:1}"
        sleep 0.2
    done

    wait "$pid"

    # Calculate elapsed time
    local end_time=$(date +%s)
    local elapsed=$((end_time - start_time))

    echo -e "\b✅ Export complete: $outfile (Elapsed: ${elapsed}s)"
}

# Usage
# export_mysql "my_database" "/path/to/my_database.sql.gz" "$mysql_pwd"


get_database_config() {
    # Databases configuration in programs
    for f in /home/www/wwwroot/*/application/database.php; do
        site=$(basename "$(dirname "$(dirname "$f")")")   # program folder name
    
        # Extract value when it's a direct string
        db=$(grep -Po "'database'\s*=>\s*'[^']+'" "$f" \
            | sed -E "s/.*'database'\s*=>\s*'([^']+)'.*/\1/" )
    
        # Extract fallback from Env::get(...) if present
        if [ -z "$db" ]; then
            db=$(grep -Po "'database'\s*=>\s*Env::get\([^,]+,\s*'[^']+'" "$f" \
                | sed -E "s/.*,\s*'([^']+)'.*/\1/" )
        fi
    
        echo "$site: $db"
    done
}


mysql_pwd=$(get_mysql_pwd)
if [ -z "$mysql_pwd" ]; then
    echo "❌ Failed to retrieve MySQL root password."
    exit 1
fi

while true; do
    echo -e "\n=== MySQL Management Menu ==="
    echo "1) Show databases"
    echo "2) Export database"
    echo "3) Create database"
    echo "4) Import database"
    echo "5) Create user"
    echo "6) Delete database"
    echo "7) Show database root password"
    echo "8) Login to mysql"
    echo "9) Restart mysql"
    echo "0) Exit"
    read -p "Select an option number: " choice

    case $choice in
        1)
            echo -e "\n📋 Available databases:"
            databases=($(mysql -uroot -p"$mysql_pwd" -e "SHOW DATABASES;" | tail -n +2 | grep -Ev "^(information_schema|mysql|performance_schema|sys)$"))
            for i in "${!databases[@]}"; do
                echo "$((i+1))) ${databases[$i]}"
            done
            echo -e "\n---------------------------------------"
            get_database_config

            ;;
        2)
            echo -e "\n---------------------------------------"
            get_database_config
            
            echo -e "\n📤 Select the number of the database to export:"
            databases=($(mysql -uroot -p"$mysql_pwd" -e "SHOW DATABASES;" | tail -n +2 | grep -Ev "^(information_schema|mysql|performance_schema|sys)$"))
            for i in "${!databases[@]}"; do
                echo "$((i+1))) ${databases[$i]}"
            done
            read -p "Enter number: " db_index
            if ! [[ "$db_index" =~ ^[0-9]+$ ]] || [ "$db_index" -lt 1 ] || [ "$db_index" -gt "${#databases[@]}" ]; then
                echo "❌ Invalid selection. Cancelled."
                continue
            fi
            dbname=${databases[$((db_index-1))]}
            export_dir="/home/www/backup/database/mysql/manual_backup"
            mkdir -p "$export_dir"
            timestamp=$(date +%F_%H-%M-%S)
            outfile="$export_dir/${dbname}_${timestamp}.sql.gz"
            # echo -e "\n📦 Exporting database [$dbname]..."
            # mysqldump -uroot -p"$mysql_pwd" "$dbname" | gzip > "$outfile"
            # echo "✅ Export complete: $outfile"

            export_mysql "$dbname" "$outfile" "$mysql_pwd"
            ;;
        3)
            read -p "Enter the database name to create (leave empty to create default 3): " newdb
            if [ -z "$newdb" ]; then
                echo -e "\n⚙️ Creating default databases:"
                default_dbs=("datahopijwkqv" "filmcyhjsqp" "filmxa0")
                for db in "${default_dbs[@]}"; do
                    mysql -uroot -p"$mysql_pwd" -e "CREATE DATABASE IF NOT EXISTS \`$db\`;"
                    echo "✅ Created: $db"
                done
            else
                mysql -uroot -p"$mysql_pwd" -e "CREATE DATABASE IF NOT EXISTS \`$newdb\`;"
                echo "✅ Database [$newdb] created."
            fi
            ;;
        4)
            echo -e "\n🔍 Searching for .sql or .sql.gz files to import..."
            mapfile -t sql_files < <(find /home/www/backup/database/mysql/ /home/www/ -maxdepth 3 -type f \( -iname "*.sql" -o -iname "*.sql.gz" \) 2>/dev/null)

            if [ "${#sql_files[@]}" -eq 0 ]; then
                echo "❌ No SQL files found."
                continue
            fi

            echo -e "\n📁 Found the following files:"
            for i in "${!sql_files[@]}"; do
                echo "$((i+1))) ${sql_files[$i]}"
            done

            read -p "Enter the number of the file to import: " file_index
            if ! [[ "$file_index" =~ ^[0-9]+$ ]] || [ "$file_index" -lt 1 ] || [ "$file_index" -gt "${#sql_files[@]}" ]; then
                echo "❌ Invalid selection. Cancelled."
                continue
            fi
            import_file="${sql_files[$((file_index-1))]}"

            # echo -e "\n📋 Select target database:"
            # db_list=($(mysql -uroot -p"$mysql_pwd" -e "SHOW DATABASES;" | tail -n +2 | grep -Ev "^(information_schema|mysql|performance_schema|sys)$"))
            # if [ "${#db_list[@]}" -eq 0 ]; then
            #     echo "❌ No databases found. Please create one first."
            #     continue
            # fi
            # for i in "${!db_list[@]}"; do
            #     echo "$((i+1))) ${db_list[$i]}"
            # done

            # read -p "Enter the target database number: " db_index
            # if ! [[ "$db_index" =~ ^[0-9]+$ ]] || [ "$db_index" -lt 1 ] || [ "$db_index" -gt "${#db_list[@]}" ]; then
            #     echo "❌ Invalid database selection."
            #     continue
            # fi
            # target_db="${db_list[$((db_index-1))]}"
            # echo "📥 Importing [$import_file] into [$target_db]..."

            # if [[ "$import_file" == *.gz ]]; then
            #     gunzip -c "$import_file" | mysql -uroot -p"$mysql_pwd" "$target_db"
            # else
            #     mysql -uroot -p"$mysql_pwd" "$target_db" < "$import_file"
            # fi

            # echo "✅ Import complete."
            
            echo -e "\n📋 Select target database:"
            db_list=($(mysql -uroot -p"$mysql_pwd" -e "SHOW DATABASES;" | tail -n +2 | grep -Ev "^(information_schema|mysql|performance_schema|sys)$"))
            if [ "${#db_list[@]}" -eq 0 ]; then
                echo "❌ No databases found. Please create one first."
                continue
            fi
            for i in "${!db_list[@]}"; do
                echo "$((i+1))) ${db_list[$i]}"
            done
            
            read -p "Enter the target database number: " db_index
            if ! [[ "$db_index" =~ ^[0-9]+$ ]] || [ "$db_index" -lt 1 ] || [ "$db_index" -gt "${#db_list[@]}" ]; then
                echo "❌ Invalid database selection."
                continue
            fi
            target_db="${db_list[$((db_index-1))]}"
            echo "📥 Importing [$import_file] into [$target_db]..."
            
            # Measure file size and estimate time
            size=$(stat -c %s "$import_file")
            size_mb=$((size / 1024 / 1024))
            time_consum=$((size_mb / 102))
            echo "📊 File size: ${size_mb} MB. Estimated time: ~${time_consum} minutes"
            
            # Show start and estimated finish times
            current_time=$(date +"%H:%M:%S")
            finish_time=$(date -d "+$time_consum minutes" +"%H:%M:%S")
            echo "⏰ Start: $current_time"
            echo "✅ Estimated finish: $finish_time"

            
            # Record start time
            time_start=$(date +%s)

            # Import with verbose
            # if [[ "$import_file" == *.gz ]]; then
            #     gunzip -c "$import_file" | mysql -uroot -p"$mysql_pwd" "$target_db"
            # else
            #     mysql -uroot -p"$mysql_pwd" "$target_db" < "$import_file"
            # fi
            
            import_mysql "$import_file" "$target_db" "$mysql_pwd"

            # Record end time
            time_end=$(date +%s)
            duration=$((time_end - time_start))
            
            # Print duration in minutes and seconds
            minutes=$((duration / 60))
            seconds=$((duration % 60))
            echo "✅ Import complete. Time consumed: ${minutes}m ${seconds}s"

            ;;
        # 5)
        #     read -p "Enter new MySQL username: " user
        #     read -p "Enter password for [$user]: " pass
        #     mysql -uroot -p"$mysql_pwd" -e "CREATE USER '$user'@'localhost' IDENTIFIED BY '$pass'; GRANT ALL PRIVILEGES ON *.* TO '$user'@'localhost' WITH GRANT OPTION; FLUSH PRIVILEGES;"
        #     echo "✅ User [$user] created and granted full privileges."
        #     ;;
        5)
            # Default credentials
            default_user="bwbkouaxib"
            default_pass="sFa4ZpL9177JSWki"
        
            # Ask for new user/pass
            read -p "Enter new MySQL username (default: $default_user): " user
            read -p "Enter password for [${user:-$default_user}] (default hidden): " pass
        
            # If empty, use default
            user=${user:-$default_user}
            pass=${pass:-$default_pass}
        
            mysql -uroot -p"$mysql_pwd" -e "CREATE USER '$user'@'localhost' IDENTIFIED BY '$pass';
                GRANT ALL PRIVILEGES ON *.* TO '$user'@'localhost' WITH GRANT OPTION;
                FLUSH PRIVILEGES;"
        
            echo "✅ User [$user] created (default used if input empty)."
            ;;

        6)
            echo -e "\n⚠️ WARNING: This will permanently delete a database!"
            db_list=($(mysql -uroot -p"$mysql_pwd" -e "SHOW DATABASES;" | tail -n +2 | grep -Ev "^(information_schema|mysql|performance_schema|sys)$"))
            if [ "${#db_list[@]}" -eq 0 ]; then
                echo "❌ No deletable databases found."
                continue
            fi

            echo -e "\n📋 Databases available for deletion:"
            for i in "${!db_list[@]}"; do
                echo "$((i+1))) ${db_list[$i]}"
            done

            read -p "Enter the number of the database to delete: " db_index
            if ! [[ "$db_index" =~ ^[0-9]+$ ]] || [ "$db_index" -lt 1 ] || [ "$db_index" -gt "${#db_list[@]}" ]; then
                echo "❌ Invalid selection. Cancelled."
                continue
            fi

            del_db="${db_list[$((db_index-1))]}"
            echo -e "\n⚠️ You are about to delete [$del_db]!"
            read -p "To confirm, type: DELETE DATABASE : " confirm
            if [ "$confirm" != "DELETE DATABASE" ]; then
                echo "❌ Confirmation failed. Operation cancelled."
                continue
            fi

            mysql -uroot -p"$mysql_pwd" -e "DROP DATABASE \`$del_db\`;"
            echo "✅ Database [$del_db] has been deleted."

            echo -e "\n📋 Remaining databases:"
            updated_dbs=($(mysql -uroot -p"$mysql_pwd" -e "SHOW DATABASES;" | tail -n +2 | grep -Ev "^(information_schema|mysql|performance_schema|sys)$"))
            for i in "${!updated_dbs[@]}"; do
                echo "$((i+1))) ${updated_dbs[$i]}"
            done
            ;;
        7)
            echo "$mysql_pwd"
            ;;
        8)
            mysql -uroot -p"$mysql_pwd"
            ;;
        9)
            service mysql restart
            systemctl mysql restart
            ;;
        0)
            echo "👋 Goodbye."
            break
            ;;
        *)
            echo "⚠️ Invalid option. Please try again."
            ;;
    esac
done
