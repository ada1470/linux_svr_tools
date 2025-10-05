#!/bin/bash

get_nic_speed() {
    # Detect the first active (UP and LOWER_UP) non-loopback interface
    iface=$(ip -o link show | awk -F': ' '$2 != "lo" && $0 ~ /state UP/ && $0 ~ /LOWER_UP/ {print $2; exit}')

    if [ -z "$iface" ]; then
        echo "❌ No active, connected network interface found."
        return 1
    fi

    if ! command -v ethtool >/dev/null 2>&1; then
        echo "ℹ️ ethtool not found. Installing..."
        yum install -y ethtool || { echo "❌ Failed to install ethtool"; return 1; }
    fi

    echo "✅ Detected active interface: $iface"
    speed=$(ethtool "$iface" 2>/dev/null | grep -i speed)

    if [ -n "$speed" ]; then
        echo "$speed"
    else
        echo "⚠️ Speed info not available for $iface (possibly virtual or restricted)."
    fi
}

# Run it
get_nic_speed
