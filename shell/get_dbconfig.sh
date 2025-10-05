for f in /home/www/wwwroot/*/application/database.php; do
    site=$(basename "$(dirname "$(dirname "$f")")")   # program folder name

    # Extract value when it's a direct string
    db=$(grep -Po "'database'\s*=>\s*'[^']+'" "$f" \
        | sed -E "s/.*'database'\s*=>\s*'([^']+)'.*/\1/" )

    # Extract fallback from Env::get(...) if present
    if [ -z "$db" ]; then
        db=$(grep -Po "'database'\s*=>\s*Env::get\([^,]+,\s*'[^']+'" "$f" \
            | sed -E "s/.*,\s*'([^']+)'.*/\1/" )
    fi

    echo "$site: $db"
done
