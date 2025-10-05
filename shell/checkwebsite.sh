#!/bin/bash

# ──[ INPUT ]────────────────────────────────────────────────────
DOMAIN=$1
if [ -z "$DOMAIN" ]; then
    echo "❌ Please provide a domain. Example: ./check_website_issue.sh domain.com"
    exit 1
fi

# ──[ CONFIG ]────────────────────────────────────────────────────
NGINX_BIN="/www/server/nginx/sbin/nginx"
NGINX_CONF_DIR="/www/server/panel/vhost/nginx"
NGINX_ERROR_LOG="/www/server/nginx/logs/error.log"
NGINX_REWRITE_DIR="/www/server/panel/vhost/rewrite"

APACHE_BIN="/www/server/apache/bin/httpd"
APACHE_CONF_DIR="/www/server/panel/vhost/apache"
APACHE_HTACCESS_BASE="/home/www/wwwroot"

DEFAULT_PHP_VERSION="74"

# ──[ AUTO-DETECT SERVICES ]──────────────────────────────────────
HAS_NGINX=false
HAS_APACHE=false

if [ -x "$NGINX_BIN" ]; then
    HAS_NGINX=true
fi

if [ -x "$APACHE_BIN" ]; then
    HAS_APACHE=true
fi

# Auto-detect installed PHP-FPM version
PHP_VERSION=$(systemctl list-units --type=service | grep -oE 'php-fpm-[0-9]+\.[0-9]+' | sort -V | tail -n1 | sed 's/php-fpm-//' | sed 's/\.//')
PHP_VERSION=${PHP_VERSION:-$DEFAULT_PHP_VERSION}

# ──[ HEADER ]────────────────────────────────────────────────────
echo "────────────────────────────────────────────────────"
echo "🔎 Website Access Diagnostic Tool"
echo "📅 Time: $(date)"
echo "🌐 Domain: $DOMAIN"
echo "🌐 Web Server: $($HAS_NGINX && echo Nginx || echo '') $($HAS_APACHE && echo Apache || echo '')"
echo "🐘 PHP-FPM: $PHP_VERSION"
echo "────────────────────────────────────────────────────"

# ──[ FUNCTIONS ]─────────────────────────────────────────────────

check_nginx_running() {
    echo -e "\n🔍 Checking if Nginx is running..."
    if pgrep -x nginx > /dev/null; then
        echo "✅ Nginx is running."
    else
        echo "❌ Nginx is NOT running!"
        systemctl status nginx --no-pager
    fi
}

check_nginx_config_test() {
    echo -e "\n🔍 Testing Nginx configuration syntax..."
    $NGINX_BIN -t 2>&1
}

check_domain_dns() {
    echo -e "\n🔍 Checking domain DNS resolution..."
    getent hosts "$DOMAIN" || echo "❌ Domain could not be resolved."
}

check_site_config() {
    echo -e "\n🔍 Checking for site config..."

    if $HAS_NGINX; then
        local nginx_conf=$(grep -rl "$DOMAIN" "$NGINX_CONF_DIR"/*.conf 2>/dev/null)
        if [ -n "$nginx_conf" ]; then
            echo "✅ Nginx config detected: $nginx_conf"
            grep -i root "$nginx_conf"
        fi
    fi

    if $HAS_APACHE; then
        local apache_conf=$(grep -rl "$DOMAIN" "$APACHE_CONF_DIR"/*.conf 2>/dev/null)
        if [ -n "$apache_conf" ]; then
            echo "✅ Apache config detected: $apache_conf"
            grep -i DocumentRoot "$apache_conf"
        fi
    fi
}

check_root_dir() {
    echo -e "\n🔍 Checking if site root directory exists..."
    local root_dir=""

    if $HAS_NGINX; then
        local nginx_conf=$(grep -rl "$DOMAIN" "$NGINX_CONF_DIR"/*.conf 2>/dev/null)
        root_dir=$(grep -i 'root ' "$nginx_conf" | awk '{print $2}' | sed 's/;$//' | sed 's/^"//;s/"$//')
    elif $HAS_APACHE; then
        local apache_conf=$(grep -rl "$DOMAIN" "$APACHE_CONF_DIR"/*.conf 2>/dev/null)
        root_dir=$(grep -i 'DocumentRoot' "$apache_conf" | awk '{print $2}' | head -n 1 | sed 's/^"//;s/"$//')
    fi

    if [ -d "$root_dir" ]; then
        echo "✅ Root directory exists: $root_dir"
    else
        echo "❌ Root directory missing: $root_dir"
    fi
}


check_php_fpm() {
    echo -e "\n🔍 Checking PHP-FPM status for PHP $PHP_VERSION..."
    local fpm_unit="php-fpm-${PHP_VERSION}"

    if systemctl list-units --type=service | grep -q "${fpm_unit}.service"; then
        systemctl status "${fpm_unit}.service" --no-pager
    elif systemctl list-units --type=service | grep -q "$fpm_unit"; then
        systemctl status "$fpm_unit" --no-pager
    else
        echo "❌ PHP-FPM service for PHP $PHP_VERSION not found."
    fi
}

check_nginx_error_log() {
    echo -e "\n🔍 Checking recent Nginx error log entries..."
    tail -n 20 "$NGINX_ERROR_LOG"
}

check_firewall_ports() {
    echo -e "\n🔍 Checking firewall rules for ports 80/443..."
    firewall-cmd --list-ports | grep -qE '80|443' && echo "✅ Ports 80/443 open in firewalld." || echo "❌ Ports 80/443 may be blocked!"
}

check_rewrite_files() {
    echo -e "\n🔍 Checking rewrite rules..."

    if $HAS_NGINX; then
        local nginx_rewrite="$NGINX_REWRITE_DIR/${DOMAIN}.conf"
        [ -f "$nginx_rewrite" ] && echo "🌀 Nginx rewrite file found: $nginx_rewrite" || echo "⚠️  No Nginx rewrite file: $nginx_rewrite"
    fi

    if $HAS_APACHE; then
        local apache_conf=$(grep -rl "$DOMAIN" "$APACHE_CONF_DIR"/*.conf 2>/dev/null)
        local apache_root=$(grep -i 'DocumentRoot' "$apache_conf" | awk '{print $2}' | head -n 1 | sed 's/^"//;s/"$//')
        local htaccess="$apache_root/.htaccess"

        [ -f "$htaccess" ] && echo "🌀 Apache .htaccess found: $htaccess" || echo "⚠️  No .htaccess file in: $apache_root"
    fi
}

# ──[ RUN CHECKS ]────────────────────────────────────────────────
check_domain_dns
$HAS_NGINX && check_nginx_running
$HAS_NGINX && check_nginx_config_test
check_site_config
check_root_dir
check_php_fpm
$HAS_NGINX && check_nginx_error_log
check_firewall_ports
check_rewrite_files

echo -e "\n✅ Done. Please review output above."
