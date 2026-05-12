#!/usr/bin/env bash
set -euo pipefail

echo "[*] 安装 Fail2ban（按需修复APT + 高级防爆破）"

# 必须 root
if [[ "${EUID}" -ne 0 ]]; then
  echo "[!] 请用 root/sudo 运行"
  exit 1
fi

# ==============================
# 可调参数（高级防爆破策略）
# ==============================
FINDTIME="10m"         # 统计窗口
MAXRETRY="3"           # 失败次数阈值（比简易版更严格）
BANTIME="1h"           # 首次封禁时长
SSHD_MODE="aggressive" # normal / aggressive（更敏感）

# 递增封禁（repeat offender）
INCR_ENABLE="true"
INCR_FACTOR="24"       # 常见做法：让封禁更快升级（例：1h -> 1d -> 2d -> 4d...）[3](https://github.com/fail2ban/fail2ban/discussions/3700)
INCR_MAXTIME="5w"      # 最长封禁上限（可调）[3](https://github.com/fail2ban/fail2ban/discussions/3700)[2](https://deepwiki.com/fail2ban/fail2ban/7.1-ban-time-increment-system)
INCR_RNDTIME="10m"     # 随机扰动，防止对方卡点[1](https://visei.com/2020/05/incremental-banning-with-fail2ban/)[2](https://deepwiki.com/fail2ban/fail2ban/7.1-ban-time-increment-system)

# recidive（惯犯：多次被 ban -> 更长封）
RECIDIVE_ENABLE="true"
RECIDIVE_FINDTIME="1d"
RECIDIVE_MAXRETRY="5"
RECIDIVE_BANTIME="7d"  # 惯犯封 7 天（可改更狠/更保守）[6](https://blog.exsvc.cn/article/fail2ban-block-recidive.html)

# 自动白名单当前 SSH 客户端 IP（降低误封把自己锁死）
CLIENT_IP=""
if [[ -n "${SSH_CONNECTION:-}" ]]; then
  CLIENT_IP="$(awk '{print $1}' <<<"${SSH_CONNECTION}")"
fi

# ==============================
# 1️⃣ APT update（允许失败）+ 按需修复（仅当安装失败才修）
# ==============================
apt_try_update() {
  command -v apt-get >/dev/null 2>&1 || return 0
  echo "[*] APT update（容错模式）"
  apt-get update || echo "[!] apt update 有错误，已忽略（先尝试继续安装）"
}

apt_fix_sources_on_demand() {
  # 只在“安装失败”时才调用：尽量快
  echo "[!] 触发按需修复APT源（仅此时才修）"
  # 常见坑：backports 404 / no Release file，直接禁用 backports
  sed -ri 's/^[[:space:]]*(deb(-src)?[[:space:]].*backports.*)$/# disabled-by-f2ban \1/g' /etc/apt/sources.list 2>/dev/null || true
  if [[ -d /etc/apt/sources.list.d ]]; then
    find /etc/apt/sources.list.d -type f -maxdepth 1 -print0 2>/dev/null \
      | xargs -0 -I{} sed -ri 's/^[[:space:]]*(deb(-src)?[[:space:]].*backports.*)$/# disabled-by-f2ban \1/g' {} || true
  fi
  apt-get clean || true
  rm -rf /var/lib/apt/lists/* || true

  # 重试一次 update（必要时才做）
  apt-get update || true
}

# ==============================
# 2️⃣ 安装 fail2ban（Debian/Ubuntu & RHEL系）
# ==============================
install_fail2ban() {
  if [[ -f /etc/debian_version ]]; then
    apt_try_update

    echo "[*] 安装 fail2ban..."
    if ! apt-get install -y fail2ban python3-systemd >/dev/null 2>&1; then
      echo "[!] 安装失败，开始按需修复APT后重试"
      apt_fix_sources_on_demand
      apt-get install -y fail2ban python3-systemd 2>/dev/null || apt-get install -y fail2ban
    fi

  elif [[ -f /etc/redhat-release ]]; then
    echo "[*] RHEL/CentOS/Rocky/Alma 检测到，使用 dnf/yum 安装"
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
}

install_fail2ban

# ==============================
# 3️⃣ 生成高级防爆破配置
# ==============================
mkdir -p /etc/fail2ban/jail.d

# fail2ban.log：recidive 需要它来判断“反复被 ban 的人”[6](https://blog.exsvc.cn/article/fail2ban-block-recidive.html)
touch /var/log/fail2ban.log
chmod 600 /var/log/fail2ban.log || true

# 确保 fail2ban 写日志到 /var/log/fail2ban.log（便于排错 + recidive）
cat > /etc/fail2ban/fail2ban.local <<'EOF'
[Definition]
loglevel  = INFO
logtarget = /var/log/fail2ban.log
EOF

# 自动探测 SSH 端口（如果 sshd 可用）
SSH_PORT="ssh"
if command -v sshd >/dev/null 2>&1; then
  p="$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}' || true)"
  [[ -n "${p:-}" ]] && SSH_PORT="${p}"
fi

# 自动判断：文件日志 vs systemd journal
LOGPATH=""
USE_SYSTEMD="false"

if [[ -f /var/log/auth.log ]]; then
  LOGPATH="/var/log/auth.log"
elif [[ -f /var/log/secure ]]; then
  LOGPATH="/var/log/secure"
else
  USE_SYSTEMD="true"
fi

# systemd 的 journalmatch：Ubuntu 常见 ssh.service；RHEL 常见 sshd.service
JOURNALMATCH="_SYSTEMD_UNIT=sshd.service + _COMM=sshd"
if command -v systemctl >/dev/null 2>&1; then
  if systemctl list-units --type=service --all 2>/dev/null | grep -qE '^\s*ssh\.service'; then
    JOURNALMATCH="_SYSTEMD_UNIT=ssh.service + _COMM=sshd"
  fi
fi

# ignoreip：回环 + 当前 SSH 来源（可选）
IGNORE_IP="127.0.0.1/8 ::1"
if [[ -n "${CLIENT_IP}" ]]; then
  IGNORE_IP="${IGNORE_IP} ${CLIENT_IP}"
  echo "[*] 已自动将当前 SSH 客户端 IP 加入白名单：${CLIENT_IP}"
fi

# 全局默认（递增封禁）[1](https://visei.com/2020/05/incremental-banning-with-fail2ban/)[2](https://deepwiki.com/fail2ban/fail2ban/7.1-ban-time-increment-system)[3](https://github.com/fail2ban/fail2ban/discussions/3700)
cat > /etc/fail2ban/jail.d/00-advanced.local <<EOF
[DEFAULT]
ignoreip = ${IGNORE_IP}

findtime = ${FINDTIME}
maxretry = ${MAXRETRY}
bantime  = ${BANTIME}

bantime.increment = ${INCR_ENABLE}
bantime.factor    = ${INCR_FACTOR}
bantime.maxtime   = ${INCR_MAXTIME}
bantime.rndtime   = ${INCR_RNDTIME}
EOF

# sshd jail（aggressive 模式 + backend 自适配）[3](https://github.com/fail2ban/fail2ban/discussions/3700)[4](https://github.com/fail2ban/fail2ban/blob/master/config/filter.d/sshd.conf)[7](https://www.cnblogs.com/architectforest/p/18426489)[5](https://resona.top/2025/03/03/%E4%BD%BF%E7%94%A8fail2ban%E9%98%B2%E8%8C%83ssh%E7%88%86%E7%A0%B4/)
if [[ "${USE_SYSTEMD}" == "true" ]]; then
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
enabled = true
port    = ${SSH_PORT}
logpath = ${LOGPATH}
filter  = sshd[mode=${SSHD_MODE}]
EOF
fi

# recidive（惯犯更长封）[6](https://blog.exsvc.cn/article/fail2ban-block-recidive.html)
if [[ "${RECIDIVE_ENABLE}" == "true" ]]; then
  cat > /etc/fail2ban/jail.d/recidive.local <<EOF
[recidive]
enabled  = true
logpath  = /var/log/fail2ban.log
bantime  = ${RECIDIVE_BANTIME}
findtime = ${RECIDIVE_FINDTIME}
maxretry = ${RECIDIVE_MAXRETRY}
EOF
fi

# ==============================
# 4️⃣ 校验 + 启动 + 开机自启
# ==============================
echo "[*] 校验 fail2ban 配置..."
if fail2ban-client -t >/dev/null 2>&1; then
  echo "[*] 配置OK，启动并设置开机自启"
  systemctl enable --now fail2ban >/dev/null 2>&1 || true
  systemctl restart fail2ban
else
  echo "[!] 配置校验失败：请检查 /etc/fail2ban/jail.d/"
  echo "    建议先把 SSH 模式改成 normal：SSHD_MODE=\"normal\"（旧版本 aggressive+systemd 可能异常）" # [10](https://blog.gitcode.com/f3d3de7d860bb6d500b62323b4b9bf10.html)
  exit 1
fi

echo
echo "✅ 完成！常用查看命令："
echo "  fail2ban-client status"
echo "  fail2ban-client status sshd"
if [[ "${RECIDIVE_ENABLE}" == "true" ]]; then
  echo "  fail2ban-client status recidive"
fi
echo "  tail -f /var/log/fail2ban.log"
