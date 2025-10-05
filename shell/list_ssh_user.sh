#!/bin/bash
echo "🔎 SSH Access Report for $(hostname)"
echo "--------------------------------------"

# Loop through users with real shells
awk -F: '($7 !~ /nologin|false/) {print $1":"$6":"$7}' /etc/passwd | while IFS=: read -r user home shell; do
    echo "👤 User: $user"
    echo "   Home: $home"
    echo "   Shell: $shell"

    # Check password status
    if passwd -S "$user" 2>/dev/null | grep -q " P "; then
        echo "   Password: ✅ set"
    else
        echo "   Password: ❌ not set/locked"
    fi

    # Check for authorized_keys
    if [ -f "$home/.ssh/authorized_keys" ]; then
        echo "   SSH Key: ✅ $(wc -l < "$home/.ssh/authorized_keys") key(s) in $home/.ssh/authorized_keys"
    else
        echo "   SSH Key: ❌ none"
    fi

    echo
done
