#!/bin/bash

BACKUP_DIR="/home/www/backup/firewall"
DB_FILE="/www/server/panel/data/db/firewall.db"
mkdir -p "$BACKUP_DIR"

run_firewall_cmd() {
    if command -v firewall-cmd &>/dev/null; then
        case $1 in
            list) firewall-cmd --list-rich-rules --permanent ;;
            add)  firewall-cmd --permanent --add-rich-rule="$2" ;;
            remove) firewall-cmd --permanent --remove-rich-rule="$2" ;;
            reload) firewall-cmd --reload ;;
            backup) firewall-cmd --list-all --permanent ;;
        esac
    else
        echo "❌ firewalld not installed."
        exit 1
    fi
}

show_firewall_rules() {
    echo -e "\n== 📋 Current Firewall IP Rules ==\n"
    mapfile -t rules < <(run_firewall_cmd list)
    if [[ ${#rules[@]} -eq 0 ]]; then
        echo "⚠️  No rich rules configured."
        return
    fi

    printf " %-5s | %-7s | %-18s | %s\n" "Index" "Action" "IP Address" "Raw Rule"
    printf -- "---------------------------------------------------------------\n"
    for i in "${!rules[@]}"; do
        rule="${rules[$i]}"
        index=$((i + 1))
        ip=$(echo "$rule" | sed -n 's/.*source address="\([^"]*\)".*/\1/p')
        action=$(echo "$rule" | grep -q "drop" && echo "drop" || echo "accept")
        printf " %-5s | %-7s | %-18s | %s\n" "$index" "$action" "$ip" "$rule"
    done
}

backup_firewall_rules() {
    local filename="firewall_backup_$(date +%F_%H-%M-%S).txt"
    local fullpath="$BACKUP_DIR/$filename"
    echo "📦 Backing up rules to $fullpath..."
    run_firewall_cmd backup > "$fullpath"
    echo "✅ Backup complete."
}

recover_firewall_rules() {
    local latest_file
    latest_file=$(ls -t "$BACKUP_DIR"/*.txt 2>/dev/null | head -n 1)
    [[ -z "$latest_file" ]] && { echo "❌ No backup found."; return; }

    echo "♻️ Restoring from: $latest_file"
    mapfile -t current_rules < <(run_firewall_cmd list)
    for rule in "${current_rules[@]}"; do
        run_firewall_cmd remove "$rule"
    done

    while read -r line; do
        [[ "$line" =~ ^rule ]] && run_firewall_cmd add "$line"
    done < "$latest_file"

    run_firewall_cmd reload
    echo "✅ Restore complete."
}

add_new_firewall_rules() {
    echo -e "\nEnter IPs (one per line). Ctrl+D to finish:\n"
    ip_list=()
    while read -r ip; do [[ -n "$ip" ]] && ip_list+=("$ip"); done
    [[ ${#ip_list[@]} -eq 0 ]] && { echo "❌ No IPs entered."; return; }

    echo -n "Action (drop/accept) [default: drop]: "; read -r action
    [[ "$action" != "accept" ]] && action="drop"

    echo -n "Annotation/Comment (optional): "; read -r note
    [[ -z "$note" ]] && note="Added by firewall_manager.sh"
    now=$(date '+%Y-%m-%d %H:%M:%S')

    for ip in "${ip_list[@]}"; do
        rule="rule family='ipv4' source address='${ip}' $action"
        run_firewall_cmd add "$rule"
        sqlite3 "$DB_FILE" \
            "INSERT INTO firewall_ip (types, address, brief, addtime, chain) VALUES ('$action', '$ip', '$note', '$now', 'INPUT');"
        echo "➕ $ip ($action) added to firewall and DB."
    done

    run_firewall_cmd reload
    echo "✅ All rules applied and saved."
}

edit_existing_rules() {
    mapfile -t current_rules < <(run_firewall_cmd list)
    [[ ${#current_rules[@]} -eq 0 ]] && { echo "⚠️  No rules to edit."; return; }

    show_firewall_rules
    echo -n "Enter index(es) to remove (e.g. 3 or 2-4): "; read -r range

    if [[ "$range" =~ ^[0-9]+$ ]]; then
        indexes=("$range")
    elif [[ "$range" =~ ^([0-9]+)-([0-9]+)$ ]]; then
        indexes=($(seq "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"))
    else
        echo "❌ Invalid range."
        return
    fi

    for idx in "${indexes[@]}"; do
        rule="${current_rules[$((idx-1))]}"
        ip=$(echo "$rule" | sed -n 's/.*source address="\([^"]*\)".*/\1/p')
        [[ -n "$rule" ]] && {
            run_firewall_cmd remove "$rule"
            sqlite3 "$DB_FILE" "DELETE FROM firewall_ip WHERE address = '$ip';"
            echo "🗑️ Removed $ip from firewall and DB."
        }
    done

    run_firewall_cmd reload
    echo "✅ Rules updated."
}

sync_panel_to_firewall() {
    echo -e "\n🔽 Syncing panel DB → firewalld..."
    current_rules=$(run_firewall_cmd list)
    mapfile -t db_entries < <(sqlite3 "$DB_FILE" "SELECT types, address FROM firewall_ip WHERE address != ''")
    added=0

    for entry in "${db_entries[@]}"; do
        types=$(cut -d'|' -f1 <<< "$entry")
        ip=$(cut -d'|' -f2 <<< "$entry")
        [[ -z "$ip" ]] && continue
        rule="rule family='ipv4' source address='$ip' ${types}"

        if ! grep -Fxq "$rule" <<< "$current_rules"; then
            run_firewall_cmd add "$rule"
            echo "➕ Added: $ip ($types)"
            ((added++))
        fi
    done

    run_firewall_cmd reload
    echo "✅ Sync complete. $added new rule(s)."
}

sync_firewall_to_panel() {
    echo -e "\n🔼 Syncing firewalld → panel DB..."
    mapfile -t firewall_rules < <(run_firewall_cmd list)
    current_db=$(sqlite3 "$DB_FILE" "SELECT address FROM firewall_ip")

    added=0
    for rule in "${firewall_rules[@]}"; do
        ip=$(echo "$rule" | sed -n 's/.*source address="\([^"]*\)".*/\1/p')
        action=$(grep -q "drop" <<< "$rule" && echo "drop" || echo "accept")
        [[ -z "$ip" ]] && continue

        if ! grep -q "^$ip$" <<< "$current_db"; then
            sqlite3 "$DB_FILE" \
                "INSERT INTO firewall_ip (types, address, brief, addtime, chain) VALUES ('$action', '$ip', 'Synced from firewalld', datetime('now'), 'INPUT');"
            echo "➕ Inserted $ip ($action)"
            ((added++))
        fi
    done

    echo "✅ Sync complete. $added rule(s) added."
}

sync_menu() {
    echo -e "\n🔄 Sync Direction:"
    echo "1. 🔽 From BT panel DB → firewalld"
    echo "2. 🔼 From firewalld → BT panel DB"
    echo -n "Choose sync direction [1-2]: "
    read -r choice
    case $choice in
        1) sync_panel_to_firewall ;;
        2) sync_firewall_to_panel ;;
        *) echo "❌ Invalid input." ;;
    esac
}

# === Menu ===
while true; do
    echo -e "\n🛡️  Firewall Rule Manager"
    echo "1. 📋 Show current IP rules"
    echo "2. 📦 Backup current firewall rules"
    echo "3. ♻️  Restore firewall rules from latest backup"
    echo "4. ➕ Add new IP rules (multi-line paste)"
    echo "5. ✏️  Edit/Delete existing IP rules"
    echo "6. 🔄 Sync rules between panel DB and firewalld"
    echo "0. 🚪 Exit"
    echo -n "Select an option [0-6]: "
    read -r choice

    case $choice in
        1) show_firewall_rules ;;
        2) backup_firewall_rules ;;
        3) recover_firewall_rules ;;
        4) add_new_firewall_rules ;;
        5) edit_existing_rules ;;
        6) sync_menu ;;
        0) echo "👋 Goodbye."; exit 0 ;;
        *) echo "❌ Invalid choice." ;;
    esac
done
