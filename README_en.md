# ipkiller.sh (English)

A shell script for automated web log analysis and firewall rule management. This tool helps detect and block high-frequency IPs or suspicious spiders, manage firewalld rules, and interact with Baota WAF (btwaf).

## 🔧 Features

- Analyze Nginx / Apache logs for top IPs and IP ranges
- Identify known spiders (Baidu, Sogou, Petal, etc.)
- Auto-block unknown or unlisted spiders
- Manage firewalld rules: add, remove, sync, backup, restore
- Display server resource usage: CPU, Memory, Disk, Load, etc.
- Restart Web / PHP / MySQL services
- Supports htop (optional)

## 📁 Structure

- `ipkiller_zh.sh` - Main script (Chinese version)
- `/www/wwwlogs/` - Log directory
- `/home/www/backup/firewall/` - Backup location
- `/tmp/*.txt` - Temporary files during runtime

## 🚀 Getting Started

```bash
bash ipkiller_zh.sh
```

## 🧰 Menu Options

Option	Function
1	Clean logs
2	Analyze logs
3	Block suspicious IPs
4	Backup firewall config
5	Restore firewall config
6	Edit firewall IP rules
7	Sync DB rules to firewalld
8	Check/disable enhanced CC mode
9	Restart Web server
10	Restart PHP
11	Restart MySQL
12	Show 'top'
13	Show 'htop' (if installed)
0	Exit
## 🔐 WAF & CC Mode
Set cc_mode = 4 means Enhanced Defense Mode in Baota. The script offers a bulk downgrade to normal mode (cc_mode = 1) to reduce false positives.

## 📋 License
MIT License.