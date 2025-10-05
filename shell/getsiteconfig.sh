#!/bin/bash

# Color
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
RESET='\033[0m'

echo -e "📦 Reading site configurations...\n"

# Define elements to extract
elems=("template_dir" "site_name" "templatefanmulu_dir" "open" "jump" "indexhide" "userhide" "jumpfilm" "indexjump" "gg")

# Format header
printf "%-35s | %-15s | %-15s | %-10s | %-10s | %-10s | %-10s | %-10s | %-10s | %-10s | %-10s | %-10s | %-10s\n" \
"Domain" "Template" "Site Name" "FML Tpl" "Open" "Jump" "IdxHide" "UsrHide" "JmpFilm" "IdxJump" "GG"

echo "------------------------------------------------------------------------------------------------------------------------------------------------------"

# Define base paths
base_path="/home/www/wwwroot"

# Find config.php files
# find "$base_path" -type f -path "*/site/*/config.php" | sort | while read -r config_path; do
find "$base_path" -type f -path "*/site/*/config.php" | while read -r config_path; do
    domain=$(basename "$(dirname "$config_path")")  # Extract domain_name from site/<domain_name>/config.php

    # Determine if it's a 泛目录 or 正规 site
    if [[ "$config_path" == *"/public/site/"* ]]; then
        type="泛目录"
    else
        type="正规"
    fi

    # Extract config using PHP CLI
    result=$(php -r "
        error_reporting(0);
        \$config = include('$config_path');
        \$out = [];
        \$out[] = '$domain';  // Domain
        \$out[] = \$config['site']['template_dir'] ?? '';
        \$out[] = \$config['site']['site_name'] ?? '';
        \$out[] = \$config['site']['templatefanmulu_dir'] ?? \$config['site']['tpl'] ?? '';
        \$out[] = \$config['seo']['open'] ?? '';
        \$out[] = \$config['seo']['jump'] ?? '';
        \$out[] = \$config['seo']['indexhide'] ?? '';
        \$out[] = \$config['seo']['userhide'] ?? '';
        \$out[] = \$config['seo']['jumpfilm'] ?? '';
        \$out[] = \$config['seo']['indexjump'] ?? '';
        \$out[] = \$config['seo']['gg'] ?? '';
        echo implode('|', \$out);
    ")

    # Read and display output
    IFS="|" read -r domain template site tpl open jump idxhide usrhide jmpfilm idxjump gg <<< "$result"

    printf "%-35s | %-15s | %-15s | %-10s | %-10s | %-10s | %-10s | %-10s | %-10s | %-10s | %-10s\n" \
    "$domain" "$template" "$site" "$tpl" "$open" "$jump" "$idxhide" "$usrhide" "$jmpfilm" "$idxjump" "$gg"
done

