#!/usr/bin/env bash
set -euo pipefail

echo "[*] 安装 Fail2ban（简易稳定版 + APT源自愈）"

# 必须 root
if [[ "${EUID}" -ne 0 ]]; then
  echo "[!] 请用 root/sudo 运行：sudo bash install.sh"
  exit 1
fi

# -----------------------------
# APT 源自愈（只在 Debian/Ubuntu 生效）
# -----------------------------
apt_self_heal() {
  # 没有 apt 就跳过
  command -v apt-get >/dev/null 2>&1 || return 0

  export DEBIAN_FRONTEND=noninteractive
  local ts; ts="$(date +%Y%m%d_%H%M%S)"
  local backup_dir="/root/apt_sources_backup_${ts}"
  mkdir -p "${backup_dir}"

  # 备份 sources
  [[ -f /etc/apt/sources.list ]] && cp -a /etc/apt/sources.list "${backup_dir}/sources.list.bak" || true
  if [[ -d /etc/apt/sources.list.d ]]; then
    cp -a /etc/apt/sources.list.d "${backup_dir}/sources.list.d.bak" || true
  fi

  echo "[*] APT 预检查：清理缓存并更新索引..."
  apt-get clean || true
  rm -rf /var/lib/apt/lists/* || true

  # 第一次 update（失败允许进入修复流程）
  set +e
  local out rc
  out="$(apt-get update 2>&1)"
  rc=$?
  set -e

  if [[ $rc -eq 0 ]]; then
    echo "[*] APT 更新正常"
    return 0
  fi

  echo "[!] APT 更新失败（将尝试自愈）。错误摘要："
  echo "$out" | tail -n 15

  # 1) 先简单重试一次（网络抖动常见）[1](https://www.cnblogs.com/rioka/p/13821598.html)
  echo "[*] APT update 重试一次..."
  set +e
  out="$(apt-get update 2>&1)"
  rc=$?
  set -e
  if [[ $rc -eq 0 ]]; then
    echo "[*] APT 重试后恢复正常"
    return 0
  fi

  # 2) 针对 “no Release file / 404 backports” 自动禁用 backports
  # Debian cloud 镜像的默认 sources.list 可能包含已移除的 bullseye-backports，导致 apt update 失败[2](https://lists.debian.org/debian-cloud/2025/07/msg00037.html)
  if echo "$out" | grep -qiE "no longer has a Release file|does not have a Release file|404"; then
    if echo "$out" | grep -qi "backports"; then
      echo "[*] 检测到 backports 仓库问题，自动注释掉 sources 中的 backports 行..."

      # 注释 /etc/apt/sources.list 中未注释的 backports 行
      if [[ -f /etc/apt/sources.list ]]; then
        sed -ri 's/^[[:space:]]*(deb(-src)?[[:space:]].*backports.*)$/# disabled-by-f2ban \1/g' /etc/apt/sources.list || true
      fi

      # 注释 /etc/apt/sources.list.d 下各文件中的 backports 行
      if [[ -d /etc/apt/sources.list.d ]]; then
        find /etc/apt/sources.list.d -type f -maxdepth 1 -print0 2>/dev/null \
          | xargs -0 -I{} sed -ri 's/^[[:space:]]*(deb(-src)?[[:space:]].*backports.*)$/# disabled-by-f2ban \1/g' {} || true
      fi

      echo "[*] 再次更新 APT 索引..."
      set +e
      out="$(apt-get update 2>&1)"
      rc=$?
      set -e
      if [[ $rc -eq 0 ]]; then
        echo "[*] 禁用 backports 后 APT 已恢复"
        return 0
      fi
    fi
  fi

  # 3) 兜底：重建官方基础源（不含 backports），确保脚本继续
  echo "[!] APT 仍失败，启用兜底：重建基础 sources.list（不含 backports）"

  # 读取发行版信息
  local id codename
  id="$(. /etc/os-release && echo "${ID:-}")"
  codename="$(. /etc/os-release && echo "${VERSION_CODENAME:-}")"

  if [[ "$id" == "debian" && -n "$codename" ]]; then
    cat > /etc/apt/sources.list <<EOF
deb http://deb.debian.org/debian ${codename} main contrib non-free
deb http://deb.debian.org/debian ${codename}-updates main contrib non-free
deb http://security.debian.org/debian-security ${codename}-security main contrib non-free
EOF
  elif [[ "$id" == "ubuntu" && -n "$codename" ]]; then
    cat > /etc/apt/sources.list <<EOF
deb http://archive.ubuntu.com/ubuntu ${codename} main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu ${codename}-updates main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu ${codename}-security main restricted universe multiverse
EOF
  fi

  # 清理并再试
  apt-get clean || true
  rm -rf /var/lib/apt/lists/* || true

  set +e
  out="$(apt-get update 2>&1)"
  rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    echo "[!] 兜底 sources.list 后 apt 仍失败。请检查网络/DNS 或第三方源。"
    echo "[!] 你可以先手动执行：apt-get update"
    echo "$out" | tail -n 30
    exit 1
  fi

  echo "[*] APT 兜底修复成功（备份在：${backup_dir}）"
}

# -----------------------------
# 安装逻辑
# -----------------------------
if [[ -f /etc/debian_version ]]; then
  apt_self_heal
  # Debian/Ubuntu
  apt-get install -y fail2ban python3-systemd 2>/dev/null || apt-get install -y fail2ban
elif [[ -f /etc/redhat-release ]]; then
  # RHEL/CentOS/Rocky/Alma
  if command -v dnf >/dev/null 2>&1; then
    dnf install -y epel-release || true
    dnf install -y fail2ban
  else
    yum install -y epel-release || true
    yum install -y fail2ban
  fi
else
  echo "[!] 不支持的系统"
  exit 1
fi

mkdir -p /etc/fail2ban/jail.d

# 自动判断日志来源（文件 vs systemd）
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

# 写入基础策略
cat > /etc/fail2ban/jail.d/00-simple.local <<EOF
[DEFAULT]
findtime = 10m
maxretry = 5
bantime = 1h
ignoreip = 127.0.0.1/8 ::1
EOF

# 写入 sshd jail（避免 “Have not found any log file for sshd jail”）
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

echo "[*] 校验配置..."
if fail2ban-client -t >/dev/null 2>&1; then
  systemctl enable fail2ban >/dev/null 2>&1 || true
  systemctl restart fail2ban
  echo "✅ 完成！"
  echo "查看状态：fail2ban-client status sshd"
else
  echo "[!] fail2ban 配置错误，请检查 /etc/fail2ban/jail.d/"
  exit 1
fi
