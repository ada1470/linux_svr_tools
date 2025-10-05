#!/bin/bash

echo "== Running Process Check =="
ps auxfww --sort=-%cpu | head -30

echo -e "\n== Open Ports =="
ss -tulnp

echo -e "\n== Cron Jobs =="
for user in $(cut -f1 -d: /etc/passwd); do
  echo "User: $user"
  crontab -u $user -l 2>/dev/null
done

echo -e "\n== Suspicious Executables in tmp =="
find /tmp /dev/shm /var/tmp -type f -executable -ls

# echo -e "\n== Recently Changed PHP Files =="
# find / -name "*.php" -mtime -2 2>/dev/null
echo -e "\n== Recently Changed PHP Files =="
find / -type f -name "*.php" -mtime -2 \
  ! -path "*/runtime/*" \
  ! -path "*/cache/*" \
  ! -path "*/temp/*" 2>/dev/null


echo -e "\n== Rootkit Hunter =="
which rkhunter && sudo rkhunter --check --sk

echo -e "\n== chkrootkit =="
which chkrootkit && sudo chkrootkit
