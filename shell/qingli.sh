#!/bin/bash

# 彩色输出函数
red()    { echo -e "\033[31m$*\033[0m"; }
green()  { echo -e "\033[32m$*\033[0m"; }

# 路径设置
CONFIG_FILE="/www/server/panel/config/config.json"
IP_FILE="/www/server/panel/data/iplist.txt"

# 优先级顺序：python3 > python > py
PYTHON_CMD=$(command -v python3 || command -v python || command -v py)
PYTHON_CMD=$(echo "$PYTHON_CMD" | tr -d '\r\n')

if [[ -z "$PYTHON_CMD" ]]; then
    echo "❌ 未找到可用的 Python 解释器（python3、python 或 py）"
    exit 1
fi

# 从 JSON 配置中获取面板标题
if [ -f "$CONFIG_FILE" ]; then
    # TITLE=$(grep -oP '"title"\s*:\s*"\K[^"]+' "$CONFIG_FILE")
    # TITLE=$(jq -r '.title' "$CONFIG_FILE" 2>/dev/null)
    # 读取配置文件中的 title 字段
    # TITLE=$("$PYTHON_CMD" -c "import json; print(json.load(open('$CONFIG_FILE')).get('title', '未知'))" 2>/dev/null)
    
    TITLE=$($PYTHON_CMD - "$CONFIG_FILE" <<'EOF'
# -*- coding: utf-8 -*-
import json, sys, traceback

try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
    title = data.get('title') or data.get('panel', {}).get('title', '未知')
    # Python 2 需要 encode，Python 3 不需要
    if sys.version_info[0] < 3:
        if isinstance(title, unicode):
            title = title.encode('utf-8')
    print(title)
except Exception:
    print("未知")
    traceback.print_exc(file=sys.stderr)
EOF
    )

else
    TITLE="未知"
fi

# echo "📋 面板名称: $TITLE"


# 从 IP 文件中获取第一条非空 IP
if [ -f "$IP_FILE" ]; then
    SERVER_IP=$(grep -m 1 -v '^$' "$IP_FILE" | xargs)
else
    SERVER_IP="未知"
fi

# 输出结果
echo "📋 面板名称: $TITLE"
echo "🌐 服务器 IP: $SERVER_IP"

# ------------------------------------------------------------------------------
# 🧹 网站缓存清理脚本
# ------------------------------------------------------------------------------
# 本脚本用于清理 /home/www/wwwroot 目录下的 site/public/site 子目录中的 cache 缓存目录。
# 用户可通过输入要排除的域名列表（即不清理这些域名的缓存）来控制清理范围。
# 支持粘贴域名列表（逗号或换行分隔），并会验证域名格式。
# 若输入有误或域名数量太少，将进行二次确认，确保安全操作。
# ------------------------------------------------------------------------------
# ❗ 注意事项：
# - 清理操作不可逆，请谨慎确认。
# - 若非 Enter 键确认，将自动取消操作。
# ------------------------------------------------------------------------------

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🧹 网站缓存清理工具"
echo "📁 目标路径: /home/www/wwwroot/*/{site,public/site}/*/cache"
echo "🛑 将删除除指定域名外的所有 cache 目录"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

echo "请输入要排除的域名列表（可用逗号或换行分隔，每行一个）："
echo "粘贴内容可使用 Shift+Insert，输入完成后（最后要是一个空行）请按 Ctrl+D 提交："

# 验证域名格式的函数
is_valid_domain() {
    [[ $1 =~ ^([a-zA-Z0-9-]+\.)+[a-zA-Z]{2,}$ ]]
}

# 读取用户输入（支持多行）
domain_input=$(cat)

# 处理输入，支持逗号与换行
domain_array=()
while IFS= read -r line; do
    IFS=',' read -ra parts <<< "$line"
    for domain in "${parts[@]}"; do
        domain_trimmed=$(echo "$domain" | xargs)  # 去除空格
        [[ -n "$domain_trimmed" ]] && domain_array+=("$domain_trimmed")
    done
done <<< "$domain_input"

valid_domains=()
invalid_domains=()

echo "正在验证域名格式 。 。 。"
# 验证域名格式
for domain in "${domain_array[@]}"; do
    if is_valid_domain "$domain"; then
        valid_domains+=("$domain")
    else
        invalid_domains+=("$domain")
    fi
done

# 如果有非法域名，提示用户确认
if [ "${#invalid_domains[@]}" -gt 0 ]; then
    echo -e "\n❗ 检测到以下无效域名："
    printf ' - %s\n' "${invalid_domains[@]}"
    read -p "是否继续操作？(y/N): " confirm_invalid
    [[ "$confirm_invalid" =~ ^[Yy]$ ]] || exit 1
fi

# 如果有效域名少于2个，提示用户确认
if [ "${#valid_domains[@]}" -lt 2 ]; then
    echo -e "\n⚠️ 仅输入了 ${#valid_domains[@]} 个有效域名："
    printf ' - %s\n' "${valid_domains[@]}"
    read -p "确定要继续吗？(y/N): " confirm_few
    [[ "$confirm_few" =~ ^[Yy]$ ]] || exit 1
fi


# 获取真实存在的域名目录（基于 cache 路径）

real_domains=()

echo "正在获取真实存在的域名目录 . . ."
# Check site/
while read -r dir; do
    [[ -d "$dir/cache" ]] && real_domains+=("$(basename "$dir")")
done < <(find /home/www/wwwroot/*/site/ -mindepth 1 -maxdepth 1 -type d 2>/dev/null)

# Check public/site/
while read -r dir; do
    [[ -d "$dir/cache" ]] && real_domains+=("$(basename "$dir")")
done < <(find /home/www/wwwroot/*/public/site/ -mindepth 1 -maxdepth 1 -type d 2>/dev/null)



# 去重

real_domains=($(printf "%s\n" "${real_domains[@]}" | sort -u))

# for domain in "${real_domains[@]}"; do
#     echo $domain
# done

# 检查输入域名是否实际存在

matched_excludes=()

unmatched_excludes=()
echo "检查输入域名是否实际存在 。 。 。"
for domain in "${valid_domains[@]}"; do
    if [[ " ${real_domains[*]} " == *" $domain "* ]]; then
        matched_excludes+=("$domain")
    else
        unmatched_excludes+=("$domain")
    fi
done



# 如果全部都不匹配，警告并显示主机信息和未匹配域名
if [ "${#matched_excludes[@]}" -eq 0 ]; then
    red "\n❌ 输入的域名与当前服务器缓存目录不匹配，可能连接的是错误的服务器！"

    echo -e "\n🔍 输入的域名如下，但没有一个与实际存在的缓存目录匹配："
    for domain in "${valid_domains[@]}"; do
        echo " - $domain"
    done

    echo -e "\n📛 当前服务器主机名: $(hostname)"
    echo "🌐 当前服务器 IP 地址: $(hostname -I | awk '{print $1}')"
    echo "📋 当前服务器面板标识: $TITLE"

    echo
    read -p "是否仍要继续？(y/N): " confirm_wrong
    [[ "$confirm_wrong" =~ ^[Yy]$ ]] || exit 1

# 如果部分未匹配，仅警告提示
elif [ "${#unmatched_excludes[@]}" -gt 0 ]; then
    red "\n⚠️ 以下输入的域名未在服务器缓存目录中找到，将被忽略："
    for domain in "${unmatched_excludes[@]}"; do
        echo " - $domain"
    done
    echo
    read -p "仍要继续吗？(Y/n): " confirm_partial
    [[ "$confirm_partial" =~ ^[Nn]$ ]] && exit 1
fi


# 构建 find 排除参数

exclude_expr=""

for domain in "${matched_excludes[@]}"; do

    exclude_expr+="! -path '*/$domain/*' "

done



# 列出将要被清理的域名（即实际存在且不在排除列表中）

to_clean=()

for domain in "${real_domains[@]}"; do

    skip=0

    for ex in "${matched_excludes[@]}"; do

        [[ "$domain" == "$ex" ]] && skip=1 && break

    done

    [[ $skip -eq 0 ]] && to_clean+=("$domain")

done



echo -e "\n🧹 将清理以下域名的缓存目录："

for d in "${to_clean[@]}"; do

    echo " - $d"

done

# 最后输出：哪些域名将被保留
if [ "${#matched_excludes[@]}" -gt 0 ]; then
    green "\n✅ 以下域名将被保留，不会清理缓存："
    for domain in "${matched_excludes[@]}"; do
        echo " - $domain"
    done
fi


echo -e "\n按 Enter 键继续清理，按其他任意键取消..."

# 等待用户确认
IFS= read -rsn1 key
if [[ -n "$key" ]]; then
    echo "❌ 已取消。"
    exit 1
fi

echo -e "\n开始清理..."
# 执行 find 命令进行清理
eval "find /home/www/wwwroot/*/{site,public/site}/*/cache \
-type d \
$exclude_expr \
-exec rm -rfv {} + 2>/dev/null"

echo -e "\n清理完毕..."