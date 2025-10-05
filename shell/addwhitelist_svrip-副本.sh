#!/bin/bash

# Detect OS
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
else
    echo "❌ Cannot detect OS."
    exit 1
fi

# Get IP list (exclude loopback and docker/bridge addresses)
SERVER_IPS=()
for ip in $(hostname -I); do
    if [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && [[ ! $ip =~ ^127\. ]] && [[ ! $ip =~ ^172\.1[6-9]\. ]] && [[ ! $ip =~ ^172\.2[0-9]\. ]] && [[ ! $ip =~ ^172\.3[0-1]\. ]] && [[ ! $ip =~ ^10\. ]] && [[ ! $ip =~ ^192\.168\. ]]; then
        SERVER_IPS+=("$ip")
    fi
done

if [ ${#SERVER_IPS[@]} -eq 0 ]; then
    echo "❌ No valid external IPs found."
    exit 1
fi

# Add to BTWAF whitelist if exists
add_to_btwaf_whitelist() {
    local whitelist_file="/www/server/btwaf/rule/ip_white.json"

    if [ ! -f "$whitelist_file" ]; then
        echo "ℹ️ BTWAF not installed. Skipping BTWAF whitelist."
        return
    fi

    echo "🔧 Adding IPs to BTWAF whitelist: ${SERVER_IPS[*]}"
    # Backup existing whitelist
    cp "$whitelist_file" "$whitelist_file.bak"

    # Read current whitelist into array
    current_entries=$(jq -c '.[]' "$whitelist_file" 2>/dev/null || echo "")

    for ip in "${SERVER_IPS[@]}"; do
        # Check if IP already exists
        if echo "$current_entries" | grep -q "\"$ip\""; then
            echo "✅ $ip already in whitelist."
            continue
        fi

        # Add as ["ip","ip"] entry
        current_entries="$current_entries"$'\n'"[\"$ip\",\"$ip\"]"
    done

    # Build new JSON array
    echo "[" > "$whitelist_file"
    echo "$current_entries" | sed '/^$/d' | paste -sd "," - >> "$whitelist_file"
    echo "]" >> "$whitelist_file"

    echo "✅ BTWAF whitelist updated."
}

# Add to system firewall
add_to_firewall() {
    for ip in "${SERVER_IPS[@]}"; do
        if [[ "$OS" == "centos" ]]; then
            echo "🔧 Adding $ip to firewalld..."
            firewall-cmd --permanent --add-rich-rule="rule family='ipv4' source address='$ip' accept" && \
            echo "✅ $ip allowed in firewalld"
        elif [[ "$OS" == "ubuntu" ]]; then
            echo "🔧 Adding $ip to UFW..."
            ufw allow from "$ip" comment "Allowed by auto-whitelist script" && \
            echo "✅ $ip allowed in ufw"
        else
            echo "❌ Unsupported OS: $OS"
            return
        fi
    done

    # Reload if firewalld
    if [[ "$OS" == "centos" ]]; then
        firewall-cmd --reload
    elif [[ "$OS" == "ubuntu" ]]; then
        ufw reload
    fi
}

add_to_firewall

if [ -f /www/server/btwaf/rule/ip_white.json ]; then
    add_to_btwaf_whitelist
fi


