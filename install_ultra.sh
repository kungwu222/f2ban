#!/usr/bin/env bash
set -euo pipefail

ts="$(date +%Y%m%d_%H%M%S)"
echo "[*] Fail2ban ULTRA setup @ $ts"

if [[ "${EUID}" -ne 0 ]]; then
  echo "[!] 请用 root 运行：sudo bash $0"
  exit 1
fi

# 获取当前 SSH 客户端 IP（自动白名单，降低误封锁死概率）
CLIENT_IP=""
if [[ -n "${SSH_CONNECTION:-}" ]]; then
  CLIENT_IP="$(awk '{print $1}' <<<"${SSH_CONNECTION}")"
fi

# -------------------------
# 1) 安装 fail2ban
# -------------------------
if [[ -f /etc/debian_version ]]; then
  echo "[*] Debian/Ubuntu: apt 安装"
  apt-get update -y
  apt-get install -y fail2ban
elif [[ -f /etc/redhat-release ]]; then
  echo "[*] RHEL/CentOS/Rocky/Alma: dnf/yum 安装"
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

# -------------------------
# 2) 备份现有配置
# -------------------------
mkdir -p /etc/fail2ban/jail.d
backup_dir="/etc/fail2ban/backup_ultra_${ts}"
mkdir -p "${backup_dir}"
cp -a /etc/fail2ban/fail2ban.conf "${backup_dir}/" 2>/dev/null || true
cp -a /etc/fail2ban/fail2ban.local "${backup_dir}/" 2>/dev/null || true
cp -a /etc/fail2ban/jail.conf "${backup_dir}/" 2>/dev/null || true
cp -a /etc/fail2ban/jail.local "${backup_dir}/" 2>/dev/null || true
cp -a /etc/fail2ban/jail.d "${backup_dir}/" 2>/dev/null || true
echo "[*] 备份完成：${backup_dir}"

# -------------------------
# 3) 选择 banaction（firewalld / nftables / iptables）
# -------------------------
BANACTION="iptables-multiport"
BANACTION_ALLPORTS="iptables-allports"

if systemctl is-active --quiet firewalld 2>/dev/null; then
  # firewalld 场景：ipset 方式封禁更常见（需要 firewalld 运行）
  BANACTION="firewallcmd-ipset"
  BANACTION_ALLPORTS="firewallcmd-allports"
elif command -v nft >/dev/null 2>&1; then
  # nftables 场景：用 nftables-* actions（万级封禁更适合用集合 set）
  BANACTION="nftables-multiport"
  BANACTION_ALLPORTS="nftables-allports"
fi

echo "[*] banaction=${BANACTION} , banaction_allports=${BANACTION_ALLPORTS}"

# -------------------------
# 4) 确保 fail2ban 记录到 /var/log/fail2ban.log（recidive 需要它）
#    并把 dbpurgeage 拉长（否则历史 ban 可能很快清掉，recidive/增量不够“记仇”）
# -------------------------
mkdir -p /var/log
touch /var/log/fail2ban.log
chmod 600 /var/log/fail2ban.log || true

cat > /etc/fail2ban/fail2ban.local <<EOF
[Definition]
loglevel = INFO
logtarget = /var/log/fail2ban.log
# 让数据库记录保留更久，便于 recidive/增量封禁利用历史（可按需改更大）
dbpurgeage = 30d
EOF

# -------------------------
# 5) 自动探测 SSH 端口（优先 sshd -T）
# -------------------------
SSH_PORT="ssh"
if command -v sshd >/dev/null 2>&1; then
  p="$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}' || true)"
  [[ -n "${p:-}" ]] && SSH_PORT="${p}"
fi
echo "[*] 检测 SSH 端口：${SSH_PORT}"

# -------------------------
# 6) ULTRA 规则写入 jail.d（不改 jail.conf）
# -------------------------
IGNORE_IP="127.0.0.1/8 ::1"
if [[ -n "${CLIENT_IP}" ]]; then
  IGNORE_IP="${IGNORE_IP} ${CLIENT_IP}"
  echo "[*] 自动白名单当前 SSH 来源 IP：${CLIENT_IP}"
fi

# 6.1 全局超强默认：2 次失败就封；阶梯惩罚；随机扰动
# bantime.increment / rndtime / maxtime 等参数见官方/源码说明与示例
cat > /etc/fail2ban/jail.d/00-ultra.local <<EOF
[DEFAULT]
ignoreip = ${IGNORE_IP}

# 超强阈值：10分钟窗口内失败 2 次就封
findtime = 10m
maxretry = 2

# 首次封禁 24 小时
bantime = 24h

# 阶梯式封禁：再次违规会加倍/指数增长（依赖 Fail2BanDb 记录）
bantime.increment = true
# 常用做法：factor 24 让“小时级”快速升级到“天级”（示例中 1h->1d->2d...）
bantime.factor = 24
# 上限 20 周（也可更小，比如 5w）
bantime.maxtime = 20w
# 加一点随机扰动，避免对方精确卡点（示例常见 10m）
bantime.rndtime = 10m

# 防火墙动作
banaction = ${BANACTION}
banaction_allports = ${BANACTION_ALLPORTS}
EOF

# 6.2 SSHD：aggressive 模式（抓更多类型 SSH 非法尝试）
cat > /etc/fail2ban/jail.d/sshd.local <<EOF
[sshd]
enabled = true
port = ${SSH_PORT}
filter = sshd[mode=aggressive]
EOF

# 6.3 惯犯 recidive：同一 IP 多次被 ban -> 直接永久封（bantime=-1）
# 典型写法：监控 /var/log/fail2ban.log，达到阈值永久封
cat > /etc/fail2ban/jail.d/recidive.local <<'EOF'
[recidive]
enabled = true
logpath = /var/log/fail2ban.log
banaction = %(banaction_allports)s
# 永久封禁（谨慎：会越积越多）
bantime = -1
findtime = 1d
maxretry = 6
EOF

# -------------------------
# 7) 配置自检 + 重启（失败自动回滚）
# -------------------------
echo "[*] 配置校验中..."
if fail2ban-client -t >/dev/null 2>&1; then
  echo "[*] 校验通过，重启 fail2ban"
  systemctl enable fail2ban >/dev/null 2>&1 || true
  systemctl restart fail2ban
else
  echo "[!] fail2ban 配置校验失败，开始回滚..."
  rm -f /etc/fail2ban/jail.d/00-ultra.local /etc/fail2ban/jail.d/sshd.local /etc/fail2ban/jail.d/recidive.local
  [[ -f "${backup_dir}/fail2ban.local" ]] && cp -a "${backup_dir}/fail2ban.local" /etc/fail2ban/fail2ban.local || true
  [[ -d "${backup_dir}/jail.d" ]] && cp -a "${backup_dir}/jail.d/." /etc/fail2ban/jail.d/ || true
  systemctl restart fail2ban || true
  echo "[!] 已回滚。请查看：/var/log/fail2ban.log 或 journalctl -u fail2ban -f"
  exit 1
fi

echo
echo "================= ✅ ULTRA 完成 ================="
echo "[+] SSHD aggressive 已启用（sshd[mode=aggressive]）"
echo "[+] 阈值：10分钟内失败2次 -> 首次封24h -> 递增加重（最高20w）"
echo "[+] recidive：1天内累计6次被 ban -> 永久封 (bantime=-1)"
echo
echo "常用命令："
echo "  查看 sshd：      fail2ban-client status sshd"
echo "  查看 recidive：  fail2ban-client status recidive"
echo "  看日志：         tail -f /var/log/fail2ban.log"
echo "  解封某IP：       fail2ban-client set sshd unbanip <IP>"
echo "=================================================="
