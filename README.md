# ipkiller.sh 中文版

一个面向 Linux 服务器的自动化日志分析与防火墙管理脚本，支持对高频访问的 IP 或可疑蜘蛛行为进行检测、标注、封锁，同时可管理 firewalld 规则与 CC 防御模式。

## 🔧 功能特性

- 🔍 分析 Nginx / Apache 日志，获取请求最多的 IP / 网段
- 🕷️ 自动识别并标注常见搜索引擎蜘蛛（百度、神马等）
- ❌ 自动封锁“未知来源”或“非白名单蜘蛛”的 IP / 网段
- 🔐 操作 firewalld 规则（添加、删除、同步、备份、恢复）
- 🧠 显示系统资源情况（CPU、内存、磁盘、负载等）
- 🚀 支持重启 Web、PHP、MySQL 服务
- 📊 可视化界面支持 `htop`（可选安装）

## 📁 文件结构

- `ipkiller.sh`：主脚本（已翻译为中文）
- `/www/wwwlogs/`：默认日志目录
- `/home/www/backup/firewall/`：防火墙配置备份目录
- `/tmp/*.txt`：脚本运行时的临时文件

## 📌 使用前提

- 操作系统：CentOS / Debian / Ubuntu
- 已安装：`firewalld`、`sqlite3`、`awk`、`grep`、`systemctl` 等常规工具
- 建议：使用宝塔面板（面板路径 `/www/server/panel/`）

## 🚀 快速开始

```bash
bash ipkiller.sh
```

执行后会自动检测 Web 服务类型，并进入交互式菜单界面。

## 🧰 菜单说明

| 编号 | 功能                    |
|------|-------------------------|
| 1    | 清理 Nginx/Apache 日志 |
| 2    | 分析访问日志            |
| 3    | 封锁高频访问 IP         |
| 4    | 备份 firewalld 配置     |
| 5    | 恢复 firewalld 配置     |
| 6    | 手动编辑防火墙规则      |
| 7    | 同步 DB 规则至 firewalld |
| 8    | 检查并可关闭 CC 增强模式|
| 9    | 重启 Web 服务（Nginx/Apache）|
| 10   | 重启 PHP-FPM 服务       |
| 11   | 重启 MySQL              |
| 12   | 显示系统资源（top）     |
| 13   | 图形化资源管理（htop）  |
| 0    | 退出脚本                |

## 🛡️ CC 防护增强模式说明

宝塔防火墙（BT WAF）中的 `cc_mode = 4` 表示启用了增强型防护，脚本提供批量降级为普通模式的功能，适用于误封频发的情况。

## 💾 防火墙数据库说明

脚本会将封锁的 IP 或网段记录入 SQLite 数据库：
- 路径：`/www/server/panel/data/db/firewall.db`
- 表名：`firewall_ip`
- 支持与 firewalld 规则自动同步

## 🧹 临时文件清单

| 路径                   | 用途           |
|------------------------|----------------|
| `/tmp/top_ips.txt`     | 存放高频IP     |
| `/tmp/ips_to_block.txt`| 标注后的IP     |
| `/tmp/ip_range_summary`| 网段汇总       |
| `/tmp/btwaf_cc_mode_check.txt` | cc_mode 检查结果 |

## 📦 示例用法

封锁分析出的所有未知来源 IP：
```bash
# 启动脚本
bash ipkiller.sh

# 选择 2 分析日志，选择 3 封锁 IP
```

## 📋 License

MIT License - 可自由修改与再发布。