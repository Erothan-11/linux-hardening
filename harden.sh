#!/bin/bash
# Copyright (c) 2025-2026 Fran Rudes (@Erothan-11)
# SPDX-License-Identifier: GPL-3.0-or-later
#====================================================================
# Linux Hardening Script
# Author: Fran Rudes (@Erothan-11)
# Description: Automated Linux hardening based on CIS benchmarks.
#              Configures SSH, firewall, kernel params, auditing,
#              file permissions, fail2ban and more.
# Usage: sudo ./harden.sh [--dry-run] [--modules MOD1,MOD2]
#
# WARNING: This script MODIFIES system configuration.
#          Always test in a non-production environment first.
#          Use --dry-run to preview changes without applying them.
#====================================================================

set -uo pipefail

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# --- Config ---
DRY_RUN=false
BACKUP_DIR="/root/hardening_backup_$(date +%Y%m%d_%H%M%S)"
CHANGES=0
SKIPPED=0
LOG_FILE="/var/log/hardening_$(date +%Y%m%d_%H%M%S).log"
MODULES="all"

# --- Parse args ---
while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)   DRY_RUN=true; shift ;;
        --modules)   MODULES="$2"; shift 2 ;;
        --modules=*) MODULES="${1#*=}"; shift ;;
        -h|--help)
            echo "Usage: sudo $0 [--dry-run] [--modules ssh,firewall,kernel,audit,permissions,services,fail2ban,network,auth]"
            echo ""
            echo "  --dry-run     Preview changes without applying them"
            echo "  --modules     Comma-separated list of modules to run (default: all)"
            echo ""
            echo "Modules: ssh, firewall, kernel, audit, permissions, services, fail2ban, network, auth"
            exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# Check root
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[!] This script must be run as root${NC}"
    exit 1
fi

# --- Detect distro ---
detect_distro() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        DISTRO_FAMILY=""
        case "$ID" in
            debian|ubuntu|kali|mint) DISTRO_FAMILY="debian" ;;
            rhel|centos|rocky|alma|fedora|ol) DISTRO_FAMILY="rhel" ;;
            *) DISTRO_FAMILY="unknown" ;;
        esac
    else
        DISTRO_FAMILY="unknown"
    fi
}

detect_distro

# --- Helpers ---
header() {
    local msg="$1"
    echo "" | tee -a "$LOG_FILE"
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}" | tee -a "$LOG_FILE"
    echo -e "${CYAN}║${NC} ${BOLD}$msg${NC}" | tee -a "$LOG_FILE"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}" | tee -a "$LOG_FILE"
}

ok()      { echo -e "  ${GREEN}[OK]${NC} $1" | tee -a "$LOG_FILE"; }
changed() { echo -e "  ${GREEN}[CHANGED]${NC} $1" | tee -a "$LOG_FILE"; ((CHANGES++)); }
skip()    { echo -e "  ${YELLOW}[SKIP]${NC} $1" | tee -a "$LOG_FILE"; ((SKIPPED++)); }
info()    { echo -e "  ${CYAN}[INFO]${NC} $1" | tee -a "$LOG_FILE"; }
warn()    { echo -e "  ${YELLOW}[WARN]${NC} $1" | tee -a "$LOG_FILE"; }
dry()     { echo -e "  ${YELLOW}[DRY-RUN]${NC} Would: $1" | tee -a "$LOG_FILE"; }

# Backup a file before modifying
backup() {
    local file="$1"
    if [[ -f "$file" ]]; then
        local dest="${BACKUP_DIR}${file}"
        mkdir -p "$(dirname "$dest")"
        cp -p "$file" "$dest" 2>/dev/null
    fi
}

# Set a config value in a file (key value format)
set_config() {
    local file="$1"
    local key="$2"
    local value="$3"
    local current

    if [[ ! -f "$file" ]]; then
        skip "$file does not exist"
        return
    fi

    current=$(grep -E "^\s*${key}\s+" "$file" 2>/dev/null | tail -1 | awk '{print $2}')

    if [[ "$current" == "$value" ]]; then
        ok "$key already set to $value"
        return
    fi

    if $DRY_RUN; then
        dry "Set $key $value in $file (current: ${current:-not set})"
        return
    fi

    backup "$file"

    if grep -qE "^\s*#?\s*${key}\s+" "$file" 2>/dev/null; then
        sed -i "s|^\s*#\?\s*${key}\s.*|${key} ${value}|" "$file"
    else
        echo "${key} ${value}" >> "$file"
    fi
    changed "$key -> $value"
}

# Set sysctl parameter
set_sysctl() {
    local param="$1"
    local value="$2"
    local desc="$3"
    local current

    current=$(sysctl -n "$param" 2>/dev/null)

    if [[ "$current" == "$value" ]]; then
        ok "$desc: already $value"
        return
    fi

    if $DRY_RUN; then
        dry "$desc: $current -> $value"
        return
    fi

    sysctl -w "${param}=${value}" &>/dev/null
    # Persist
    if grep -q "^${param}" /etc/sysctl.d/99-hardening.conf 2>/dev/null; then
        sed -i "s|^${param}.*|${param} = ${value}|" /etc/sysctl.d/99-hardening.conf
    else
        echo "${param} = ${value}" >> /etc/sysctl.d/99-hardening.conf
    fi
    changed "$desc: $current -> $value"
}

# Check if module should run
should_run() {
    local mod="$1"
    [[ "$MODULES" == "all" ]] || echo ",$MODULES," | grep -q ",$mod,"
}

# ===================================================================
# START
# ===================================================================
echo "" | tee "$LOG_FILE"
echo -e "${BOLD}========================================${NC}" | tee -a "$LOG_FILE"
echo -e "${BOLD}  LINUX HARDENING SCRIPT${NC}" | tee -a "$LOG_FILE"
echo -e "${BOLD}  $(date '+%Y-%m-%d %H:%M:%S')${NC}" | tee -a "$LOG_FILE"
if $DRY_RUN; then
echo -e "${BOLD}  ${YELLOW}DRY-RUN MODE${NC}" | tee -a "$LOG_FILE"
fi
echo -e "${BOLD}========================================${NC}" | tee -a "$LOG_FILE"

info "Distro: ${DISTRO_FAMILY} (${PRETTY_NAME:-unknown})"
info "Backup dir: $BACKUP_DIR"
info "Log: $LOG_FILE"

mkdir -p "$BACKUP_DIR"
touch /etc/sysctl.d/99-hardening.conf 2>/dev/null

# ===================================================================
# MODULE: SSH HARDENING
# ===================================================================
if should_run "ssh"; then
header "SSH HARDENING"

SSHD="/etc/ssh/sshd_config"
if [[ -f "$SSHD" ]]; then
    set_config "$SSHD" "PermitRootLogin" "no"
    set_config "$SSHD" "PasswordAuthentication" "no"
    set_config "$SSHD" "PermitEmptyPasswords" "no"
    set_config "$SSHD" "X11Forwarding" "no"
    set_config "$SSHD" "MaxAuthTries" "3"
    set_config "$SSHD" "ClientAliveInterval" "300"
    set_config "$SSHD" "ClientAliveCountMax" "2"
    set_config "$SSHD" "LoginGraceTime" "60"
    set_config "$SSHD" "AllowAgentForwarding" "no"
    set_config "$SSHD" "AllowTcpForwarding" "no"
    set_config "$SSHD" "TCPKeepAlive" "no"
    set_config "$SSHD" "Compression" "no"
    set_config "$SSHD" "LogLevel" "VERBOSE"
    set_config "$SSHD" "MaxSessions" "2"
    set_config "$SSHD" "UseDNS" "no"

    # Banner
    if ! $DRY_RUN; then
        if [[ ! -f /etc/ssh/banner ]]; then
            cat > /etc/ssh/banner << 'BANNER'
*******************************************************************
*  WARNING: Unauthorized access to this system is prohibited.     *
*  All connections are monitored and recorded.                    *
*  Disconnect IMMEDIATELY if you are not an authorized user.      *
*******************************************************************
BANNER
            changed "Created SSH banner"
        fi
        set_config "$SSHD" "Banner" "/etc/ssh/banner"
    else
        dry "Create SSH banner at /etc/ssh/banner"
    fi

    # Restart SSH
    if ! $DRY_RUN && [[ $CHANGES -gt 0 ]]; then
        info "Restarting sshd..."
        systemctl restart sshd 2>/dev/null || service ssh restart 2>/dev/null
    fi
else
    skip "sshd_config not found"
fi
fi

# ===================================================================
# MODULE: FIREWALL
# ===================================================================
if should_run "firewall"; then
header "FIREWALL HARDENING"

if command -v ufw &>/dev/null; then
    info "Configuring UFW..."
    if $DRY_RUN; then
        dry "Enable UFW with default deny incoming, allow outgoing"
        dry "Allow SSH (port 22)"
    else
        ufw default deny incoming 2>/dev/null
        ufw default allow outgoing 2>/dev/null
        ufw allow ssh 2>/dev/null
        echo "y" | ufw enable 2>/dev/null
        changed "UFW enabled: deny incoming, allow outgoing, allow SSH"
    fi

elif command -v firewall-cmd &>/dev/null; then
    info "Configuring firewalld..."
    if $DRY_RUN; then
        dry "Enable firewalld, set default zone to drop, allow SSH"
    else
        systemctl enable --now firewalld 2>/dev/null
        firewall-cmd --set-default-zone=drop 2>/dev/null
        firewall-cmd --permanent --add-service=ssh 2>/dev/null
        firewall-cmd --reload 2>/dev/null
        changed "firewalld enabled: default zone drop, SSH allowed"
    fi

else
    # Fallback to iptables
    info "Configuring iptables..."
    if $DRY_RUN; then
        dry "Set iptables: accept established, allow SSH, drop rest"
    else
        backup /etc/iptables.rules
        # Flush
        iptables -F
        iptables -X
        # Default policies
        iptables -P INPUT DROP
        iptables -P FORWARD DROP
        iptables -P OUTPUT ACCEPT
        # Allow loopback
        iptables -A INPUT -i lo -j ACCEPT
        # Allow established
        iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
        # Allow SSH
        iptables -A INPUT -p tcp --dport 22 -m state --state NEW -j ACCEPT
        # Log dropped
        iptables -A INPUT -j LOG --log-prefix "IPTABLES-DROP: " --log-level 4
        # Save
        if command -v iptables-save &>/dev/null; then
            iptables-save > /etc/iptables.rules 2>/dev/null
        fi
        changed "iptables configured: DROP input, allow SSH + established"
    fi
fi
fi

# ===================================================================
# MODULE: KERNEL PARAMETERS
# ===================================================================
if should_run "kernel"; then
header "KERNEL HARDENING (sysctl)"

# Network hardening
set_sysctl "net.ipv4.ip_forward" "0" "Disable IP forwarding"
set_sysctl "net.ipv4.conf.all.send_redirects" "0" "Disable send redirects"
set_sysctl "net.ipv4.conf.default.send_redirects" "0" "Disable default send redirects"
set_sysctl "net.ipv4.conf.all.accept_redirects" "0" "Disable accept redirects"
set_sysctl "net.ipv4.conf.default.accept_redirects" "0" "Disable default accept redirects"
set_sysctl "net.ipv6.conf.all.accept_redirects" "0" "Disable IPv6 accept redirects"
set_sysctl "net.ipv4.conf.all.accept_source_route" "0" "Disable source routing"
set_sysctl "net.ipv4.conf.default.accept_source_route" "0" "Disable default source routing"
set_sysctl "net.ipv4.conf.all.log_martians" "1" "Log martian packets"
set_sysctl "net.ipv4.conf.default.log_martians" "1" "Log default martians"
set_sysctl "net.ipv4.icmp_echo_ignore_broadcasts" "1" "Ignore ICMP broadcasts"
set_sysctl "net.ipv4.icmp_ignore_bogus_error_responses" "1" "Ignore bogus ICMP errors"
set_sysctl "net.ipv4.tcp_syncookies" "1" "Enable TCP SYN cookies"
set_sysctl "net.ipv4.conf.all.rp_filter" "1" "Enable reverse path filtering"
set_sysctl "net.ipv4.conf.default.rp_filter" "1" "Enable default reverse path filtering"

# Kernel hardening
set_sysctl "kernel.randomize_va_space" "2" "Enable full ASLR"
set_sysctl "kernel.sysrq" "0" "Disable SysRq key"
set_sysctl "kernel.core_uses_pid" "1" "Core dumps use PID"
set_sysctl "fs.suid_dumpable" "0" "Disable SUID core dumps"
set_sysctl "kernel.dmesg_restrict" "1" "Restrict dmesg"
set_sysctl "kernel.kptr_restrict" "2" "Restrict kernel pointers"
set_sysctl "kernel.yama.ptrace_scope" "1" "Restrict ptrace"
set_sysctl "net.ipv4.tcp_timestamps" "0" "Disable TCP timestamps"

if ! $DRY_RUN; then
    sysctl -p /etc/sysctl.d/99-hardening.conf &>/dev/null
fi
fi

# ===================================================================
# MODULE: AUDIT SYSTEM
# ===================================================================
if should_run "audit"; then
header "AUDIT SYSTEM"

# Install auditd if not present
if ! command -v auditctl &>/dev/null; then
    if $DRY_RUN; then
        dry "Install auditd"
    else
        info "Installing auditd..."
        case "$DISTRO_FAMILY" in
            debian) apt-get install -y auditd audispd-plugins &>/dev/null ;;
            rhel)   dnf install -y audit audit-libs &>/dev/null || yum install -y audit audit-libs &>/dev/null ;;
        esac
        changed "Installed auditd"
    fi
fi

if command -v auditctl &>/dev/null || $DRY_RUN; then
    # Audit rules
    AUDIT_RULES="/etc/audit/rules.d/hardening.rules"

    if $DRY_RUN; then
        dry "Create audit rules at $AUDIT_RULES"
    else
        backup "$AUDIT_RULES"
        cat > "$AUDIT_RULES" << 'RULES'
# Hardening audit rules - Fran Rudes (@Erothan-11)

# Monitor authentication files
-w /etc/passwd -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/group -p wa -k identity
-w /etc/gshadow -p wa -k identity
-w /etc/sudoers -p wa -k sudoers
-w /etc/sudoers.d/ -p wa -k sudoers

# Monitor SSH config
-w /etc/ssh/sshd_config -p wa -k sshd_config
-w /etc/ssh/sshd_config.d/ -p wa -k sshd_config

# Monitor cron
-w /etc/crontab -p wa -k cron
-w /etc/cron.d/ -p wa -k cron
-w /etc/cron.daily/ -p wa -k cron
-w /etc/cron.hourly/ -p wa -k cron
-w /etc/cron.weekly/ -p wa -k cron
-w /etc/cron.monthly/ -p wa -k cron
-w /var/spool/cron/ -p wa -k cron

# Monitor login configs
-w /etc/login.defs -p wa -k login
-w /etc/pam.d/ -p wa -k pam
-w /etc/securetty -p wa -k login

# Monitor network config
-w /etc/hosts -p wa -k network
-w /etc/resolv.conf -p wa -k network
-w /etc/sysctl.conf -p wa -k sysctl
-w /etc/sysctl.d/ -p wa -k sysctl

# Monitor systemd services
-w /etc/systemd/ -p wa -k systemd
-w /usr/lib/systemd/ -p wa -k systemd

# Log all commands run as root
-a always,exit -F arch=b64 -F euid=0 -S execve -k root_commands
-a always,exit -F arch=b32 -F euid=0 -S execve -k root_commands

# Privilege escalation
-a always,exit -F arch=b64 -S setuid -S setgid -k privilege_escalation
-a always,exit -F arch=b32 -S setuid -S setgid -k privilege_escalation

# File deletion by users
-a always,exit -F arch=b64 -S unlink -S rename -S unlinkat -S renameat -F auid>=1000 -F auid!=4294967295 -k file_deletion

# Kernel module loading
-w /sbin/insmod -p x -k kernel_modules
-w /sbin/rmmod -p x -k kernel_modules
-w /sbin/modprobe -p x -k kernel_modules

# Make config immutable (reboot required to change)
-e 2
RULES
        changed "Created audit rules"

        systemctl enable auditd 2>/dev/null
        systemctl restart auditd 2>/dev/null
        changed "Auditd enabled and restarted"
    fi
fi
fi

# ===================================================================
# MODULE: FILE PERMISSIONS
# ===================================================================
if should_run "permissions"; then
header "FILE PERMISSIONS"

fix_perms() {
    local file="$1"
    local owner="$2"
    local perms="$3"
    local desc="$4"

    if [[ ! -f "$file" ]]; then
        skip "$desc: file not found"
        return
    fi

    local current_perms current_owner
    current_perms=$(stat -c "%a" "$file" 2>/dev/null)
    current_owner=$(stat -c "%U:%G" "$file" 2>/dev/null)

    if [[ "$current_perms" == "$perms" && "$current_owner" == "$owner" ]]; then
        ok "$desc: already correct ($perms, $owner)"
        return
    fi

    if $DRY_RUN; then
        dry "$desc: $current_perms/$current_owner -> $perms/$owner"
        return
    fi

    backup "$file"
    chown "$owner" "$file" 2>/dev/null
    chmod "$perms" "$file" 2>/dev/null
    changed "$desc: $current_perms -> $perms, $current_owner -> $owner"
}

fix_perms /etc/passwd "root:root" "644" "/etc/passwd"
fix_perms /etc/shadow "root:root" "640" "/etc/shadow"
fix_perms /etc/group "root:root" "644" "/etc/group"
fix_perms /etc/gshadow "root:root" "640" "/etc/gshadow"
fix_perms /etc/ssh/sshd_config "root:root" "600" "sshd_config"
fix_perms /etc/crontab "root:root" "600" "/etc/crontab"
fix_perms /boot/grub/grub.cfg "root:root" "600" "GRUB config"
fix_perms /boot/grub2/grub.cfg "root:root" "600" "GRUB2 config"

# Remove world-writable permissions from critical dirs
for dir in /etc /usr /var/log; do
    ww_count=$(find "$dir" -type f -perm -0002 2>/dev/null | wc -l)
    if [[ "$ww_count" -gt 0 ]]; then
        if $DRY_RUN; then
            dry "Remove world-writable from $ww_count files in $dir"
        else
            find "$dir" -type f -perm -0002 -exec chmod o-w {} \; 2>/dev/null
            changed "Removed world-writable from $ww_count files in $dir"
        fi
    else
        ok "No world-writable files in $dir"
    fi
done

# Sticky bit on world-writable dirs
for dir in /tmp /var/tmp; do
    if [[ -d "$dir" ]]; then
        if stat -c "%a" "$dir" 2>/dev/null | grep -q "1"; then
            ok "$dir has sticky bit"
        else
            if $DRY_RUN; then
                dry "Set sticky bit on $dir"
            else
                chmod +t "$dir" 2>/dev/null
                changed "Set sticky bit on $dir"
            fi
        fi
    fi
done
fi

# ===================================================================
# MODULE: SERVICES
# ===================================================================
if should_run "services"; then
header "SERVICE HARDENING"

# Disable insecure services
insecure_services=(
    "telnet" "rsh" "rlogin" "rexec" "tftp"
    "vsftpd" "xinetd" "avahi-daemon"
    "cups" "rpcbind" "nfs-server"
)

for svc in "${insecure_services[@]}"; do
    if systemctl is-enabled "$svc" &>/dev/null 2>&1; then
        if $DRY_RUN; then
            dry "Disable service: $svc"
        else
            systemctl stop "$svc" 2>/dev/null
            systemctl disable "$svc" 2>/dev/null
            changed "Disabled: $svc"
        fi
    else
        ok "$svc: already disabled or not installed"
    fi
done

# Ensure core security services are enabled
essential_services=("auditd" "rsyslog" "sshd")
for svc in "${essential_services[@]}"; do
    if command -v systemctl &>/dev/null; then
        if systemctl is-enabled "$svc" &>/dev/null 2>&1; then
            ok "$svc: enabled"
        else
            if $DRY_RUN; then
                dry "Enable service: $svc"
            else
                systemctl enable "$svc" 2>/dev/null
                systemctl start "$svc" 2>/dev/null
                changed "Enabled: $svc"
            fi
        fi
    fi
done
fi

# ===================================================================
# MODULE: FAIL2BAN
# ===================================================================
if should_run "fail2ban"; then
header "FAIL2BAN"

if ! command -v fail2ban-client &>/dev/null; then
    if $DRY_RUN; then
        dry "Install fail2ban"
    else
        info "Installing fail2ban..."
        case "$DISTRO_FAMILY" in
            debian) apt-get install -y fail2ban &>/dev/null ;;
            rhel)   dnf install -y fail2ban &>/dev/null || yum install -y epel-release fail2ban &>/dev/null ;;
        esac
        if command -v fail2ban-client &>/dev/null; then
            changed "Installed fail2ban"
        else
            warn "Could not install fail2ban"
        fi
    fi
fi

if command -v fail2ban-client &>/dev/null || $DRY_RUN; then
    F2B_LOCAL="/etc/fail2ban/jail.local"

    if $DRY_RUN; then
        dry "Create fail2ban config at $F2B_LOCAL"
    else
        backup "$F2B_LOCAL"
        cat > "$F2B_LOCAL" << 'F2B'
# Fail2ban hardening config - Fran Rudes (@Erothan-11)
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 3
banaction = iptables-multiport
backend = systemd

[sshd]
enabled = true
port = ssh
filter = sshd
logpath = %(sshd_log)s
maxretry = 3
bantime = 7200
F2B

        changed "Created fail2ban config"
        systemctl enable fail2ban 2>/dev/null
        systemctl restart fail2ban 2>/dev/null
        changed "Fail2ban enabled and started"
    fi
fi
fi

# ===================================================================
# MODULE: NETWORK
# ===================================================================
if should_run "network"; then
header "NETWORK HARDENING"

# Disable unused protocols
if $DRY_RUN; then
    dry "Disable DCCP, SCTP, RDS, TIPC protocols"
else
    MODPROBE_DIR="/etc/modprobe.d"
    mkdir -p "$MODPROBE_DIR"

    protocols=("dccp" "sctp" "rds" "tipc")
    for proto in "${protocols[@]}"; do
        if ! grep -q "install ${proto} /bin/true" "${MODPROBE_DIR}/hardening.conf" 2>/dev/null; then
            echo "install ${proto} /bin/true" >> "${MODPROBE_DIR}/hardening.conf"
            changed "Disabled protocol: $proto"
        else
            ok "$proto: already disabled"
        fi
    done
fi

# TCP wrappers
if [[ -f /etc/hosts.deny ]]; then
    if ! grep -q "ALL: ALL" /etc/hosts.deny 2>/dev/null; then
        if $DRY_RUN; then
            dry "Set hosts.deny to ALL: ALL"
        else
            backup /etc/hosts.deny
            echo "ALL: ALL" >> /etc/hosts.deny
            changed "hosts.deny: ALL: ALL"
        fi
    else
        ok "hosts.deny: already ALL: ALL"
    fi
fi

if [[ -f /etc/hosts.allow ]]; then
    if ! grep -q "sshd: ALL" /etc/hosts.allow 2>/dev/null; then
        if $DRY_RUN; then
            dry "Allow sshd in hosts.allow"
        else
            backup /etc/hosts.allow
            echo "sshd: ALL" >> /etc/hosts.allow
            changed "hosts.allow: sshd: ALL"
        fi
    else
        ok "hosts.allow: sshd already allowed"
    fi
fi
fi

# ===================================================================
# MODULE: AUTHENTICATION
# ===================================================================
if should_run "auth"; then
header "AUTHENTICATION HARDENING"

# Password policy
LOGIN_DEFS="/etc/login.defs"
if [[ -f "$LOGIN_DEFS" ]]; then
    set_config "$LOGIN_DEFS" "PASS_MAX_DAYS" "90"
    set_config "$LOGIN_DEFS" "PASS_MIN_DAYS" "1"
    set_config "$LOGIN_DEFS" "PASS_MIN_LEN" "12"
    set_config "$LOGIN_DEFS" "PASS_WARN_AGE" "14"
    set_config "$LOGIN_DEFS" "LOGIN_RETRIES" "3"
    set_config "$LOGIN_DEFS" "LOGIN_TIMEOUT" "60"
    set_config "$LOGIN_DEFS" "UMASK" "027"
fi

# Lock inactive accounts (90 days)
if $DRY_RUN; then
    dry "Set useradd default inactive to 30 days"
else
    useradd -D -f 30 2>/dev/null
    changed "Default account inactivity lock: 30 days"
fi

# Disable root console login (securetty)
if [[ -f /etc/securetty ]]; then
    if $DRY_RUN; then
        dry "Empty /etc/securetty to disable root console login"
    else
        backup /etc/securetty
        echo "" > /etc/securetty
        changed "Disabled root console login (securetty)"
    fi
fi

# Restrict su to wheel/sudo group
if [[ -f /etc/pam.d/su ]]; then
    if ! grep -q "pam_wheel.so" /etc/pam.d/su 2>/dev/null || grep -q "^#.*pam_wheel.so" /etc/pam.d/su 2>/dev/null; then
        if $DRY_RUN; then
            dry "Restrict su to wheel group via pam_wheel.so"
        else
            backup /etc/pam.d/su
            sed -i 's/^#\s*\(auth\s*required\s*pam_wheel.so\)/\1/' /etc/pam.d/su
            changed "Restricted su to wheel group"
        fi
    else
        ok "su already restricted to wheel group"
    fi
fi
fi

# ===================================================================
# SUMMARY
# ===================================================================
header "HARDENING COMPLETE"
echo ""

if $DRY_RUN; then
    info "${YELLOW}DRY-RUN: No changes were applied${NC}"
    echo ""
fi

info "Changes applied: ${BOLD}$CHANGES${NC}"
info "Skipped:         ${BOLD}$SKIPPED${NC}"
info "Backup dir:      ${BOLD}$BACKUP_DIR${NC}"
info "Log file:        ${BOLD}$LOG_FILE${NC}"
echo ""

if [[ $CHANGES -gt 0 ]] && ! $DRY_RUN; then
    warn "Some changes may require a reboot to take full effect"
    warn "Review $LOG_FILE for all changes made"
fi

echo ""
echo -e "  ${BOLD}To undo changes:${NC}"
echo "  cp -r ${BACKUP_DIR}/* / "
echo ""
