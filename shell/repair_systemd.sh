#!/bin/bash
# systemd / systemctl repair tool for CentOS 7

LOGFILE="/root/systemd_repair.log"

log() {
    echo -e "[`date '+%Y-%m-%d %H:%M:%S'`] $1" | tee -a "$LOGFILE"
}

log "=== Starting systemctl/systemd repair ==="

# 1. Check systemctl binary
if ! command -v systemctl &>/dev/null; then
    log "❌ systemctl command not found! Trying to reinstall systemd..."
    yum reinstall -y systemd >>"$LOGFILE" 2>&1
else
    log "✅ systemctl command exists: $(systemctl --version | head -n1)"
fi

# 2. Verify integrity of systemd package
log "🔎 Verifying systemd files..."
rpm -Va systemd >>"$LOGFILE" 2>&1
if [ $? -ne 0 ]; then
    log "⚠️ Some systemd files are corrupted, reinstalling..."
    yum reinstall -y systemd >>"$LOGFILE" 2>&1
else
    log "✅ systemd files check passed"
fi

# 3. Check dependencies
for pkg in dbus systemd-libs; do
    if ! rpm -q $pkg &>/dev/null; then
        log "❌ Missing dependency: $pkg, installing..."
        yum install -y $pkg >>"$LOGFILE" 2>&1
    else
        log "✅ Dependency found: $pkg"
        yum reinstall -y $pkg >>"$LOGFILE" 2>&1
    fi
done

# 4. Reload systemd manager
log "🔄 Reloading systemd manager..."
systemctl daemon-reexec 2>>"$LOGFILE"
systemctl daemon-reload 2>>"$LOGFILE"

# 5. Test if systemctl works
if systemctl list-units --type=service &>/dev/null; then
    log "✅ systemctl appears to be working correctly now."
else
    log "❌ systemctl is still broken. Check $LOGFILE for details."
    log "👉 You may need to boot into rescue mode and manually reinstall systemd."
fi

log "=== Repair process finished ==="
