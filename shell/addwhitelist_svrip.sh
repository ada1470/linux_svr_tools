#!/bin/bash

# === Configuration ===
BTWAF_FILE="/www/server/btwaf/rule/ip_white.json"
FIREWALL_BACKUP_DIR="/home/www/backup/firewall"
mkdir -p "$FIREWALL_BACKUP_DIR"

# === Get server IPs ===
get_server_ips() {
    local all_ips
    all_ips=$(hostname -I)
    SERVER_IPS=()

    for ip in $all_ips; do
        if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            SERVER_IPS+=("$ip")
        fi
    done
}

# === Convert IP to int ===
ip_to_int() {
    local IFS=.
    read -r o1 o2 o3 o4 <<< "$1"
    echo $(( (o1 << 24) + (o2 << 16) + (o3 << 8) + o4 ))
}

# === Add to BTWAF whitelist ===
add_to_btwaf_whitelist() {
    if [[ ! -f "$BTWAF_FILE" ]]; then
        echo "⚠️ BTWAF not found at $BTWAF_FILE"
        return
    fi

    local backup_path="${BTWAF_FILE}.bak_$(date +%F_%H-%M-%S)"
    cp "$BTWAF_FILE" "$backup_path"

    # Load current entries
    current_json=$(<"$BTWAF_FILE")
    mapfile -t existing_lines < <(echo "$current_json" | jq -c '.[]')

    # Convert to set for quick lookup
    declare -A ip_range_set
    for line in "${existing_lines[@]}"; do
        ip_range_set["$line"]=1
    done

    # Add server IPs
    for ip in "${SERVER_IPS[@]}"; do
        ip_int=$(ip_to_int "$ip")
        entry="[$ip_int, $ip_int]"
        if [[ -z "${ip_range_set["$entry"]}" ]]; then
            existing_lines+=("$entry")
            ip_range_set["$entry"]=1
            echo "➕ Added $ip to BTWAF whitelist."
        else
            echo "✅ $ip already in BTWAF whitelist."
        fi
    done

    # Save updated JSON
    {
        echo "["
        printf "  %s\n" "$(IFS=,; echo "${existing_lines[*]}")"
        echo "]"
    } > "$BTWAF_FILE"

    BTWAF_BACKUP_PATH="$backup_path"
}

# === Add to firewalld ===
add_to_firewalld() {
    if ! command -v firewall-cmd &>/dev/null; then
        echo "❌ firewalld not installed."
        return
    fi

    local backup_file="$FIREWALL_BACKUP_DIR/firewall_backup_$(date +%F_%H-%M-%S).txt"
    echo "📦 Backing up firewall rules to $backup_file..."
    firewall-cmd --list-all --permanent > "$backup_file"
    FIREWALL_BACKUP_PATH="$backup_file"

    current_rules=$(firewall-cmd --list-rich-rules --permanent)
    for ip in "${SERVER_IPS[@]}"; do
        rule="rule family='ipv4' source address='$ip' accept"
        if ! grep -Fxq "$rule" <<< "$current_rules"; then
            firewall-cmd --permanent --add-rich-rule="$rule"
            echo "➕ Allowed $ip in firewalld."
        else
            echo "✅ $ip already allowed in firewalld."
        fi
    done

    firewall-cmd --reload
}

# === Main ===
get_server_ips
if [[ ${#SERVER_IPS[@]} -eq 0 ]]; then
    echo "❌ No valid server IPs found."
    exit 1
fi

echo "🔍 Found IPs: ${SERVER_IPS[*]}"

add_to_btwaf_whitelist
add_to_firewalld

echo -e "\n✅ Done!"
[[ -n "$BTWAF_BACKUP_PATH" ]] && echo "📂 BTWAF whitelist backup: $BTWAF_BACKUP_PATH"
[[ -n "$FIREWALL_BACKUP_PATH" ]] && echo "📂 Firewall rules backup: $FIREWALL_BACKUP_PATH"
