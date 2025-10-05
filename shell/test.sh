#!/bin/bash
CONF_DIR="/www/server/panel/vhost/nginx"
BACKUP_DIR="/root/nginx_conf_backup_$(date +%F_%H-%M-%S)"
mkdir -p "$BACKUP_DIR"

echo "🔄 Backing up original .conf files to $BACKUP_DIR..."
cp "$CONF_DIR"/*.conf "$BACKUP_DIR"

echo "🔍 Updating server_name directives..."

for file in "$CONF_DIR"/*.conf; do
  # Extract domain (assumes domain.com is always the first one)
  domain=$(grep -oP 'server_name\s+\K[^;]+' "$file" | awk '{print $1}')
  wildcard="*.$domain"

  # Check if *.domain.com is already present
  if ! grep -q "\*\.$domain" "$file"; then
    sed -i "/server_name/s/;$/ $wildcard;/" "$file"
    echo "✅ Updated: $file"
  else
    echo "⚠️ Already contains wildcard: $file"
  fi
done

echo "✅ All done. Reloading nginx..."
nginx -t && systemctl reload nginx
