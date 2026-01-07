#!/usr/bin/env bash
set -euo pipefail

MASTER_URL="${1:-}"
SLAVE_NAME="${2:-$(hostname -s)}"
SECRET="${3:-public}"

if [[ -z "$MASTER_URL" ]]; then
  echo "Usage: $0 <MASTER_URL> [SLAVE_NAME] [SECRET]"
  echo 'Example:'
  echo "  $0 \"http://master:8088/smokeping/smokeping.fcgi\" host2 \"S3cr3t-Long-Random\""
  exit 1
fi

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Please run as root (use sudo)."
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

echo "===> Installing SmokePing Slave (Debian/Ubuntu)"
echo "===> MASTER_URL : $MASTER_URL"
echo "===> SLAVE_NAME : $SLAVE_NAME"
echo "===> SECRET     : (hidden)"

echo "===> Installing packages"
apt-get update -y
apt-get install -y --no-install-recommends \
  smokeping fping perl ca-certificates curl \
  libio-socket-ssl-perl libsys-syslog-perl

# fping 权限（Debian/Ubuntu 推荐 setcap）
FPING_BIN="$(command -v fping || true)"
if [[ -z "$FPING_BIN" ]]; then
  echo "ERROR: fping not found after installation."
  exit 1
fi

echo "===> Setting capabilities on fping"
if command -v setcap >/dev/null 2>&1; then
  setcap cap_net_raw,cap_net_admin+ep "$FPING_BIN" || true
else
  chmod u+s "$FPING_BIN" || true
fi

# smokeping 二进制路径（Debian/Ubuntu 通常在 /usr/sbin）
SMOKEPING_BIN="$(command -v smokeping || true)"
if [[ -z "$SMOKEPING_BIN" ]]; then
  echo "ERROR: smokeping not found after installation."
  exit 1
fi

echo "===> Preparing directories"
install -d -o smokeping -g smokeping /var/lib/smokeping-slave

echo "===> Writing shared secret file"
SECRET_FILE="/etc/smokeping/secret.txt"
printf "%s" "$SECRET" > "$SECRET_FILE"
chown smokeping:smokeping "$SECRET_FILE"
chmod 600 "$SECRET_FILE"

echo "===> Quick check master URL reachability"
# 只做一次 HEAD 检测，不阻塞（某些站点可能不支持 HEAD）
curl -fsSIL --max-time 5 "$MASTER_URL" >/dev/null || \
  echo "WARN: Cannot HEAD $MASTER_URL now. If service fails, verify URL and firewall."

echo "===> Creating systemd service"
cat > /etc/systemd/system/smokeping-slave.service <<EOF
[Unit]
Description=SmokePing Slave
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=smokeping
Group=smokeping

# systemd 自动创建 /run/smokeping（避免 pid 目录不存在）
RuntimeDirectory=smokeping
RuntimeDirectoryMode=0755

ExecStart=$SMOKEPING_BIN \\
  --master-url=$MASTER_URL \\
  --slave-name=$SLAVE_NAME \\
  --cache-dir=/var/lib/smokeping-slave \\
  --shared-secret=$SECRET_FILE \\
  --pid-dir=/run/smokeping \\
  --nodaemon

Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

echo "===> Enabling and starting service"
systemctl daemon-reload
systemctl enable --now smokeping-slave

echo
echo "===> Done."
echo "Check: systemctl status smokeping-slave --no-pager"
echo "Logs : journalctl -u smokeping-slave -e --no-pager"
echo
echo "IMPORTANT (Master side):"
echo "  - Master must have slave name '$SLAVE_NAME' configured"
echo "  - Master secrets must include: $SLAVE_NAME:$SECRET"
echo "  - Ensure slave can access MASTER_URL (port/firewall/DNS)"
