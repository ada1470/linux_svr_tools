#!/bin/bash

# 可配置变量
TOP_IP_COUNT=200  # 要分析的前N个IP数量，可根据需要更改（例如：20、50、200、500）
TOP_IP_ANALYSE=10
TOP_RANGE_COUNT=20

LOG_DIR="/www/wwwlogs"
BACKUP_DIR="/home/www/backup/firewall"
SPIDER_WHITELIST_REGEX="baiduspider|sogouspider|bytespider|shenmaspider|hn.kd.ny.adsl|petal"
TMP_IP_LIST="/tmp/top_ips.txt"
# 用于存储标注过的IP和网段的临时文件
IPS_TO_BLOCK_FILE="/tmp/ips_to_block.txt"
RANGES_TO_BLOCK_FILE="/tmp/ranges_to_block.txt"

# 检测Web服务类型（nginx或apache）
detect_server_type() {
    if pgrep -x "nginx" >/dev/null; then
        SERVER_TYPE="nginx"
    elif pgrep -x "httpd" >/dev/null || pgrep -x "apache2" >/dev/null; then
        SERVER_TYPE="apache"
    else
        echo "无法检测到 Web 服务类型。"
        systemctl status nginx || systemctl status httpd || systemctl status apache2
        service nginx status
        service httpd status

        read -p "是否尝试重启 Web 服务？[y/N]: " confirm
        confirm=${confirm,,}  # 转为小写

        if [[ "$confirm" == "y" || "$confirm" == "yes" ]]; then
            restart_web_server
        fi

        exit 1
    fi
}

# 清理日志
clean_logs() {
    echo "正在清理日志..."
    find "$LOG_DIR" -maxdepth 1 -type f \( -name "*.log" -o -name "*_log" \) -exec rm -v {} \;

    restart_web_server
}

# 分析日志，生成要封锁的IP和网段
analyze_logs() {
    echo "正在分析 $SERVER_TYPE 的日志..."

    > "$IPS_TO_BLOCK_FILE"
    > "$RANGES_TO_BLOCK_FILE"

    if [[ $SERVER_TYPE == "nginx" ]]; then
        LOG_FILES="$LOG_DIR"/*.log
    else
        LOG_FILES="$LOG_DIR"/*access_log
    fi

    awk '{ print $1 }' $LOG_FILES | sort | uniq -c | sort -nr | head -n "$TOP_IP_COUNT" > "$TMP_IP_LIST"
    sed -i '/[0-9]\{1,3\}\(\.[0-9]\{1,3\}\)\{3\}/!d' "$TMP_IP_LIST"

    echo -e "\n== 标注前 $TOP_IP_ANALYSE 个独立IP =="
    head -n "$TOP_IP_ANALYSE" "$TMP_IP_LIST" | while read -r count ip; do
        annotate_ip "$ip" "$count"
    done

    echo -e "\n== 顶部IP网段 =="
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
                printf "%-18s %6d 次请求来自 %3d 个唯一IP\n", r, count[r], unique_count[r]
            }
        }
    }' | sort -k2 -nr | head -n "$TOP_RANGE_COUNT" | tee /tmp/ip_range_summary

    echo -e "\n== 标注IP网段 =="
    while read -r range; do
        annotate_ip "$range" "$count_line"
    done < <(cut -d' ' -f1 /tmp/ip_range_summary)

    echo -e "\n== 顶部引用来源域名 =="
    awk -F'"' '{print $4}' $LOG_FILES | \
        awk -F/ '/^https?:\/\// {print $3}' | \
        grep -vE '^(-|localhost|127\.0\.0\.1)$' | \
        sort | uniq -c | sort -nr | head -n 20

    echo -e "\n== 错误请求最多的IP =="
}

# 标注IP（是否是已知蜘蛛、防火墙白名单等）
annotate_ip() {
    local ip="$1"
    local count="$2"
    local annotation=""

    if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        if host_info=$(getent hosts "$ip"); then
            if echo "$host_info" | grep -Eiq "$SPIDER_WHITELIST_REGEX"; then
                annotation=$(echo "$host_info" | grep -Eo "$SPIDER_WHITELIST_REGEX" | head -n 1)
                annotation="$annotation（白名单蜘蛛）"
            else
                domain=$(echo "$host_info" | awk '{print $2}')
                annotation="$domain（非白名单蜘蛛）"
            fi
        else
            local range=$(echo "$ip" | sed -E 's#([0-9]+\.[0-9]+\.[0-9]+)\.[0-9]+#\1.0/24#')
            if firewall-cmd --list-rich-rules | grep -qE "$ip|$range"; then
                annotation="防火墙白名单"
            else
                annotation="未知来源"
            fi
        fi

        if [[ -w "$IPS_TO_BLOCK_FILE" || ! -e "$IPS_TO_BLOCK_FILE" && -w "$(dirname "$IPS_TO_BLOCK_FILE")" ]]; then
            echo "$count - $ip => $annotation" | tee -a "$IPS_TO_BLOCK_FILE"
        else
            echo "错误：无法写入 $IPS_TO_BLOCK_FILE" >&2
        fi

    else
        local ip_base=$(echo "$ip" | cut -d'/' -f1 | cut -d. -f1-3)
        local sample_ip="$ip_base.1"
        annotation="未知来源"

        if host_entry=$(getent hosts "$sample_ip"); then
            if echo "$host_entry" | grep -Eiq "$SPIDER_WHITELIST_REGEX"; then
                spider_name=$(echo "$host_entry" | grep -Eio "$SPIDER_WHITELIST_REGEX" | head -n 1)
                annotation="$spider_name（白名单蜘蛛）"
            else
                domain=$(echo "$host_entry" | awk '{print $2}')
                annotation="$domain（非白名单蜘蛛）"
            fi
        elif firewall-cmd --list-rich-rules | grep -Eq "$ip"; then
            annotation="防火墙白名单"
        fi

        if [[ -w "$RANGES_TO_BLOCK_FILE" || ! -e "$RANGES_TO_BLOCK_FILE" && -w "$(dirname "$RANGES_TO_BLOCK_FILE")" ]]; then
            echo "$ip => $annotation" | tee -a "$RANGES_TO_BLOCK_FILE"
        else
            echo "错误：无法写入 $RANGES_TO_BLOCK_FILE" >&2
        fi
    fi
}

# TODO: 继续翻译 block_ip、edit_firewall_ip_rules、sync_firewall_ip_rules 等函数...
...（前面代码保持不变）...

# 阻止可疑IP和网段
block_ip() {
    echo "封锁非白名单高频请求的IP..."

    ips_to_block=()
    ranges_to_block=()

    echo -e "\n== 收集需封锁的独立IP =="
    while read -r line; do
        ip=$(echo "$line" | awk '{print $3}')
        annotation=$(echo "$line" | cut -d'>' -f2- | sed 's/^ *//')
        if [[ "$annotation" == *"未知"* || "$annotation" == *"非白名单"* ]]; then
            ips_to_block+=("$ip")
        fi
    done < "$IPS_TO_BLOCK_FILE"

    echo -e "\n== 收集需封锁的IP网段 =="
    while read -r line; do
        ip_base=$(echo "$line" | awk '{print $1}')
        annotation=$(echo "$line" | cut -d'>' -f2- | sed 's/^ *//')
        if [[ "$annotation" == *"未知"* || "$annotation" == *"非白名单"* ]]; then
            ranges_to_block+=("$ip_base")
        fi
    done < "$RANGES_TO_BLOCK_FILE"

    if [[ ${#ips_to_block[@]} -gt 0 ]]; then
        echo -e "\n== 将封锁以下IP =="
        for ip in "${ips_to_block[@]}"; do
            echo "$ip"
        done
        echo -e "\n是否封锁这些IP？[y/N]: "
        read -r confirm_ips
        if [[ "$confirm_ips" =~ ^[Yy]$ ]]; then
            for ip in "${ips_to_block[@]}"; do
                echo "正在封锁 IP: $ip"
                firewall-cmd --permanent --add-rich-rule="rule family='ipv4' source address='$ip' drop"
                sqlite3 /www/server/panel/data/db/firewall.db \
                    "INSERT INTO firewall_ip (types, address, brief, addtime, chain) VALUES ('drop', '$ip', '脚本封锁', strftime('%Y-%m-%d %H:%M:%S', 'now'), 'INPUT');"
                echo "$ip 已封锁并记录入数据库"
            done
        fi
    fi

    if [[ ${#ranges_to_block[@]} -gt 0 ]]; then
        echo -e "\n== 将封锁以下IP网段 =="
        for range in "${ranges_to_block[@]}"; do
            echo "$range"
        done
        echo -e "\n是否封锁这些网段？[y/N]: "
        read -r confirm_ranges
        if [[ "$confirm_ranges" =~ ^[Yy]$ ]]; then
            for range in "${ranges_to_block[@]}"; do
                echo "正在封锁网段: $range"
                firewall-cmd --permanent --add-rich-rule="rule family='ipv4' source address='$range' drop"
                sqlite3 /www/server/panel/data/db/firewall.db \
                    "INSERT INTO firewall_ip (types, address, brief, addtime, chain) VALUES ('drop', '$range', '脚本封锁', strftime('%Y-%m-%d %H:%M:%S', 'now'), 'INPUT');"
                echo "$range 已封锁并记录入数据库"
            done
        fi
    fi

    echo -e "\n重新加载防火墙配置..."
    firewall-cmd --reload
}

# 后续函数建议按模块另建文件或菜单项调用，避免脚本过于庞大

# TODO: edit_firewall_ip_rules()
# TODO: sync_firewall_ip_rules()
# TODO: backup_firewall()
# TODO: restore_firewall()
# TODO: show_top_programs()
# TODO: check_cc_defend_mode()
# TODO: restart_web_server(), restart_php(), restart_mysql()
# TODO: main_menu()

# 注：如果需要，我可继续完成这些函数的中文翻译。


# 编辑防火墙IP规则（根据索引删除）
edit_firewall_ip_rules() {
    echo "编辑防火墙 IP 规则..."
    echo -e "\n== 当前防火墙规则列表 =="
    firewall-cmd --list-rich-rules | nl -s '. '

    echo -e "\n请输入要删除的规则编号范围（例如 3-5 表示删除第3到第5条规则）："
    read -r index_range

    if [[ "$index_range" =~ ^[0-9]+-[0-9]+$ ]]; then
        start_index=$(echo "$index_range" | cut -d'-' -f1)
        end_index=$(echo "$index_range" | cut -d'-' -f2)

        if [[ $start_index -le $end_index ]]; then
            echo -e "\n正在删除索引 $start_index 到 $end_index 的规则..."
            rules=$(firewall-cmd --list-rich-rules)
            IFS=$'\n' read -r -d '' -a rule_array <<< "$rules"

            for ((i = start_index - 1; i < end_index; i++)); do
                rule=${rule_array[$i]}
                if [[ -n "$rule" ]]; then
                    echo "移除规则: $rule"
                    ip_or_range=$(echo "$rule" | sed -n 's/.*source address="\([^"]*\)".*/\1/p')
                    firewall-cmd --permanent --remove-rich-rule="$rule"
                    sqlite3 /www/server/panel/data/db/firewall.db \
                        "DELETE FROM firewall_ip WHERE address = '$ip_or_range';"
                    echo "$ip_or_range 已从防火墙和数据库中移除。"
                fi
            done

            echo -e "\n重新加载防火墙..."
            firewall-cmd --reload
            echo "防火墙规则更新完毕。"
        else
            echo "无效范围，起始索引必须小于等于结束索引。"
        fi
    else
        echo "输入格式无效，请使用类似 3-5 的格式。"
    fi
}

# 同步数据库中的防火墙规则到 firewalld
sync_firewall_ip_rules() {
    echo "准备同步 firewall.db 中的 IP 规则到 firewalld..."

    current_rules=$(firewall-cmd --list-rich-rules)
    mapfile -t ip_entries < <(sqlite3 /www/server/panel/data/db/firewall.db \
        "SELECT types, address FROM firewall_ip WHERE address != ''")

    declare -a rules_to_add
    echo -e "\n== 即将添加的规则 =="

    for entry in "${ip_entries[@]}"; do
        types=$(echo "$entry" | cut -d'|' -f1)
        ip=$(echo "$entry" | cut -d'|' -f2)
        [[ -z "$ip" ]] && continue

        if [[ "$types" == "drop" ]]; then
            action="drop"
        else
            action="accept"
        fi

        rule="rule family=\"ipv4\" source address=\"$ip\" $action"
        if ! grep -Fxq "$rule" <<< "$current_rules"; then
            echo "$rule"
            rules_to_add+=("$rule")
        fi
    done

    if [[ ${#rules_to_add[@]} -eq 0 ]]; then
        echo "✅ 所有规则已存在，无需同步。"
        return
    fi

    echo -e "\n将添加 ${#rules_to_add[@]} 条规则。是否继续？(y/n): "
    read -r confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        for rule in "${rules_to_add[@]}"; do
            echo "➕ 添加规则: $rule"
            firewall-cmd --permanent --add-rich-rule="$rule"
        done
        echo -e "\n重新加载防火墙配置..."
        firewall-cmd --reload
        echo "✅ 同步完成。"
    else
        echo "❌ 用户取消操作。"
    fi
}

# 备份防火墙配置
backup_firewall() {
    mkdir -p "$BACKUP_DIR"
    local filename="firewall_backup_$(date +%F_%H-%M-%S).txt"
    local fullpath="$BACKUP_DIR/$filename"
    echo "正在备份防火墙配置..."
    firewall-cmd --list-all > "$fullpath"
    echo "备份已保存至: $fullpath"
}

# 恢复防火墙配置
restore_firewall() {
    echo -e "\n可用备份列表："
    mapfile -t backups < <(ls -t "$BACKUP_DIR"/*.txt 2>/dev/null)
    if [[ ${#backups[@]} -eq 0 ]]; then
        echo "未找到任何备份文件。"
        return
    fi

    for i in "${!backups[@]}"; do
        printf "%2d. %s\n" $((i+1)) "${backups[$i]}"
    done
    echo " 0. 返回菜单"

    echo -n "请输入要查看/恢复的备份编号: "
    read -r index

    if [[ "$index" == "0" ]]; then
        return
    fi

    if [[ "$index" =~ ^[0-9]+$ && "$index" -ge 1 && "$index" -le ${#backups[@]} ]]; then
        local selected="${backups[$((index-1))]}"
        echo -e "\n选择的备份文件: $selected"

        echo "正在解析端口和规则..."
        ports=$(grep -oP 'ports: \K.*' "$selected")
        mapfile -t rich_rules < <(grep -oP '^\s*rule.*' "$selected")

        echo -e "\n备份中的端口: $ports"
        echo -e "\n备份中的规则:"
        for rule in "${rich_rules[@]}"; do
            echo "  $rule"
        done

        echo -e "\n是否仅恢复缺失的规则？(y/n): "
        read -r confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            echo -e "\n正在检查并恢复缺失规则..."
            current_rules=$(firewall-cmd --list-rich-rules)

            for rule in "${rich_rules[@]}"; do
                if grep -Fxq "$rule" <<< "$current_rules"; then
                    echo "✓ 已存在: $rule"
                else
                    echo "➕ 添加: $rule"
                    firewall-cmd --permanent --add-rich-rule="$rule"
                fi
            done

            echo -e "\n重新加载防火墙..."
            firewall-cmd --reload
            echo "防火墙恢复成功（仅添加缺失规则）。"
        else
            echo "用户取消恢复操作。"
        fi
    else
        echo "无效选择。"
    fi
}


# 检查并可选关闭 CC 防护增强模式
check_cc_defend_mode() {
    local btwaf_file="/www/server/btwaf/site.json"

    echo -e "\n== 检查 CC 防御增强模式状态 (cc_mode) =="

    if [[ ! -f "$btwaf_file" ]]; then
        echo "错误：未找到 $btwaf_file"
        return 1
    fi

    PYTHON_CMD=""
    for cmd in python3 python py; do
        if command -v "$cmd" >/dev/null 2>&1; then
            PYTHON_CMD="$cmd"
            break
        fi
    done

    if [[ -z "$PYTHON_CMD" ]]; then
        echo "错误：未检测到 Python 解释器。"
        return 1
    fi

    SITE_JSON="/www/server/btwaf/site.json"

    if [[ -s "$SITE_JSON" ]]; then
        if [[ $(grep -o '[^[:space:]]' "$SITE_JSON" | tr -d '\n') == '{}' ]]; then
            echo "⚠️ 文件为空对象（仅包含 {}）。"
            return 1
        else
            "$PYTHON_CMD" -c 'import json, sys; d=json.load(open("""'"$SITE_JSON"'""")); [sys.stdout.write("%s: %s\n" % (k, v.get("cc_mode", ""))) for k,v in d.items()]' | tee /tmp/btwaf_cc_mode_check.txt
        fi
    else
        echo "⚠️ 文件不存在或完全为空：$SITE_JSON"
        return 1
    fi

    if grep -q ': 4' /tmp/btwaf_cc_mode_check.txt; then
        echo -e "\n部分站点启用了增强 CC 防护模式 (cc_mode = 4)。"
        echo -n "是否将所有站点改为普通模式 (cc_mode = 1)？[y/N]: "
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
print("所有 cc_mode=4 已更新为 1。")'
        else
            echo "未进行修改。"
        fi
    else
        echo "所有站点均未启用 cc_mode = 4。"
    fi
}

# 重启 Web 服务
restart_web_server() {
    if [[ $SERVER_TYPE == "nginx" ]]; then
        echo "正在重启 nginx..."
        systemctl restart nginx
        sleep 15
        if ! systemctl is-active --quiet nginx; then
            echo "Nginx 重启失败，尝试启动 nginx..."
            systemctl start nginx
        fi
        systemctl status nginx | grep Active
        service nginx status

    elif [[ $SERVER_TYPE == "apache" ]]; then
        echo "正在重启 apache..."
        systemctl restart httpd || systemctl restart apache2
        sleep 15
        if ! systemctl is-active --quiet httpd && ! systemctl is-active --quiet apache2; then
            echo "Apache 重启失败，尝试启动 apache..."
            systemctl start httpd || systemctl start apache2
        fi
        systemctl status httpd | grep Active || systemctl status apache2 | grep Active
        service httpd status || service apache2 status
    else 
        echo "尝试启动任意可用 Web 服务..."
        systemctl start nginx || systemctl start httpd || systemctl start apache2
    fi
}

# 重启 PHP
restart_php() {
    echo "正在重启 PHP..."
    systemctl restart php-fpm-74 || systemctl restart php-fpm-72
    systemctl status php-fpm-74 || systemctl status php-fpm-72
}

# 重启 MySQL
restart_mysql() {
    echo "正在重启 MySQL..."
    systemctl restart mysql
    systemctl status mysql
}

# 主菜单函数
main_menu() {
    detect_server_type
    print_menu_header

    echo -e "\n菜单选项："
    echo "1. 清理日志"
    echo "2. 分析日志"
    echo "3. 封锁可疑 IP"
    echo "4. 备份防火墙配置"
    echo "5. 恢复防火墙配置"
    echo "6. 编辑防火墙 IP 规则"
    echo "7. 同步防火墙 IP 规则"
    echo "8. 检查/切换 CC 防护增强模式"
    echo "9. 重启 Web 服务"
    echo "10. 重启 PHP"
    echo "11. 重启 MySQL"
    echo "12. 查看 'top' 资源"
    echo "13. 查看 'htop' 图形界面"
    echo "0. 退出"
    echo -n "请输入选项编号: "
    read -r choice

    case "$choice" in
        1) clean_logs ;;
        2) analyze_logs ;;
        3) block_ip ;;
        4) backup_firewall ;;
        5) restore_firewall ;;
        6) edit_firewall_ip_rules ;;
        7) sync_firewall_ip_rules ;;
        8) check_cc_defend_mode ;;
        9) restart_web_server ;;
        10) restart_php ;;
        11) restart_mysql ;;
        12) top ;;
        13) show_htop ;;
        0) exit 0 ;;
        *) echo "无效选项，请重试。" ;;
    esac
}

# 无限循环主菜单
while true; do
    main_menu
done
