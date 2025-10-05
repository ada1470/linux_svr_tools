#!/usr/bin/python3
# coding: utf-8

import sys
sys.path.insert(0, '/www/server/panel/class')

import db
import public

# Step 1: Read encrypted password from DB
sql = db.Sql()
enc_pwd = sql.table('config').where('id=?', (1,)).getField('mysql_root')
print("Encrypted password:", enc_pwd)
