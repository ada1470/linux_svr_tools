#!/usr/bin/env bash
# show-online-ips.sh
# Show currently online/logged-in users and their remote IPs.
# Run as root for best results.

OUTDIR="/root/online-ips-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUTDIR"

echo "Gathering online/login info... (saving to $OUTDIR)"
echo

# 1) From who (utmp)
echo "==== from who (utmp) ====" | tee "$OUTDIR/who.txt"
if command -v who >/dev/null 2>&1; then
  # show user, tty, login time, and host/ip (if present)
  who -uH | tee -a "$OUTDIR/who.txt"
else
  echo "who not found" | tee -a "$OUTDIR/who.txt"
fi
echo

# 2) From w (summary)
echo "==== from w (current sessions) ====" | tee "$OUTDIR/w.txt"
if command -v w >/dev/null 2>&1; then
  w -h | tee -a "$OUTDIR/w.txt"
else
  echo "w not found" | tee -a "$OUTDIR/w.txt"
fi
echo

# 3) From ss/lsof: established SSH or TCP shells
echo "==== ssh / TCP established connections (ss + lsof) ====" | tee "$OUTDIR/ss_lsof.txt"

# Use ss to list established connections related to ssh (port 22) and capture remote IP + pid if available
if command -v ss >/dev/null 2>&1; then
  # show established tcp conns and try to find associated process
  ss -tnp state established '( sport = :ssh or dport = :ssh )' 2>/dev/null | tee -a "$OUTDIR/ss_lsof.txt"
fi

# fallback / supplement using lsof to find sshd processes with established sockets
if command -v lsof >/dev/null 2>&1; then
  lsof -nP -iTCP -sTCP:ESTABLISHED 2>/dev/null | egrep 'sshd|bash|sh|python|perl' | tee -a "$OUTDIR/ss_lsof.txt"
fi

echo

# 4) Try to map pty-owning processes to remote IPs via /proc (catches reverse shells)
echo "==== /proc -> find pty processes + remote address (best-effort) ====" | tee "$OUTDIR/proc_pty.txt"

# iterate processes and check fd pointing to /dev/pts/* then check their socket peer via /proc/<pid>/net/tcp and ip mapping
for pid in $(ls /proc | egrep '^[0-9]+$' | sort -n); do
  # skip if no exe
  [ -r "/proc/$pid/fd" ] || continue
  # check fd symlink 0/1/2 for a pts
  tty=$(readlink -f /proc/$pid/fd/0 2>/dev/null || true)
  if [[ "$tty" == /dev/pts/* ]]; then
    user=$(ps -p "$pid" -o user= 2>/dev/null)
    cmd=$(ps -p "$pid" -o args= 2>/dev/null)
    # try to find a remote IP from /proc/$pid/net/tcp (best-effort)
    peerip=""
    if [ -r "/proc/$pid/net/tcp" ]; then
      # parse hex ip:port in column 2 (local) and 3 (rem), convert rem ip
      rem_hex=$(awk 'NR>1 && $4 ~ /01/ {print $3; exit}' /proc/$pid/net/tcp 2>/dev/null || true)
      if [ -n "$rem_hex" ]; then
        # rem_hex looks like '0100007F:0035' (ip:port) in hex; convert ip
        iphex=$(echo "$rem_hex" | cut -d: -f1)
        # convert little-endian hex to dotted
        peerip=$(printf "%d.%d.%d.%d\n" 0x${iphex:6:2} 0x${iphex:4:2} 0x${iphex:2:2} 0x${iphex:0:2} 2>/dev/null || true)
      fi
    fi
    printf "PID:%s USER:%s TTY:%s IP:%s CMD:%s\n" "$pid" "${user:-?}" "${tty##*/}" "${peerip:-?}" "${cmd:-?}" | tee -a "$OUTDIR/proc_pty.txt"
  fi
done

echo

# 5) Consolidate candidate remote IPs from different sources and print unique list
echo "==== consolidated list (username, ip, tty, pid, source) ====" | tee "$OUTDIR/consolidated.txt"

# Collect IPs/users from 'who' output
awk 'NR>1 {ip=$5; if (ip=="") ip="?"; print $1"\t"ip"\t"$2"\twho"}' <(who -uH 2>/dev/null || true) 2>/dev/null >> "$OUTDIR/consolidated.tmp"

# Collect from ss output file (extract remote ip and pid info)
if [ -s "$OUTDIR/ss_lsof.txt" ]; then
  # Try to parse lines containing pid= and ip:port columns
  grep -Eo 'users:\(\("[^"]+",pid=[0-9]+' "$OUTDIR/ss_lsof.txt" 2>/dev/null | sed -E 's/users:\(\("([^"]+)",pid=([0-9]+).*/\1\t\2\tss/' >> "$OUTDIR/consolidated.tmp" 2>/dev/null || true

  # Extract remote IPs like x.x.x.x:port
  grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}:[0-9]+' "$OUTDIR/ss_lsof.txt" 2>/dev/null | sed 's/:.*//' | sort -u | while read ip; do
    echo -e "?\t$ip\t?\tss" >> "$OUTDIR/consolidated.tmp"
  done
fi

# Collect from lsof parsed lines (if present)
if [ -f "$OUTDIR/ss_lsof.txt" ]; then
  awk '/sshd/ { for(i=1;i<=NF;i++) if ($i ~ /->/) { split($i,a,"->"); print "?\t"a[2]"\t?\tlsof" } }' "$OUTDIR/ss_lsof.txt" 2>/dev/null | sed 's/:.*//' >> "$OUTDIR/consolidated.tmp" 2>/dev/null || true
fi

# Collect from proc_pty parsing (which printed PID and IP)
awk -F' ' '/PID:/ { pid=$1; user=""; tty=""; ip="?"; cmd=""; 
  for(i=1;i<=NF;i++){
    if ($i ~ /^USER:/) user=substr($i,6)
    if ($i ~ /^TTY:/) tty=substr($i,5)
    if ($i ~ /^IP:/) ip=substr($i,4)
  }
  print (user==""?"?":user) "\t" ip "\t" (tty==""?"?":tty) "\tproc"
}' "$OUTDIR/proc_pty.txt" 2>/dev/null >> "$OUTDIR/consolidated.tmp" || true

# Clean and dedupe
if [ -f "$OUTDIR/consolidated.tmp" ]; then
  # Normalize tabs and unique
  awk -F'\t' '{gsub(/\r/,""); print $1 "\t" $2 "\t" $3 "\t" $4}' "$OUTDIR/consolidated.tmp" \
    | sort -u \
    | awk -F'\t' '{printf "%-15s %-20s %-8s %s\n", $1, $2, $3, $4}' | tee "$OUTDIR/consolidated.txt"
  rm -f "$OUTDIR/consolidated.tmp"
else
  echo "No candidate sessions found." | tee "$OUTDIR/consolidated.txt"
fi

echo
echo "Saved outputs into: $OUTDIR"
echo "If you see suspicious remote IPs here, copy them and I can help you investigate (grep logs, check process, whois, block, etc.)"


#!/usr/bin/env bash
# show-login-ips.sh
# Show IPs of actual login sessions (SSH/interactive shells) only.
# Run as root for best results.

set -euo pipefail
TMP=$(mktemp)
OUT=$(mktemp)

cleanup() { rm -f "$TMP" "$OUT"; }
trap cleanup EXIT

echo "Scanning for real login sessions (sshd + interactive shells)..."

# 1) Use ss to find established connections owned by sshd (works even if sshd uses nonstandard port)
# Example ss line contains: users:(("sshd",pid=1234,fd=3))
ss -tnp state established 2>/dev/null \
  | grep -E 'users:\(\("sshd"|sshd,' || true \
  > "$TMP".ss_raw

# Parse ss output: extract remote IP and sshd pid
if [ -s "$TMP".ss_raw ]; then
  while read -r line; do
    # extract remote ip:port column (for ss -tnp typical layout, it's the 5th column)
    # robustly find first occurrence of x.x.x.x:port or [::]:port
    remote=$(echo "$line" | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}:[0-9]+' | head -n1 || true)
    # fallback for IPv6
    if [ -z "$remote" ]; then
      remote=$(echo "$line" | grep -Eo '\[[0-9a-fA-F:]+\]:[0-9]+' | head -n1 || true)
    fi
    ip="${remote%%:*}"
    # extract pid from users:(("sshd",pid=1234
    pid=$(echo "$line" | grep -Eo 'pid=[0-9]+' | head -n1 | cut -d= -f2 || true)
    if [ -n "$ip" ] && [ -n "$pid" ]; then
      # find the logged-in username by inspecting sshd process or its children
      user=$(ps -p "$pid" -o user= 2>/dev/null | awk '{print $1}' || true)
      # sometimes sshd pid is a parent; look for "sshd: username" child
      child_user=$(ps --no-headers -o user=,cmd= --ppid "$pid" 2>/dev/null \
                    | awk -F'[: ]+' '/sshd: /{print $2; exit}' || true)
      if [ -n "$child_user" ]; then user="$child_user"; fi
      echo -e "${ip}\t${user:-?}\tsshd_pid:${pid}" >> "$OUT"
    fi
  done < "$TMP".ss_raw
fi

# 2) Use lsof restricted to sshd to ensure we don't pick up web clients.
# This avoids listing processes accessing port 80/443.
if command -v lsof >/dev/null 2>&1; then
  lsof -nP -a -c sshd -iTCP -sTCP:ESTABLISHED 2>/dev/null \
    | awk 'NR>1 { for(i=1;i<=NF;i++) if ($i ~ /->[0-9]/) { split($i,a,"->"); split(a[2],b,":"); print b[1] } }' \
    | sort -u \
    | while read -r ip; do
      # map ip to possible sshd pid & user from ss results (if present)
      existing=$(awk -vip="$ip" -F'\t' '$1==ip{print $0; exit}' "$OUT" || true)
      if [ -z "$existing" ]; then
        echo -e "${ip}\t?\tlsof" >> "$OUT"
      fi
    done
fi

# 3) Find interactive shells whose ancestor is sshd (covers shells spawned by ssh sessions)
# For every process with a controlling tty under /dev/pts, walk parent chain to see if any ancestor is sshd.
for pid in $(ls /proc | egrep '^[0-9]+$' | sort -n); do
  # only consider processes with a pts controlling terminal (likely interactive)
  tty=$(readlink -f /proc/$pid/fd/0 2>/dev/null || true)
  if [[ "$tty" != /dev/pts/* ]]; then
    continue
  fi
  # climb parent chain searching for sshd
  cur=$pid
  found_sshd_pid=""
  while [ "$cur" != "1" ] && [ -n "$cur" ]; do
    ppid=$(awk -F' ' '{print $4}' /proc/$cur/stat 2>/dev/null || echo "")
    cmd=$(ps -p "$cur" -o comm= 2>/dev/null || echo "")
    if [[ "$cmd" == "sshd" ]]; then
      found_sshd_pid=$cur
      break
    fi
    if [ -z "$ppid" ]; then break; fi
    cur=$ppid
  done
  if [ -n "$found_sshd_pid" ]; then
    # find remote IP for that sshd pid if present in ss output
    ip=$(awk -vpid="$found_sshd_pid" -F'\t' '$3==("sshd_pid:"pid){print $1; exit}' "$OUT" || true)
    user=$(ps -p "$pid" -o user= 2>/dev/null | awk '{print $1}' || true)
    if [ -n "$ip" ]; then
      echo -e "${ip}\t${user:-?}\tssh_shell_pid:${pid}" >> "$OUT"
    fi
  fi
done

# 4) Normalize and output a clean deduped list of IPs (with optional username if known)
# Remove local loopback and empty entries
awk -F'\t' '
  { ip=$1; user=$2; note=$3;
    if (ip=="" || ip=="-" ) next;
    if (ip ~ /^127\.0\.0\.1$/) next;
    if (ip ~ /^::1$/) next;
    print ip"\t"user"\t"note
  }
' "$OUT" | sort -u > "$TMP"

if [ ! -s "$TMP" ]; then
  echo "No active SSH/login sessions found."
  exit 0
fi

echo
echo "==== Active login IPs (unique) ===="
# Print with columns: IP    USER    NOTE
printf "%-16s %-12s %s\n" "IP" "USER" "NOTE"
printf "%-16s %-12s %s\n" "----------------" "------------" "----------------"
while read -r line; do
  ip=$(echo "$line" | awk '{print $1}')
  user=$(echo "$line" | awk '{print $2}')
  note=$(echo "$line" | awk '{$1=$2=""; sub(/^  /,""); print $0}')
  printf "%-16s %-12s %s\n" "$ip" "${user:-?}" "${note:-?}"
done < "$TMP"

# Final clean list of IP-only lines (if you need only IPs):
echo
echo "==== Clean IP list ===="
awk '{print $1}' "$TMP" | sort -u
