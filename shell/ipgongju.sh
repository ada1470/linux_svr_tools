#!/bin/bash

# 可配置变量
TOP_IP_COUNT=200  # 要分析的IP数量，可根据需要修改（例如：20, 50, 200, 500）
TOP_IP_ANALYSE=10
TOP_RANGE_COUNT=20

LOG_DIR="/www/wwwlogs"
BACKUP_DIR="/home/www/backup/firewall"
SPIDER_WHITELIST_REGEX="baiduspider|sogouspider|bytespider|shenmaspider|hn.kd.ny.adsl|petal"
TMP_IP_LIST="/tmp/top_ips.txt"
# 存储标记IP和网段的临时文件
IPS_TO_BLOCK_FILE="/tmp/ips_to_block.txt"
RANGES_TO_BLOCK_FILE="/tmp/ranges_to_block.txt"

# 检测可用的Python命令
PYTHON_CMD=""
for cmd in python3 python py; do
    if command -v "$cmd" >/dev/null 2>&1; then
        PYTHON_CMD="$cmd"
        break
    fi
done

# 检测服务器类型（nginx或apache）
detect_server_type() {
    if pgrep -x "nginx" >/dev/null; then
        SERVER_TYPE="nginx"
    elif pgrep -x "httpd" >/dev/null || pgrep -x "apache2" >/dev/null; then
        SERVER_TYPE="apache"
    else
        echo "无法检测服务器类型。"
        systemctl status nginx || systemctl status httpd || systemctl status apache2
        service nginx status
        service httpd status
        
        read -p "是否要重启Web服务器？ [y/N]: " confirm
        confirm=${confirm,,}  # 转换为小写

        if [[ "$confirm" == "y" || "$confirm" == "yes" ]]; then
            restart_web_server
        fi
        
        exit 1
    fi
}

if [[ "$SERVER_TYPE" == "nginx" || -z "$SERVER_TYPE" ]]; then
    LOG_FILES="$LOG_DIR"/*.log
else
    LOG_FILES="$LOG_DIR"/*access_log
fi

# 清理日志功能
clean_logs() {
    echo "正在清理日志..."
    find "$LOG_DIR" -maxdepth 1 -type f \( -name "*.log" -o -name "*_log" \) -exec rm -v {} \;

    restart_web_server
}

# 分析日志并生成IP和网段列表
analyze_logs() {
     echo "正在为 $SERVER_TYPE 分析日志..."

    # 清除之前的数据
    > "$IPS_TO_BLOCK_FILE"
    > "$RANGES_TO_BLOCK_FILE"
    
    awk '{ print $1 }' $LOG_FILES | sort | uniq -c | sort -nr | head -n "$TOP_IP_COUNT" > "$TMP_IP_LIST"
    
    # 删除不包含有效IPv4地址的行
    sed -i '/[0-9]\{1,3\}\(\.[0-9]\{1,3\}\)\{3\}/!d' "$TMP_IP_LIST"

    echo -e "\n== 标记前 $TOP_IP_ANALYSE 个独立IP =="

    # 标记IP并写入IPS_TO_BLOCK_FILE
    head -n "$TOP_IP_ANALYSE" "$TMP_IP_LIST" | while read -r count ip; do
        annotate_ip "$ip" "$count"
    done

    echo -e "\nTop IP 网段:"
    awk '$2 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ { print $1, $2 }' "$TMP_IP_LIST" | \
    awk '
    {
        split($2, ip, ".")
        range = ip[1]"."ip[2]"."ip[3]".0/24"
        count[range] += $1
        key = range "_" $2
        if (!seen[key]++) {
            unique_count[range]++
        }
    }
    END {
        for (r in count) {
            if (unique_count[r] > 1) {
                printf "%-18s %6d 请求来自 %3d 个独立IP\n", r, count[r], unique_count[r]
            }
        }
    }' | sort -k2 -nr | head -n "$TOP_RANGE_COUNT" | tee /tmp/ip_range_summary

    echo -e "\n== 标记IP网段 =="

    # 标记IP网段并写入RANGES_TO_BLOCK_FILE
    while read -r range; do
        annotate_ip "$range" "$count_line"
    done < <(cut -d' ' -f1 /tmp/ip_range_summary)
    
    echo -e "\n== Top 引用域名 =="
        
    awk -F'"' '{print $4}' $LOG_FILES | \
        awk -F/ '/^https?:\/\// {print $3}' | \
        grep -vE '^(-|localhost|127\.0\.0\.1)$' | \
        sort | uniq -c | sort -nr | head -n 20
        
    echo -e "\n== Top 错误IP =="
    
}


is_whitelisted_btwaf() {
    local ip="$1"
    
    ip_to_int() {
        local IFS=.
        read -r o1 o2 o3 o4 <<< "$1"
        echo $(( (o1 << 24) + (o2 << 16) + (o3 << 8) + o4 ))
    }

    is_ip_in_cidr() {
        local ip="$1"
        local cidr="$2"

        IFS=/ read -r subnet mask <<< "$cidr"
        ip_int=$(ip_to_int "$ip")
        subnet_int=$(ip_to_int "$subnet")
        mask_bits=$(( 0xFFFFFFFF << (32 - mask) & 0xFFFFFFFF ))

        if (( (ip_int & mask_bits) == (subnet_int & mask_bits) )); then
            return 0
        else
            return 1
        fi
    }

    ip_int=$(ip_to_int "$ip")

    for w in "${WHITELISTED_IPS[@]}"; do
        w=$(echo "$w" | xargs)  # trim spaces

        if [[ "$w" == *"/"* ]]; then
            # CIDR format
            if is_ip_in_cidr "$ip" "$w"; then
                return 0
            fi

        elif [[ "$w" == *"-"* ]]; then
            # IP range
            IFS='-' read -r start end <<< "$w"
            start=$(echo "$start" | xargs)
            end=$(echo "$end" | xargs)
            start_int=$(ip_to_int "$start")
            end_int=$(ip_to_int "$end")
            if (( ip_int >= start_int && ip_int <= end_int )); then
                return 0
            fi

        else
            # Single IP
            if [[ "$w" == "$ip" ]]; then
                return 0
            fi
        fi
    done

    return 1
}



# 标记IP功能
annotate_ip() {
    local ip="$1"
    local count="$2"
    local annotation=""

    # 检查是否为完整IPv4地址
    if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        # 首先检查 IP 或其 /24 范围是否在防火墙黑白名单中
        range=$(echo "$ip" | sed -E 's#([0-9]+\.[0-9]+\.[0-9]+)\.[0-9]+#\1.0/24#')
        # if firewall-cmd --list-rich-rules | grep -qE "$ip|$range"; then
        #     annotation="防火墙黑白名单"
                # echo "firewall-cmd --list-rich-rules | grep -Eq $ip\|$range"
        firewall_entry=$(firewall-cmd --list-rich-rules | grep -E "$ip|$range")

        # echo $firewall_entry
        if [[ -n "$firewall_entry" ]]; then
            if echo "$firewall_entry" | grep -qE '\baccept\b|\ballow\b'; then
                annotation="防火墙[白]名单"
            elif echo "$firewall_entry" | grep -qE '\bdrop\b|\breject\b'; then
                annotation="防火墙[黑]名单"
            else
                annotation="防火墙已列入"
            fi
        elif is_whitelisted_btwaf "$ip"; then
            annotation="BTWAF白名单"
        elif host_info=$(getent hosts "$ip"); then
            if echo "$host_info" | grep -Eiq "$SPIDER_WHITELIST_REGEX"; then
                annotation=$(echo "$host_info" | grep -Eo "$SPIDER_WHITELIST_REGEX" | head -n 1)
                annotation="$annotation (白名单蜘蛛)"
            else
                domain=$(echo "$host_info" | awk '{print $2}')
                annotation="$domain (恶意爬虫)"
            fi
        else
            annotation="未知"
        fi


        # 写入前检查权限
        if [[ -w "$IPS_TO_BLOCK_FILE" || ! -e "$IPS_TO_BLOCK_FILE" && -w "$(dirname "$IPS_TO_BLOCK_FILE")" ]]; then
            echo "$count - $ip => $annotation" | tee -a "$IPS_TO_BLOCK_FILE"
        else
            echo "错误: 无法写入 $IPS_TO_BLOCK_FILE" >&2
        fi

    else
        local ip_base=$(echo "$ip" | cut -d'/' -f1 | cut -d. -f1-3)
        local sample_ip="$ip_base.1"
        annotation="未知"

        # if firewall-cmd --list-rich-rules | grep -Eq "$ip"; then
        #     annotation="防火墙黑白名单"
        firewall_entry=$(firewall-cmd --list-rich-rules | grep -E "$ip";)
        
        if [[ -n "$firewall_entry" ]]; then
            if echo "$firewall_entry" | grep -qE '\baccept\b|\ballow\b'; then
                annotation="防火墙[白]名单"
            elif echo "$firewall_entry" | grep -qE '\bdrop\b|\breject\b'; then
                annotation="防火墙[黑]名单"
            else
                annotation="防火墙已列入"
            fi
        elif is_whitelisted_btwaf "$ip"; then
            annotation="BTWAF白名单"
        elif host_entry=$(getent hosts "$sample_ip"); then
            if echo "$host_entry" | grep -Eiq "$SPIDER_WHITELIST_REGEX"; then
                spider_name=$(echo "$host_entry" | grep -Eio "$SPIDER_WHITELIST_REGEX" | head -n 1)
                annotation="$spider_name (爬虫白名单)"
            else
                domain=$(echo "$host_entry" | awk '{print $2}')
                annotation="$domain (未列出的爬虫)"
            fi
        fi

        # 写入前检查权限
        if [[ -w "$RANGES_TO_BLOCK_FILE" || ! -e "$RANGES_TO_BLOCK_FILE" && -w "$(dirname "$RANGES_TO_BLOCK_FILE")" ]]; then
            echo "$ip => $annotation" | tee -a "$RANGES_TO_BLOCK_FILE"
        else
            echo "错误: 无法写入 $RANGES_TO_BLOCK_FILE" >&2
        fi
    fi
}


check_and_load_btwaf_whitelist() {
    local whitelist_file="/www/server/btwaf/rule/ip_white.json"

    if [[ ! -s "$whitelist_file" ]]; then
        echo "⚠️ 未找到白名单文件或文件为空: $whitelist_file"
        return
    fi

    # echo "== 从 BTWAF 加载 IP 白名单 =="

    WHITELISTED_IPS=()

    "$PYTHON_CMD" - <<EOF
# -*- coding: utf-8 -*-
import json
import socket
import struct
import sys

def int_to_ip(ip):
    return socket.inet_ntoa(struct.pack("!I", ip))

def list_to_ip(octets):
    return ".".join(str(i) for i in octets)

try:
    with open("$whitelist_file") as f:
        data = json.load(f)

    with open("/tmp/btwaf_ip_whitelist.txt", "w") as out:
        for entry in data:
            if isinstance(entry, list) and len(entry) == 2:
                start, end = entry[0], entry[1]

                # Case: [int, int]
                if isinstance(start, int) and isinstance(end, int):
                    ip1 = int_to_ip(start)
                    ip2 = int_to_ip(end)

                # Case: [[x,x,x,x], [x,x,x,x]]
                elif (
                    isinstance(start, list) and len(start) == 4 and
                    isinstance(end, list) and len(end) == 4
                ):
                    ip1 = list_to_ip(start)
                    ip2 = list_to_ip(end)

                else:
                    continue  # unsupported entry format

                if ip1 == ip2:
                    out.write(ip1 + "\n")
                else:
                    out.write(ip1 + " - " + ip2 + "\n")

except Exception as e:
    sys.stderr.write("解析白名单失败: %s\n" % e)
EOF


    mapfile -t WHITELISTED_IPS < /tmp/btwaf_ip_whitelist.txt
}

# 根据分析结果封锁可疑IP
block_ip() {
    echo "正在封锁未在白名单中的高请求IP..."

    # 收集要封锁的IP和网段
    ips_to_block=()
    ranges_to_block=()

    # 从标记为"未知"或"未列出的爬虫"的文件中收集IP
    echo -e "\n== 收集要封锁的标记IP =="

    while read -r line; do
        ip=$(echo "$line" | awk '{print $3}')
        annotation=$(echo "$line" | cut -d'>' -f2- | sed 's/^ *//')
    
        if [[ "$annotation" == *"未知"* || "$annotation" == *"未列出的爬虫"* ]]; then
            ips_to_block+=("$ip")
        fi
    done < "$IPS_TO_BLOCK_FILE"

    # 从标记为"未知"或"未列出的爬虫"的文件中收集IP网段
    echo -e "\n== 收集要封锁的标记IP网段 =="

    while read -r line; do
        ip_base=$(echo "$line" | awk '{print $1}')
        annotation=$(echo "$line" | cut -d'>' -f2- | sed 's/^ *//')
    
        if [[ "$annotation" == *"未知"* || "$annotation" == *"未列出的爬虫"* ]]; then
            ranges_to_block+=("$ip_base")
        fi
    done < "$RANGES_TO_BLOCK_FILE"

    # 显示要封锁的IP和网段并确认
    if [[ ${#ips_to_block[@]} -gt 0 ]]; then
        echo -e "\n== 要封锁的IP: =="
        for ip in "${ips_to_block[@]}"; do
            echo "$ip"
        done

        echo -e "\n要封锁这些IP吗？ [y/N]: "
        read -r confirm_ips
        if [[ "$confirm_ips" =~ ^[Yy]$ ]]; then
            for ip in "${ips_to_block[@]}"; do
                # 使用firewall-cmd封锁IP
                echo "正在封锁IP: $ip"
                firewall-cmd --permanent --add-rich-rule="rule family='ipv4' source address='$ip' drop"

                # 添加到firewall_ip表并记录时间戳
                sqlite3 /www/server/panel/data/db/firewall.db \
                    "INSERT INTO firewall_ip (types, address, brief, addtime, chain) VALUES ('drop', '$ip', '脚本封锁', strftime('%Y-%m-%d %H:%M:%S', 'now'), 'INPUT');"

                echo "成功封锁 $ip 并记录到数据库。"
            done
        fi
    fi

    if [[ ${#ranges_to_block[@]} -gt 0 ]]; then
        echo -e "\n== 要封锁的IP网段: =="
        for range in "${ranges_to_block[@]}"; do
            echo "$range"
        done

        echo -e "\n要封锁这些IP网段吗？ [y/N]: "
        read -r confirm_ranges
        if [[ "$confirm_ranges" =~ ^[Yy]$ ]]; then
            for range in "${ranges_to_block[@]}"; do
                # 使用firewall-cmd封锁网段
                echo "正在封锁网段: $range"
                firewall-cmd --permanent --add-rich-rule="rule family='ipv4' source address='$range' drop"

                # 添加到firewall_ip表并记录时间戳
                sqlite3 /www/server/panel/data/db/firewall.db \
                    "INSERT INTO firewall_ip (types, address, brief, addtime, chain) VALUES ('drop', '$range', '脚本封锁', strftime('%Y-%m-%d %H:%M:%S', 'now'), 'INPUT');"

                echo "成功封锁 $range 并记录到数据库。"
            done
        fi
    fi

    # 重新加载防火墙以应用更改
    echo -e "\n正在重新加载防火墙..."
    firewall-cmd --reload
}

# 编辑防火墙IP规则
edit_firewall_ip_rules() {
    echo "正在编辑防火墙IP规则..."

    # 显示当前防火墙规则及索引
    echo -e "\n== 当前防火墙IP规则 =="
    firewall-cmd --list-rich-rules | nl -s '. '

    echo -e "\n输入要删除的规则索引范围（例如：3-5 删除索引3到5的规则）:"
    read -r index_range

    # 验证输入格式
    if [[ "$index_range" =~ ^[0-9]+-[0-9]+$ ]]; then
        # 解析起始和结束索引
        start_index=$(echo "$index_range" | cut -d'-' -f1)
        end_index=$(echo "$index_range" | cut -d'-' -f2)

        # 验证索引
        if [[ $start_index -le $end_index ]]; then
            echo -e "\n正在删除索引 $start_index 到 $end_index 的规则..."

            # 列出所有富规则及索引
            rules=$(firewall-cmd --list-rich-rules)

            # 将规则分割为数组
            IFS=$'\n' read -r -d '' -a rule_array <<< "$rules"

            # 删除选定的规则范围
            for ((i = start_index - 1; i < end_index; i++)); do
                rule=${rule_array[$i]}
                if [[ -n "$rule" ]]; then
                    echo "正在删除规则: $rule"
                    
                    # 从规则中提取IP或网段
                    ip_or_range=$(echo "$rule" | sed -n 's/.*source address="\([^"]*\)".*/\1/p')

                    # 从防火墙中删除规则
                    firewall-cmd --permanent --remove-rich-rule="$rule"

                    # 从数据库中删除对应条目
                    sqlite3 /www/server/panel/data/db/firewall.db \
                        "DELETE FROM firewall_ip WHERE address = '$ip_or_range';"

                    echo "已从防火墙和数据库中删除 $ip_or_range 的规则。"
                fi
            done

            # 重新加载防火墙以应用更改
            echo -e "\n正在重新加载防火墙..."
            firewall-cmd --reload
            echo "防火墙规则更新成功。"
        else
            echo "无效范围。起始索引必须小于或等于结束索引。"
        fi
    else
        echo "无效输入。请输入有效范围（例如：3-5）。"
    fi
}

# 同步防火墙IP规则
sync_firewall_ip_rules() {
    echo "准备从firewall.db同步IP规则到firewalld..."

    # 获取当前富规则
    current_rules=$(firewall-cmd --list-rich-rules)

    # 从数据库查询所有IP规则
    mapfile -t ip_entries < <(sqlite3 /www/server/panel/data/db/firewall.db \
        "SELECT types, address FROM firewall_ip WHERE address != ''")

    declare -a rules_to_add

    echo -e "\n== 要添加的候选规则 =="

    for entry in "${ip_entries[@]}"; do
        types=$(echo "$entry" | cut -d'|' -f1)
        ip=$(echo "$entry" | cut -d'|' -f2)

        [[ -z "$ip" ]] && continue

        # 确定动作：drop或accept
        if [[ "$types" == "drop" ]]; then
            action="drop"
        else
            action="accept"
        fi

        rule="rule family=\"ipv4\" source address=\"$ip\" $action"

        # 检查规则是否已存在
        if ! grep -Fxq "$rule" <<< "$current_rules"; then
            echo "$rule"
            rules_to_add+=("$rule")
        fi
    done

    if [[ ${#rules_to_add[@]} -eq 0 ]]; then
        echo "✅ 数据库中的所有IP规则已存在于firewalld中。"
        return
    fi

    echo -e "\n将添加 ${#rules_to_add[@]} 条规则。继续吗？ (y/n): "
    read -r confirm

    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        for rule in "${rules_to_add[@]}"; do
            echo "➕ 正在添加: $rule"
            firewall-cmd --permanent --add-rich-rule="$rule"
        done

        echo -e "\n正在重新加载防火墙以应用更改..."
        firewall-cmd --reload
        echo "✅ 同步完成。已添加 ${#rules_to_add[@]} 条规则。"
    else
        echo "❌ 用户取消同步。"
    fi
}

# 备份防火墙配置
backup_firewall() {
    mkdir -p "$BACKUP_DIR"
    local filename="firewall_backup_$(date +%F_%H-%M-%S).txt"
    local fullpath="$BACKUP_DIR/$filename"
    echo "正在备份防火墙配置..."
    firewall-cmd --list-all > "$fullpath"
    echo "备份已保存到: $fullpath"
}

# 从备份恢复防火墙配置
restore_firewall() {
    echo -e "\n可用备份:"
    mapfile -t backups < <(ls -t "$BACKUP_DIR"/*.txt 2>/dev/null)

    if [[ ${#backups[@]} -eq 0 ]]; then
        echo "未找到备份文件。"
        return
    fi

    for i in "${!backups[@]}"; do
        printf "%2d. %s\n" $((i+1)) "${backups[$i]}"
    done
    echo " 0. 返回菜单"

    echo -n "输入编号查看/恢复备份: "
    read -r index

    if [[ "$index" == "0" ]]; then
        return
    fi

    if [[ "$index" =~ ^[0-9]+$ && "$index" -ge 1 && "$index" -le ${#backups[@]} ]]; then
        local selected="${backups[$((index-1))]}"
        echo -e "\n已选择备份: $selected"
        
        echo "正在解析端口和富规则..."
        ports=$(grep -oP 'ports: \K.*' "$selected")
        mapfile -t rich_rules < <(grep -oP '^\s*rule.*' "$selected")

        echo -e "\n备份中的端口:\n  $ports"
        echo -e "\n备份中的富规则:"
        for rule in "${rich_rules[@]}"; do
            echo "  $rule"
        done

        echo -e "\n继续仅恢复缺失的规则吗？ (y/n): "
        read -r confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            echo -e "\n正在检查并恢复缺失的富规则..."

            # 获取当前防火墙富规则
            current_rules=$(firewall-cmd --list-rich-rules)

            for rule in "${rich_rules[@]}"; do
                if grep -Fxq "$rule" <<< "$current_rules"; then
                    echo "✓ 规则已存在: $rule"
                else
                    echo "➕ 正在添加规则: $rule"
                    firewall-cmd --permanent --add-rich-rule="$rule"
                fi
            done

            echo -e "\n正在重新加载防火墙以应用更改..."
            firewall-cmd --reload
            echo "防火墙恢复成功（仅应用了缺失的规则）。"
        else
            echo "恢复已取消。"
        fi
    else
        echo "无效选择。"
    fi
}

# 显示访问最多的程序/域名
show_top_programs() {
    echo "正在从日志中显示访问最多的程序/域名..."

    local log_pattern
    if [[ $SERVER_TYPE == "nginx" ]]; then
        log_pattern="$LOG_DIR/*.log"
    else
        log_pattern="$LOG_DIR/*_log"
    fi

    echo -e "\n== 访问最多的程序/域名 =="

    awk '{ 
        gsub(/\/www\/wwwlogs\//, "", FILENAME);
        gsub(/\.log$/, "", FILENAME);
        print $1, FILENAME 
    }' $log_pattern | sort | uniq -c | sort -nr | head -n 20
}

# 检查CC防御增强模式状态
check_cc_defend_mode() {
    local btwaf_file="/www/server/btwaf/site.json"

    echo -e "\n== 检查CC-Defend增强模式状态 (cc_mode) =="

    if [[ ! -f "$btwaf_file" ]]; then
        echo "错误: 未找到 $btwaf_file 文件。"
        return 1
    fi


    if [[ -z "$PYTHON_CMD" ]]; then
        echo "错误: 未找到Python解释器。"
        return 1
    fi

    # 显示所有站点的cc_mode值
    SITE_JSON="/www/server/btwaf/site.json"
    
    if [[ -s "$SITE_JSON" ]]; then
        if [[ $(grep -o '[^[:space:]]' "$SITE_JSON" | tr -d '\n') == '{}' ]]; then
            echo "⚠️  文件逻辑上为空（仅包含{}）。"
            return 1
        else
            "$PYTHON_CMD" -c 'import json, sys; d=json.load(open("'"$SITE_JSON"'")); [sys.stdout.write("%s: %s\n" % (k, v.get("cc_mode", ""))) for k,v in d.items()]' \
            | tee /tmp/btwaf_cc_mode_check.txt
        fi
    else
        echo "⚠️  未找到文件或文件完全为空: $SITE_JSON"
        return 1
    fi

    # 检查是否有站点设置为4
    if grep -q ': 4' /tmp/btwaf_cc_mode_check.txt; then
        echo -e "\n部分站点正在使用增强CC-Defend模式 (cc_mode = 4)。"
        echo -n "要为所有站点关闭增强模式（设置为cc_mode = 1）吗？ [y/N]: "
        read -r confirm

        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            "$PYTHON_CMD" -c '
import json
p = "/www/server/btwaf/site.json"
d = json.load(open(p))
for k in d:
    if d[k].get("cc_mode") == 4:
        d[k]["cc_mode"] = 1
json.dump(d, open(p, "w"), indent=4)
print("已将所有cc_mode 4更新为1。")
'
        else
            echo "未做任何更改。"
        fi
    else
        echo "当前没有站点使用cc_mode = 4。"
    fi
}

# 字节转换为人类可读格式
bytes_to_human() {
    local bytes=$1
    local kib=$((1024))
    local mib=$((1024 * kib))
    local gib=$((1024 * mib))
    local tib=$((1024 * gib))

    if (( bytes >= tib )); then
        printf "%.2f TiB" "$(bc -l <<< "$bytes/$tib")"
    elif (( bytes >= gib )); then
        printf "%.2f GiB" "$(bc -l <<< "$bytes/$gib")"
    elif (( bytes >= mib )); then
        printf "%.2f MiB" "$(bc -l <<< "$bytes/$mib")"
    elif (( bytes >= kib )); then
        printf "%.2f KiB" "$(bc -l <<< "$bytes/$kib")"
    else
        printf "%d B" "$bytes"
    fi
}

# 去除ANSI颜色代码
strip_ansi() {
    echo -e "$1" | sed -r 's/\x1B\[[0-9;]*[mK]//g'
}

# 打印菜单头部
print_menu_header() {
    local width=$(tput cols)
    local title="服务器维护菜单"
    # 检测操作系统名称
    local os_name="未知操作系统"
    if [ -f /etc/os-release ]; then
        os_name=$(awk -F= '/^PRETTY_NAME/{gsub(/"/, "", $2); print $2}' /etc/os-release)
    elif [ -f /etc/redhat-release ]; then
        os_name=$(cat /etc/redhat-release)
    elif [ -f /etc/debian_version ]; then
        os_name="Debian $(cat /etc/debian_version)"
    fi
    local server_line="Web服务器: $SERVER_TYPE  |  操作系统: $os_name"

    # 限制最大宽度以保持一致性
    (( width > 80 )) && width=80

    # 构建边框
    local border_line=$(printf '─%.0s' $(seq 1 $((width - 2))))
    local title_padding=$(( (width - 2 - ${#title}) / 2 ))
    local padded_title=$(printf "%*s%s%*s" "$title_padding" "" "$title" "$((width - 3 - title_padding - ${#title}))" "")

    # 检测Python版本
    local python_ver
    if command -v python3 &>/dev/null; then
        python_ver="$(python3 --version 2>&1)"
    elif command -v python &>/dev/null; then
        python_ver="$(python --version 2>&1)"
    else
        python_ver="未找到"
    fi

    # 检测PHP版本
    local php_ver
    php_ver=$(php -v 2>/dev/null | head -n 1 || echo "PHP: 未找到")

    # CPU使用率
    local cpu_usage
    cpu_usage=$(top -bn1 | awk '/%Cpu/{print 100 - $8}' | awk '{printf "%.1f", $1}')

    local cpu_color="\e[0m"
    (( ${cpu_usage%.*} >= 90 )) && cpu_color="\e[31m"
    (( ${cpu_usage%.*} >= 80 && ${cpu_usage%.*} < 90 )) && cpu_color="\e[33m"

    # 内存使用率
    read total used <<< $(free -m | awk '/Mem:/ {print $2, $3}')
    local mem_perc=$(( used * 100 / total ))
    local mem_color="\e[0m"
    (( mem_perc >= 90 )) && mem_color="\e[31m"
    (( mem_perc >= 80 && mem_perc < 90 )) && mem_color="\e[33m"

    # 磁盘信息
    local root_used root_total root_perc home_used home_total home_perc
    read root_used root_total root_perc <<< $(df -h / | awk 'NR==2 {print $3, $2, $5}')
    read home_used home_total home_perc <<< $(df -h /home 2>/dev/null | awk 'NR==2 {print $3, $2, $5}')
    [[ -z "$home_used" ]] && home_used="-" && home_total="-" && home_perc="-"

    root_perc_val=${root_perc%\%}
    home_perc_val=${home_perc%\%}

    local root_color="\e[0m"
    (( root_perc_val >= 90 )) && root_color="\e[31m"
    (( root_perc_val >= 80 && root_perc_val < 90 )) && root_color="\e[33m"

    local home_color="\e[0m"
    (( home_perc_val >= 90 )) && home_color="\e[31m"
    (( home_perc_val >= 80 && home_perc_val < 90 )) && home_color="\e[33m"

    # 磁盘I/O统计（从sda设备获取）
    local disk_read disk_write
    disk_read=$(iostat -dx sda | awk 'NR==4 {print $6}')   # rkB/s
    disk_write=$(iostat -dx sda | awk 'NR==4 {print $7}')  # wkB/s

    # 运行时间和负载平均值
    local uptime_info load_avg
    uptime_info=$(uptime -p)  # 例如："运行 2 天 4 小时"
    load_avg=$(uptime | awk -F'load average: ' '{print $2}')  # 例如："0.12, 0.34, 0.56"
    # 获取CPU核心数
    core_count=$(nproc)
   
    # 提取负载值
    IFS=',' read -r load1 load5 load15 <<< "$load_avg"
    load1=$(echo "$load1" | xargs)      # 去除空格
    load5=$(echo "$load5" | xargs)
    load15=$(echo "$load15" | xargs)
   
    # 转换为浮点数进行比较
    status="正常"
    color="\e[0m"
   
    if (( $(echo "$load15 > $core_count * 1.5" | bc -l) )); then
        status="🔴 高"
        color="\e[31m"
    elif (( $(echo "$load15 > $core_count" | bc -l) )); then
        status="🟠 偏高"
        color="\e[33m"
    else
        status="🟢 正常"
        color="\e[32m"
    fi
    
    # 最终人类可读的字符串
    load_display="${color}${load1} (1分钟), ${load15} (15分钟) [核心数: ${core_count}, 状态: ${status}]\e[0m"

    # 网络统计（使用RX-OK和TX-OK）
    local net_sent net_received
    net_sent=$(netstat -i | grep -E '^em1[[:space:]]' | awk '{print $7}')
    net_received=$(netstat -i | grep -E '^em1[[:space:]]' | awk '{print $3}')
   
    # 转换网络统计为人类可读格式
    net_sent_hr=$(bytes_to_human "$net_sent")
    net_received_hr=$(bytes_to_human "$net_received")

    # 交换空间使用情况
    local swap_total swap_used
    read swap_total swap_used <<< $(free -m | awk '/Swap:/ {print $2, $3}')
    swap_perc=$(awk "BEGIN { printf \"%.1f\", ($swap_used / $swap_total) * 100 }")
   
    swap_color="\e[0m"
    if (( $(echo "$swap_perc >= 90" | bc -l) )); then
        swap_color="\e[31m"  # 红色
    elif (( $(echo "$swap_perc >= 80" | bc -l) )); then
        swap_color="\e[33m"  # 黄色/深橙色
    fi

    # 打印菜单框
    echo -e "\e[36m┌$border_line┐"
    print_line "📋  $title" ""
    echo -e "├$border_line┤\e[0m"
   
    print_line "⏳  运行时间" "$uptime_info"
    print_line "🖥️  服务器类型" "$server_line"
    print_line "🐍  Python版本" "$python_ver"
    print_line "💻  PHP版本" "$php_ver"

    # 🔹 子节分隔线（与框宽度匹配）
    echo -e "\e[36m├$border_line┤\e[0m"

    print_line "📉  负载平均值" "$(echo -e "$load_display")"
    print_line "⚡  CPU使用率" "$(echo -e "${cpu_color}${cpu_usage}%\e[0m")"
    print_line "🧠  内存使用率" "$(echo -e "${mem_color}${mem_perc}% (${used}M/${total}M)\e[0m")"
    print_line "💾  根磁盘" "$(echo -e "${root_color}${root_used} / ${root_total} (${root_perc})\e[0m")"
    print_line "📂  家目录磁盘" "$(echo -e "${home_color}${home_used} / ${home_total} (${home_perc})\e[0m")"
    
    print_line "📚  磁盘读取" "$disk_read KB/s"
    print_line "📖  磁盘写入" "$disk_write KB/s"
    print_line "📤  网络发送" "$net_sent_hr [TX]"
    print_line "📥  网络接收" "$net_received_hr [RX]"
    print_line "💤  交换空间使用率" "$(echo -e "${swap_color}${swap_used} / ${swap_total} MB (${swap_perc}%)\e[0m")"
   
    echo -e "\e[36m└$border_line┘\e[0m"
}

# 打印行
print_line() {
    local label="$1"
    local value="$2"
    local total_width=$(($(tput cols) - 2))
    [[ $total_width -gt 80 ]] && total_width=78

    local label_width=24
    local value_width=$((total_width - label_width - 1))

    # 计算标签的可见长度（不含ANSI代码）
    local visible_label_length=$(strip_ansi "$label" | wc -m)

    if [[ -z "$value" ]]; then
        # 标题行
        local title_length=$(strip_ansi "$label" | wc -m)
        local padding_left=$(( (total_width - title_length) / 2 ))
        local padding_right=$(( total_width - title_length - padding_left + 1 ))
        printf "\e[36m│%*s%s%*s\e[0m\n" $padding_left "" "$label" $padding_right ""
    else
        # 标签和值行
        printf "\e[36m│ %-${label_width}s: %-${value_width}s \e[0m\n" "$label" "$value"
    fi
}

# 显示htop
show_htop() {
    if ! command -v htop >/dev/null 2>&1; then
        echo "未安装htop。"

        read -p "要安装htop吗？ [y/N]: " confirm
        confirm=${confirm,,}  # 转换为小写

        if [[ "$confirm" != "y" && "$confirm" != "yes" ]]; then
            echo "跳过htop安装。"
            return
        fi

        echo "正在安装htop..."

        if [ -f /etc/redhat-release ]; then
            echo "检测到CentOS/RHEL。使用yum安装..."
            sudo yum install htop -y
        elif [ -f /etc/debian_version ]; then
            echo "检测到Debian/Ubuntu。使用apt安装..."
            sudo apt update && sudo apt install htop -y
        else
            echo "未知操作系统。请手动安装htop。"
            return
        fi
    fi

    htop
}

# 重启Web服务器

restart_web_server() {
    if [[ $SERVER_TYPE == "nginx" ]]; then
        echo "正在重启 nginx..."
        systemctl restart nginx
        sleep 15
        if ! systemctl is-active --quiet nginx; then
            echo "Nginx 重启失败，尝试重新启动 nginx..."
            systemctl start nginx
        fi
        systemctl status nginx | grep Active
        service nginx status

    elif [[ $SERVER_TYPE == "apache" ]]; then
        echo "正在重启 apache..."
        systemctl restart httpd || systemctl restart apache2
        sleep 15
        if ! systemctl is-active --quiet httpd && ! systemctl is-active --quiet apache2; then
            echo "Apache 重启失败，尝试重新启动 apache..."
            systemctl start httpd || systemctl start apache2
        fi
        systemctl status httpd | grep Active || systemctl status apache2 | grep Active
        service httpd status || service apache2 status
    else 
        echo "尝试启动任意 Web 服务..."
        systemctl start nginx || systemctl start httpd || systemctl start apache2
    fi
}

restart_php() {
    echo "正在重启 PHP..."
    systemctl restart php-fpm-74 || systemctl restart php-fpm-72
    systemctl status php-fpm-74 || systemctl status php-fpm-72
}

restart_mysql() {
    echo "正在重启 MySQL..."
    systemctl restart mysql
    systemctl status mysql
}

main_menu() {
    detect_server_type
    print_menu_header

    echo -e "\n菜单："
    echo "1. 清理日志"
    echo "2. 分析日志"
    echo "3. 阻止可疑 IP"
    echo "4. 备份防火墙配置"
    echo "5. 恢复防火墙配置"
    echo "6. 编辑防火墙 IP 规则"
    # echo "7. 显示访问最多的程序/域名"
    echo "7. 同步防火墙 IP 规则 / 域名"
    echo "8. 检查/切换 CC 防护增强模式"
    echo "9. 重启 Web 服务"
    echo "10. 重启 PHP"
    echo "11. 重启 MySQL"
    echo "12. 显示 'top'"
    echo "13. 显示 'htop'"
    echo "0. 退出"
    echo -n "请选择操作编号: "
    read -r choice
    
    case "$choice" in
        1) clean_logs ;;
        2) analyze_logs ;;
        3) block_ip ;;
        4) backup_firewall ;;
        5) restore_firewall ;;
        6) edit_firewall_ip_rules ;;
        # 7) show_top_programs ;;
        7) sync_firewall_ip_rules ;;
        8) check_cc_defend_mode ;;
        9) restart_web_server ;;
        10) restart_php ;;
        11) restart_mysql ;;
        12) top ;;
        13) show_htop ;;
        0) exit 0 ;;
        *) echo "无效选项" ;;
    esac
}

check_and_load_btwaf_whitelist  # Loads WHITELISTED_IPS array

# 主循环菜单
while true; do
    main_menu
done
