#!/bin/bash

PYTHON_BIN="/www/server/panel/pyenv/bin/python"

# Function to get MySQL root password from BT Panel
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


mysql_pwd=$(get_mysql_pwd)
if [ -z "$mysql_pwd" ]; then
    echo "❌ Failed to retrieve MySQL root password."
    exit 1
fi

while true; do
    echo -e "\n=== MySQL 管理菜单 ==="
    echo "1) 显示数据库"
    echo "2) 导出数据库"
    echo "3) 创建数据库"
    echo "4) 导入数据库"
    echo "5) 创建用户"
    echo "6) 删除数据库"

    echo "0) 退出"
    read -p "请选择操作编号: " choice

    case $choice in
        1)
            echo -e "\n📋 当前数据库列表："
            databases=($(mysql -uroot -p"$mysql_pwd" -e "SHOW DATABASES;" | tail -n +2 | grep -Ev "^(information_schema|mysql|performance_schema|sys)$"))
            for i in "${!databases[@]}"; do
                echo "$((i+1))) ${databases[$i]}"
            done
            ;;
        2)
            echo -e "\n📤 请选择要导出的数据库编号："
            databases=($(mysql -uroot -p"$mysql_pwd" -e "SHOW DATABASES;" | tail -n +2 | grep -Ev "^(information_schema|mysql|performance_schema|sys)$"))
            for i in "${!databases[@]}"; do
                echo "$((i+1))) ${databases[$i]}"
            done
            read -p "输入编号: " db_index

            # Check for valid numeric input
            if ! [[ "$db_index" =~ ^[0-9]+$ ]] || [ "$db_index" -lt 1 ] || [ "$db_index" -gt "${#databases[@]}" ]; then
                echo "❌ 无效编号，操作已取消。"
                continue
            fi
            
            dbname=${databases[$((db_index-1))]}



            export_dir="/www/backup/database/mysql/manual_backup"
            mkdir -p "$export_dir"
            timestamp=$(date +%F_%H-%M-%S)
            outfile="$export_dir/${dbname}_${timestamp}.sql.gz"
            echo -e "\n📦 正在导出数据库 [$dbname]..."
            mysqldump -uroot -p"$mysql_pwd" "$dbname" | gzip > "$outfile"
            echo "✅ 导出完成: $outfile"
            ;;
        3)
            read -p "输入要创建的数据库名称（留空将自动创建默认数据库）: " newdb

            if [ -z "$newdb" ]; then
                echo -e "\n⚙️ 创建默认数据库："
                default_dbs=("datahopijwkqv" "filmcyhjsqp" "filmxa0")
                for db in "${default_dbs[@]}"; do
                    mysql -uroot -p"$mysql_pwd" -e "CREATE DATABASE IF NOT EXISTS \`$db\`;"
                    echo "✅ 已创建: $db"
                done
            else
                mysql -uroot -p"$mysql_pwd" -e "CREATE DATABASE IF NOT EXISTS \`$newdb\`;"
                echo "✅ 数据库 [$newdb] 已创建"
            fi
            
            # Show remaining databases
            echo -e "\n📋 当前数据库列表（更新后）:"
            updated_dbs=($(mysql -uroot -p"$mysql_pwd" -e "SHOW DATABASES;" | tail -n +2 | grep -Ev "^(information_schema|mysql|performance_schema|sys)$"))
            for i in "${!updated_dbs[@]}"; do
                echo "$((i+1))) ${updated_dbs[$i]}"
            done
            ;;

        4)
            echo -e "\n🔍 正在查找数据库备份文件（.sql/.sql.gz）..."
            mapfile -t sql_files < <(find /www/backup/database/mysql/ /home/www/ -maxdepth 3 -type f \( -iname "*.sql" -o -iname "*.sql.gz" \) 2>/dev/null)

            if [ "${#sql_files[@]}" -eq 0 ]; then
                echo "❌ 未找到任何 SQL 文件。"
                continue
            fi

            echo -e "\n📁 找到以下 SQL 文件："
            for i in "${!sql_files[@]}"; do
                echo "$((i+1))) ${sql_files[$i]}"
            done

            read -p "请输入要导入的文件编号: " file_index

            if ! [[ "$file_index" =~ ^[0-9]+$ ]] || [ "$file_index" -lt 1 ] || [ "$file_index" -gt "${#sql_files[@]}" ]; then
                echo "❌ 无效编号，操作已取消。"
                continue
            fi

            import_file="${sql_files[$((file_index-1))]}"
            # read -p "输入目标数据库名称: " target_db
            
            # Show available databases to import into
            echo -e "\n📋 可用数据库列表："
            db_list=($(mysql -uroot -p"$mysql_pwd" -e "SHOW DATABASES;" | tail -n +2 | grep -Ev "^(information_schema|mysql|performance_schema|sys)$"))
            if [ "${#db_list[@]}" -eq 0 ]; then
                echo "❌ 未找到可用数据库，请先创建一个。"
                continue
            fi

            for i in "${!db_list[@]}"; do
                echo "$((i+1))) ${db_list[$i]}"
            done

            read -p "请选择导入目标数据库编号: " db_index
            if ! [[ "$db_index" =~ ^[0-9]+$ ]] || [ "$db_index" -lt 1 ] || [ "$db_index" -gt "${#db_list[@]}" ]; then
                echo "❌ 无效编号，操作已取消。"
                continue
            fi

            target_db="${db_list[$((db_index-1))]}"


            echo "📥 正在将 [$import_file] 导入到数据库 [$target_db]..."

            if [[ "$import_file" == *.gz ]]; then
                gunzip -c "$import_file" | mysql -uroot -p"$mysql_pwd" "$target_db"
            else
                mysql -uroot -p"$mysql_pwd" "$target_db" < "$import_file"
            fi

            echo "✅ 导入完成"
            ;;

        5)
            read -p "输入新用户名: " user
            read -p "输入密码: " pass
            mysql -uroot -p"$mysql_pwd" -e "CREATE USER '$user'@'localhost' IDENTIFIED BY '$pass'; GRANT ALL PRIVILEGES ON *.* TO '$user'@'localhost' WITH GRANT OPTION; FLUSH PRIVILEGES;"
            echo "✅ 用户 [$user] 已创建并授予权限"
            ;;
        6)
            echo -e "\n⚠️ 注意：该操作将永久删除数据库！"
            db_list=($(mysql -uroot -p"$mysql_pwd" -e "SHOW DATABASES;" | tail -n +2 | grep -Ev "^(information_schema|mysql|performance_schema|sys)$"))
            if [ "${#db_list[@]}" -eq 0 ]; then
                echo "❌ 未找到可删除的数据库。"
                continue
            fi

            echo -e "\n📋 可删除数据库列表："
            for i in "${!db_list[@]}"; do
                echo "$((i+1))) ${db_list[$i]}"
            done

            read -p "请输入要删除的数据库编号: " db_index
            if ! [[ "$db_index" =~ ^[0-9]+$ ]] || [ "$db_index" -lt 1 ] || [ "$db_index" -gt "${#db_list[@]}" ]; then
                echo "❌ 无效编号，操作已取消。"
                continue
            fi

            del_db="${db_list[$((db_index-1))]}"
            echo -e "\n⚠️ 即将删除数据库 [$del_db]！"
            read -p "请手动输入“删除数据库”以确认操作: " confirm
            if [ "$confirm" != "删除数据库" ]; then
                echo "❌ 输入不匹配，删除操作已取消。"
                continue
            fi

            mysql -uroot -p"$mysql_pwd" -e "DROP DATABASE \`$del_db\`;"
            echo "✅ 数据库 [$del_db] 已成功删除。"
            
            # Show remaining databases
            echo -e "\n📋 当前数据库列表（更新后）:"
            updated_dbs=($(mysql -uroot -p"$mysql_pwd" -e "SHOW DATABASES;" | tail -n +2 | grep -Ev "^(information_schema|mysql|performance_schema|sys)$"))
            for i in "${!updated_dbs[@]}"; do
                echo "$((i+1))) ${updated_dbs[$i]}"
            done
            ;;

        0)
            echo "👋 退出"
            break
            ;;
        *)
            echo "⚠️ 无效选项，请重新选择。"
            ;;
    esac
done
