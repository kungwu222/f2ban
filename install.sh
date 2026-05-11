#!/usr/bin/env bash
set -e

echo "[*] 安装 Fail2ban（简易稳定版）"

if [[ "$EUID" -ne 0 ]]; then
  echo "[!] 请用 root 运行"
  exit 1
fi

# ========= 安装 =========
if [[ -f /etc/debian_version ]]; then
  apt update -y
  apt install -y fail2ban python3-systemd || apt install -y fail2ban
elif [[ -f /etc/redhat-release ]]; then
  if command -v dnf >/dev/null 2>&1; then
    dnf install -y epel-release
    dnf install -y fail2ban
  else
    yum install -y epel-release
    yum install -y fail2ban
  fi
else
  echo "[!] 不支持的系统"
  exit 1
fi

# ========= 创建配置目录 =========
mkdir -p /etc/fail2ban/jail.d

# ========= 自动判断日志来源 =========
LOGPATH=""
USE_SYSTEMD="false"

if [[ -f /var/log/auth.log ]]; then
  LOGPATH="/var/log/auth.log"
elif [[ -f /var/log/secure ]]; then
  LOGPATH="/var/log/secure"
else
  USE_SYSTEMD="true"
fi

echo "[*] 检测日志方式: $([[ $USE_SYSTEMD == true ]] && echo "systemd" || echo "$LOGPATH")"

# ========= 写入配置 =========
if [[ "$USE_SYSTEMD" == "true" ]]; then
  cat > /etc/fail2ban/jail.d/sshd.local <<EOF
[sshd]
enabled = true
port = ssh
backend = systemd
EOF
else
  cat > /etc/fail2ban/jail.d/sshd.local <<EOF
[sshd]
enabled = true
port = ssh
logpath = ${LOGPATH}
EOF
fi

# ========= 全局简单策略 =========
cat > /etc/fail2ban/jail.d/00-simple.local <<EOF
[DEFAULT]
findtime = 10m
maxretry = 5
bantime = 10h
ignoreip = 127.0.0.1/8 ::1
EOF

# ========= 启动 =========
echo "[*] 校验配置..."
if fail2ban-client -t >/dev/null 2>&1; then
  systemctl enable fail2ban
  systemctl restart fail2ban
  echo "[*] 启动成功"
else
  echo "[!] 配置错误，请检查 /etc/fail2ban/jail.d/"
  exit 1
fi

echo
echo "✅ 完成！"
echo
echo "查看状态："
echo "  fail2ban-client status"
echo "  fail2ban-client status sshd"
