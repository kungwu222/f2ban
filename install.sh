#!/bin/bash

# ========================
# Fail2Ban 一键安装脚本（SSH防护）
# ========================

echo "===> 开始安装 Fail2Ban..."

# 判断系统类型
if [ -f /etc/debian_version ]; then
    echo "检测到 Debian/Ubuntu"
    apt update -y
    apt install -y fail2ban
    LOGPATH="/var/log/auth.log"
elif [ -f /etc/redhat-release ]; then
    echo "检测到 CentOS/RHEL"
    yum install -y epel-release
    yum install -y fail2ban
    LOGPATH="/var/log/secure"
else
    echo "不支持的系统"
    exit 1
fi

# 备份旧配置
[ -f /etc/fail2ban/jail.local ] && cp /etc/fail2ban/jail.local /etc/fail2ban/jail.local.bak

echo "===> 生成配置文件..."

cat > /etc/fail2ban/jail.local <<EOF

[DEFAULT]
ignoreip = 127.0.0.1/8 ::1
bantime = 24h
findtime = 10m
maxretry = 5

[sshd]
enabled = true
port    = ssh
logpath = $LOGPATH
backend = auto
filter  = sshd
EOF

echo "===> 启动 fail2ban..."

systemctl enable fail2ban
systemctl restart fail2ban

echo "===> 安装完成 ✅"

echo "查看状态："
echo "fail2ban-client status sshd"
