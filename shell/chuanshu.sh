#!/bin/bash

# 接收目标IP:端口作为可选参数
if [[ -n "$1" ]]; then
    dest_input="$1"
else
    read -p "请输入目标服务器 (格式 ip:端口): " dest_input
fi

# 提取IP和端口
dest_svr_ip=$(echo "$dest_input" | cut -d':' -f1)
dest_svr_port=$(echo "$dest_input" | cut -d':' -f2)

# 验证格式
if [[ -z "$dest_svr_ip" || -z "$dest_svr_port" ]]; then
    echo "格式错误，请使用 ip:端口 格式"
    exit 1
fi

transfer_all_with_cache() {
    echo "开始传输所有程序（包含缓存和压缩文件）..."
    rsync -av --progress -e "ssh -p $dest_svr_port" /home/www/wwwroot/ root@$dest_svr_ip:/home/www/wwwroot/
}

transfer_program_exclude_cache_with_config() {
    echo "传输程序（排除缓存，包含配置文件）..."
    rsync -av --progress \
        --exclude='site/*/cache' --exclude='runtime' --exclude='log' \
        -e "ssh -p $dest_svr_port" \
        /home/www/wwwroot/ root@$dest_svr_ip:/home/www/wwwroot/
}

transfer_program_only() {
    echo "仅传输程序（不包含缓存和配置文件）..."
    rsync -av --progress \
        --exclude='site/*' \
        --include='site/' \
        --include='site/default/***' \
        --exclude='runtime' \
        --exclude='log' \
        --exclude='*.conf' \
        --exclude='*.cnf' \
        -e "ssh -p $dest_svr_port" \
        /home/www/wwwroot/ root@$dest_svr_ip:/home/www/wwwroot/
}

transfer_selected_program() {
    echo "扫描文件夹（排除压缩文件）..."

    parent_dir="/home/www/wwwroot"
    exclude_dirs=("cache" "log" "runtime")
    min_size_kb=2  # 1.10KB ≈ 2 个磁盘块
    folder_list=()

    # 遍历顶层目录并编号列出
    index=1
    for dir in "$parent_dir"/*; do
        [ -d "$dir" ] || continue
        dirname=$(basename "$dir")

        # 跳过排除目录
        for excl in "${exclude_dirs[@]}"; do
            if [[ "$dirname" == "$excl" ]]; then
                continue 2
            fi
        done

        # 计算目录大小（排除压缩文件）
        size_kb=$(find "$dir" -maxdepth 2 -type f \
            ! -iname "*.zip" \
            ! -iname "*.tar.gz" \
            ! -iname "*.tgz" \
            ! -iname "*.gz" \
            ! -iname "*.rar" \
            ! -iname "*.7z" \
            ! -iname "*.bz2" \
            -exec du -b {} + 2>/dev/null | awk '{sum+=$1} END {print int(sum/1024)}')

        # 仅显示大小符合要求的目录
        if (( size_kb >= min_size_kb )); then
            echo "$index) $dirname - 大小: ${size_kb}KB"
            folder_list+=("$dirname")  # 添加有效目录
            ((index++))
        fi
    done

    # 让用户按编号选择目录
    echo
    read -p "请输入要传输的目录编号: " folder_index
    
    if [[ "$sel" == "0" ]]; then
        echo "已取消选择。"
        return
    fi
    
    selected_folder="${folder_list[$folder_index-1]}"  # 通过索引获取目录名

    # 如果选择有效，则进行传输
    if [ -n "$selected_folder" ]; then
        full_path="$parent_dir/$selected_folder"
        echo "正在传输 $selected_folder..."
        rsync -av --progress -e "ssh -p $dest_svr_port" "$full_path" root@$dest_svr_ip:/home/www/wwwroot/
    else
        echo "❌ 无效的选择。"
    fi
}


transfer_caiji() {
    echo "查找采集程序目录..."
    caiji_dirs=()
    index=1
    while IFS= read -r dir; do
        echo "$index) $dir"
        caiji_dirs+=("$dir")
        ((index++))
    done < <(find /home -mindepth 1 -maxdepth 2 -type d \( -name "caiji" -o -iname "*caiji*" \))

    if [[ ${#caiji_dirs[@]} -eq 0 ]]; then
        echo "未找到任何采集程序目录。"
        return
    fi

    echo
    read -p "请输入要传输的目录编号（输入 0 返回）: " sel
    if [[ "$sel" == "0" ]]; then
        echo "已取消选择。"
        return
    fi

    selected_dir="${caiji_dirs[$((sel-1))]}"
    if [ -n "$selected_dir" ]; then
        echo "正在传输: $selected_dir"
        rsync -av --progress -e "ssh -p $dest_svr_port" "$selected_dir" root@$dest_svr_ip:"$selected_dir"
    else
        echo "❌ 无效的选择。"
    fi
}


transfer_database() {
    echo "搜索最新数据库备份..."
    latest_file=$(find /home/www/backup/database/mysql/crontab_backup/ -type f -name "*.tar.gz" -printf "%T@ %p\n" 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2)

    if [[ -z "$latest_file" ]]; then
        echo "未找到数据库备份文件。请手动通过面板进行备份。"
    else
        echo "找到备份文件: $latest_file"
        remote_dir=$(dirname "$latest_file")
        ssh -p $dest_svr_port root@$dest_svr_ip "mkdir -p $remote_dir"
        rsync -av --progress -e "ssh -p $dest_svr_port" "$latest_file" root@$dest_svr_ip:"$latest_file"
    fi
}

transfer_baota_menu() {
    echo "请选择宝塔数据传输方式："
    echo "1) 传输所有宝塔数据"
    echo "2) 选择性传输宝塔文件"
    read -p "请输入选项编号: " baota_choice
    case "$baota_choice" in
        1) transfer_baota_all ;;
        2) transfer_baota_selected ;;
        *) echo "无效选项。" ;;
    esac
}

transfer_baota_all() {
    echo "传输宝塔面板全部数据..."
    rsync -av --progress -e "ssh -p $dest_svr_port" /www/server/panel/vhost/ root@$dest_svr_ip:/www/server/panel/vhost/
    rsync -av --progress -e "ssh -p $dest_svr_port" /www/server/panel/data/db/site.db root@$dest_svr_ip:/www/server/panel/data/db/
    rsync -av --progress -e "ssh -p $dest_svr_port" /www/server/panel/data/db/backup.db root@$dest_svr_ip:/www/server/panel/data/db/
    rsync -av --progress -e "ssh -p $dest_svr_port" /www/server/panel/data/db/crontab.db root@$dest_svr_ip:/www/server/panel/data/db/
    rsync -av --progress -e "ssh -p $dest_svr_port" /www/server/panel/data/db/database.db root@$dest_svr_ip:/www/server/panel/data/db/
}

transfer_baota_selected() {
    echo "传输选定的宝塔数据库文件..."
    files=(site.db backup.db crontab.db database.db)
    for i in "${!files[@]}"; do
        echo "$((i+1))) ${files[$i]}"
    done
    read -p "请选择要传输的编号: " index
    file="${files[$((index-1))]}"
    rsync -av --progress -e "ssh -p $dest_svr_port" /www/server/panel/data/db/$file root@$dest_svr_ip:/www/server/panel/data/db/
}

transfer_large_files() {
    echo "查找大型压缩或SQL文件..."
    files=()
    index=1
    while IFS= read -r -d '' file; do
        size_kb=$(du -k "$file" | cut -f1)
        if [[ "$size_kb" -gt 1024 ]]; then
            files+=("$file")
            echo "$index) $file ($((size_kb/1024)) MB)"
            ((index++))
        fi
    done < <(find /home/www/ -maxdepth 2 -type f \( -name "*.gz" -o -name "*.sql" -o -name "*.tar" \) -print0)

    if [ ${#files[@]} -eq 0 ]; then
        echo "未找到符合条件的大文件。"
        return
    fi

    read -p "请输入要传输的文件编号: " sel
    
    if [[ "$sel" == "0" ]]; then
        echo "已取消选择。"
        return
    fi
    
    selected_file="${files[$((sel-1))]}"
    dest_dir=$(dirname "$selected_file")
    ssh -p $dest_svr_port root@$dest_svr_ip "mkdir -p $dest_dir"
    echo "正在传输: $selected_file"
    rsync -av --progress -e "ssh -p $dest_svr_port" "$selected_file" root@$dest_svr_ip:"$selected_file"
}

main_menu() {
    echo "请选择要传输的内容："
    echo "1) 传输 /home/www/wwwroot/ 中的所有程序（包含缓存和压缩文件）"
    echo "2) 排除 site/*/cache、runtime、log（包含配置文件）"
    echo "3) 排除 site/*/cache、runtime、log（不包含配置文件）"
    echo "4) 选择要传输的程序文件夹（大于1.10KB）"
    echo "5) 传输采集程序"
    echo "6) 传输数据库备份文件"
    echo "7) 传输宝塔面板数据"
    echo "8) 传输 /home/www/ 下的大型压缩或SQL文件"
    echo "0) 退出"
    read -p "请输入选项编号: " choice
    case "$choice" in
        1) transfer_all_with_cache ;;
        2) transfer_program_exclude_cache_with_config ;;
        3) transfer_program_only ;;
        4) transfer_selected_program ;;
        5) transfer_caiji ;;
        6) transfer_database ;;
        7) transfer_baota_menu ;;
        8) transfer_large_files ;;
        0) exit 0 ;;
        *) echo "无效选项，请重新输入。" ;;
    esac
}

while true; do
    main_menu
done
