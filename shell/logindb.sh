#!/bin/bash

# Use BT Panel's internal Python to extract and decrypt MySQL root password
mysql_pwd=$(/www/server/panel/pyenv/bin/python - <<'EOF'
import sys
sys.path.insert(0, '/www/server/panel/class')
import db
import public

# Read password from DB
sql = db.Sql()
enc_pwd = sql.table('config').where('id=?', (1,)).getField('mysql_root')
print(enc_pwd)
EOF
)

# Check if password retrieval succeeded
if [ -z "$mysql_pwd" ]; then
    echo "❌ Failed to retrieve MySQL root password."
    exit 1
fi

# Step 3: Use the password to log in via mysql CLI
mysql -uroot -p"$mysql_pwd"
