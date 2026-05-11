#!/usr/bin/env bash
set -euo pipefail

ts="$(date +%Y%m%d_%H%M%S)"
echo "[*] Fail2Ban STABLE setup @ ${ts}"

if [[ "${EUID}" -ne 0 ]]; then
  echo "[!] 请用 root 运行：sudo bash $0"
  exit 1
fi

# ========= 可调参数（稳定默认）=========
FINDTIME="10m"
MAXRETRY="5"
BANTIME="1h"
# 模式：normal / aggressive（aggressive 更敏感，误封概率更高；稳定起见默认 normal）
SSHD_MODE="normal"

# ========= 获取当前 SSH 客户端 IP（自动白名单，降低误封锁死）=========
CLIENT_IP=""
if [[ -n "${SSH_CONNECTION:-}" ]]; then
  CLIENT_IP="$(awk '{print $1}' <<<"${SSH_CONNECTION}")"
fi

# ========= 安装 fail2ban（并尽量补齐 systemd 依赖）=========
if [[ -f /etc/debian_version ]]; then
  echo "[*] Debian/Ubuntu detected -> apt install"
  apt-get update -y
  # python3-systemd：在 Debian/Ubuntu 上使用 systemd 后端时常需要（不少场景缺它会出问题）
  # 有文章/经验建议 Debian 12 安装 python3-systemd，并在 jail 中指定 backend=systemd [1](https://blog.csdn.net/m0_38072683/article/details/142050201)[3](https://blog.51cto.com/u_13758447/12044448)
  apt-get install -y fail2ban python3-systemd || apt-get install -y fail2ban
elif [[ -f /etc/redhat-release ]]; then
  echo "[*] RHEL/CentOS/Rocky/Alma detected -> dnf/yum install"
  if command -v dnf >/dev/null 2>&1; then
    dnf install -y epel-release || true
    dnf install -y fail2ban
  else
    yum install -y epel-release || true
    yum install -y fail2ban
  fi
else
  echo "[!] Unsupported distro."
  exit 1
fi

# ========= 备份配置（可回滚）=========
mkdir -p /etc/fail2ban/jail.d
backup_dir="/etc/fail2ban/backup_stable_${ts}"
mkdir -p "${backup_dir}"
cp -a /etc/fail2ban/fail2ban.conf "${backup_dir}/" 2>/dev/null || true
cp -a /etc/fail2ban/fail2ban.local "${backup_dir}/" 2>/dev/null || true
cp -a /etc/fail2ban/jail.conf "${backup_dir}/" 2>/dev/null || true
cp -a /etc/fail2ban/jail.local "${backup_dir}/" 2>/dev/null || true
cp -a /etc/fail2ban/jail.d "${backup_dir}/" 2>/dev/null || true
echo "[*] Backup saved to: ${backup_dir}"

# ========= 确保 fail2ban 自身日志文件可用（方便排错）=========
mkdir -p /var/log
touch /var/log/fail2ban.log
chmod 600 /var/log/fail2ban.log || true

# 将 fail2ban 记录到 /var/log/fail2ban.log（recidive/排错都更直观）
cat > /etc/fail2ban/fail2ban.local <<'EOF'
[Definition]
loglevel  = INFO
logtarget = /var/log/fail2ban.log
EOF

# ========= 自动探测 SSH 端口 =========
SSH_PORT="ssh"
if command -v sshd >/dev/null 2>&1; then
  p="$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}' || true)"
  [[ -n "${p:-}" ]] && SSH_PORT="${p}"
fi
echo "[*] SSH port detected: ${SSH_PORT}"

# ========= 自动判断 sshd 该读“文件日志”还是“systemd journal” =========
# 你遇到的错误就是：找不到 /var/log/auth.log 之类文件时，sshd jail 直接失败 [1](https://blog.csdn.net/m0_38072683/article/details/142050201)[2](https://github.com/fail2ban/fail2ban/issues/3567)
# 解决思路：存在文件就用 logpath；否则用 backend=systemd + journalmatch（journald） [8](https://www.cnblogs.com/architectforest/p/18426489)[6](https://wiki.archlinux.org/title/Fail2ban)

LOGPATH=""
if [[ -f /var/log/auth.log ]]; then
  LOGPATH="/var/log/auth.log"
elif [[ -f /var/log/secure ]]; then
  LOGPATH="/var/log/secure"
fi

USE_SYSTEMD_BACKEND="false"
JOURNALMATCH=""

# 如果没找到文件日志，就切到 systemd 后端
if [[ -z "${LOGPATH}" ]]; then
  USE_SYSTEMD_BACKEND="true"
  # 自动识别 ssh 服务 unit：Ubuntu 常见 ssh.service；RHEL 常见 sshd.service
  if systemctl list-units --type=service --all 2>/dev/null | grep -qE '^\s*ssh\.service'; then
    JOURNALMATCH="_SYSTEMD_UNIT=ssh.service + _COMM=sshd"
  else
    JOURNALMATCH="_SYSTEMD_UNIT=sshd.service + _COMM=sshd"
  fi
fi

echo "[*] Log source: $([[ "${USE_SYSTEMD_BACKEND}" == "true" ]] && echo "systemd journal (${JOURNALMATCH})" || echo "file (${LOGPATH})")"

# ========= 写入稳定配置（只写 overrides，不复制整份默认配置）=========
# 不复制整份 jail.conf 到 *.local：维护者明确不推荐，可能导致配置不兼容、缺 include 等问题 [4](https://github.com/fail2ban/fail2ban/blob/master/config/jail.conf)[5](https://mylinux.work/projects/fail2ban-install-script/)

IGNORE_IP="127.0.0.1/8 ::1"
if [[ -n "${CLIENT_IP}" ]]; then
  IGNORE_IP="${IGNORE_IP} ${CLIENT_IP}"
  echo "[*] Whitelisted current SSH client IP: ${CLIENT_IP}"
fi

cat > /etc/fail2ban/jail.d/00-stable.local <<EOF
[DEFAULT]
ignoreip  = ${IGNORE_IP}
findtime  = ${FINDTIME}
maxretry  = ${MAXRETRY}
bantime   = ${BANTIME}
EOF

# sshd jail
if [[ "${USE_SYSTEMD_BACKEND}" == "true" ]]; then
  cat > /etc/fail2ban/jail.d/sshd.local <<EOF
[sshd]
enabled      = true
port         = ${SSH_PORT}
backend      = systemd
journalmatch = ${JOURNALMATCH}
filter       = sshd[mode=${SSHD_MODE}]
EOF
else
  cat > /etc/fail2ban/jail.d/sshd.local <<EOF
[sshd]
enabled  = true
port     = ${SSH_PORT}
logpath  = ${LOGPATH}
backend  = auto
filter   = sshd[mode=${SSHD_MODE}]
EOF
fi

# ========= 配置自检 + 启动 =========
echo "[*] Validating configuration (fail2ban-client -t) ..."
# 启动失败/Socket 不存在时，通常要先 systemctl status fail2ban + fail2ban-client -t 排查 [4](https://github.com/fail2ban/fail2ban/blob/master/config/jail.conf)
if fail2ban-client -t >/dev/null 2>&1; then
  echo "[*] Config OK. Restarting fail2ban..."
  systemctl enable fail2ban >/dev/null 2>&1 || true
  systemctl restart fail2ban
else
  echo "[!] Config test failed. Rolling back..."
  rm -f /etc/fail2ban/jail.d/00-stable.local /etc/fail2ban/jail.d/sshd.local
  [[ -f "${backup_dir}/fail2ban.local" ]] && cp -a "${backup_dir}/fail2ban.local" /etc/fail2ban/fail2ban.local || true
  [[ -d "${backup_dir}/jail.d" ]] && cp -a "${backup_dir}/jail.d/." /etc/fail2ban/jail.d/ || true
  systemctl restart fail2ban || true
  echo "[!] Rolled back. Check logs:"
  echo "    tail -f /var/log/fail2ban.log"
  echo "    journalctl -u fail2ban -n 50 --no-pager"
  exit 1
fi

echo
echo "================= ✅ STABLE 部署完成 ================="
echo "[+] 配置位置：/etc/fail2ban/jail.d/00-stable.local  &  /etc/fail2ban/jail.d/sshd.local"
echo "[+] 说明：若系统没有 /var/log/auth.log，则已自动改用 backend=systemd + journalmatch 修复“找不到日志文件”问题 [1](https://blog.csdn.net/m0_38072683/article/details/142050201)[8](https://www.cnblogs.com/architectforest/p/18426489)"
echo
echo "常用命令："
echo "  查看服务：        systemctl status fail2ban"
echo "  查看 sshd jail：  fail2ban-client status sshd"
echo "  查看日志：        tail -f /var/log/fail2ban.log"
echo "  解封 IP：         fail2ban-client set sshd unbanip <IP>"
echo "======================================================"
