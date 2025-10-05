#!/bin/bash
# ssh_country_whitelist.sh
# Universal SSH country whitelist using ipset + iptables
# Works on CentOS 7/8 and Ubuntu/Debian
# WARNING: make sure your current public IP is allowed to avoid lockout

set -euo pipefail

# ------------------------------
# CONFIG
# ------------------------------
COUNTRY_WHITELIST="KH,TH,HK"      # Comma-separated ISO country codes
IPSET_NAME="ssh_whitelist"     # ipset name
SAFE_IP=$(curl -s https://ifconfig.me)   # your current IP (safety bypass)

# ------------------------------
# Detect OS
# ------------------------------
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
else
    echo "❌ Unsupported OS"
    exit 1
fi
echo "[*] Detected OS: $OS"

# ------------------------------
# Detect SSH port
# ------------------------------
SSH_PORT=$(grep -i "^Port " /etc/ssh/sshd_config | awk '{print $2}' | tail -n1)
SSH_PORT=${SSH_PORT:-22}
echo "[*] SSH port: $SSH_PORT"
echo "[*] Allowed countries: $COUNTRY_WHITELIST"
echo "[*] Safety IP: $SAFE_IP"

# ------------------------------
# Install dependencies
# ------------------------------
if [[ "$OS" =~ (centos|rhel) ]]; then
    yum install -y epel-release ipset iptables-services wget curl
    systemctl stop firewalld || true
    systemctl disable firewalld || true
    systemctl enable iptables
    systemctl start iptables
else
    apt-get update -y
    apt-get install -y ipset iptables-persistent wget curl
fi

# ------------------------------
# Create ipset
# ------------------------------
if ipset list "$IPSET_NAME" >/dev/null 2>&1; then
    ipset flush "$IPSET_NAME"
    ipset destroy "$IPSET_NAME"
fi
ipset create "$IPSET_NAME" hash:net family inet maxelem 65536

# Add safety IP
[ -n "$SAFE_IP" ] && ipset add "$IPSET_NAME" "$SAFE_IP/32" -exist

# ------------------------------
# Populate ipset from ipdeny
# ------------------------------
IFS=',' read -ra COUNTRIES <<< "$COUNTRY_WHITELIST"
for cc in "${COUNTRIES[@]}"; do
    cc_lower=$(echo "$cc" | tr '[:upper:]' '[:lower:]')
    url="http://www.ipdeny.com/ipblocks/data/countries/${cc_lower}.zone"
    echo "[*] Downloading CIDRs for $cc from $url"
    wget -qO- "$url" | while read cidr; do
        [ -n "$cidr" ] && ipset add "$IPSET_NAME" "$cidr" -exist
    done
done

# ------------------------------
# Apply iptables rules
# ------------------------------
# Remove old SSH rules (best effort)
iptables -D INPUT -p tcp --dport "$SSH_PORT" -j ACCEPT 2>/dev/null || true
iptables -D INPUT -p tcp --dport "$SSH_PORT" -m set ! --match-set "$IPSET_NAME" src -j DROP 2>/dev/null || true

# Allow SSH from ipset
iptables -I INPUT -p tcp --dport "$SSH_PORT" -m set --match-set "$IPSET_NAME" src -j ACCEPT
# Drop SSH from all others
iptables -I INPUT -p tcp --dport "$SSH_PORT" -m set ! --match-set "$IPSET_NAME" src -j DROP

# Ensure other essentials
iptables -I INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -I INPUT -i lo -j ACCEPT

# ------------------------------
# Save rules for persistence
# ------------------------------
if [[ "$OS" =~ (centos|rhel) ]]; then
    service iptables save || iptables-save > /etc/sysconfig/iptables
else
    netfilter-persistent save || iptables-save > /etc/iptables/rules.v4
fi

# Save ipset for restore on boot
ipset save > /etc/ipset.conf
if command -v systemctl >/dev/null 2>&1; then
    cat >/etc/systemd/system/ipset-restore.service <<'EOF'
[Unit]
Description=Restore ipset lists
After=network.target

[Service]
Type=oneshot
ExecStart=/sbin/ipset restore < /etc/ipset.conf
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable ipset-restore.service
fi

# ------------------------------
# Done
# ------------------------------
echo "[✔] SSH country whitelist applied."
echo "[*] ipset entries:"
ipset list "$IPSET_NAME"
echo "[*] iptables rules for SSH port $SSH_PORT:"
iptables -L INPUT -n --line-numbers | grep "$SSH_PORT"
echo "✅ Test SSH access from allowed and blocked countries."
