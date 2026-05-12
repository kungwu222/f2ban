#!/usr/bin/env bash
set -euo pipefail

echo "[*] 安装 Fail2ban（按需修复APT版）"

# 必须 root
if [[ "$EUID" -ne 0 ]]; then
  echo "[!] 请用 root/sudo 运行"
  exit 1
fi

# ==============================
# 1️⃣ 先尝试更新（允许失败）
# ==============================
echo "[*] 更新APT（容错模式）"
apt-get update || echo "[!] apt update 有错误，已忽略"

# ==============================
# 2️⃣ 尝试安装 fail2ban
# ==============================
echo "[*] 安装 fail2ban..."
if ! apt-get install -y fail2ban >/dev/null 2>&1; then
  echo "[!] 安装失败，开始修复APT源..."

  # ==============================
  # 3️⃣ 按需修复APT（只在失败时执行）
  # ==============================

  echo "[*] 修复：移除backports源"
  sed -i '/backports/d' /etc/apt/sources.list || true
  rm -f /etc/apt/sources.list.d/*backports* 2>/dev/null || true

  echo "[*] 清理缓存"
  apt-get clean
  rm -rf /var/lib/apt/lists/*

  echo "[*] 重新更新APT"
  apt-get update || true

  echo "[*] 重试安装 fail2ban..."
  if ! apt-get install -y fail2ban; then
    echo "[!] 仍然失败，使用兜底源"

    # ==============================
    # 4️⃣ 最后兜底（重建官方源）
    # ==============================

    . /etc/os-release

    if [[ "$ID" == "debian" ]]; then
      cat > /etc/apt/sources.list <<EOF
deb http://deb.debian.org/debian $VERSION_CODENAME main contrib non-free
deb http://deb.debian.org/debian $VERSION_CODENAME-updates main contrib non-free
deb http://security.debian.org/debian-security $VERSION_CODENAME-security main contrib non-free
EOF
    elif [[ "$ID" == "ubuntu" ]]; then
      cat > /etc/apt/sources.list <<EOF
deb http://archive.ubuntu.com/ubuntu $VERSION_CODENAME main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu $VERSION_CODENAME-updates main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu $VERSION_CODENAME-security main restricted universe multiverse
EOF
    fi

    apt-get clean
    rm -rf /var/lib/apt/lists/*
    apt-get update

    apt-get install -y fail2ban
  fi
fi

# ==============================
# 5️⃣ 配置 fail2ban
# ==============================
mkdir -p /etc/fail2ban/jail.d

cat > /etc/fail2ban/jail.d/sshd.local <<EOF
[sshd]
enabled = true
port = ssh
EOF

echo "[*] 启动 fail2ban..."
systemctl enable fail2ban >/dev/null 2>&1 || true
systemctl restart fail2ban

echo "✅ 安装完成！"
echo "查看状态：fail2ban-client status sshd"
