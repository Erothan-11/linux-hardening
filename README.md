# Linux Hardening

![Bash](https://img.shields.io/badge/Bash-4EAA25?style=flat-square&logo=gnubash&logoColor=white)
![Linux](https://img.shields.io/badge/Linux-FCC624?style=flat-square&logo=linux&logoColor=black)
![License](https://img.shields.io/badge/License-MIT-blue?style=flat-square)

Automated Linux hardening script based on CIS benchmarks. Configures SSH, firewall, kernel parameters, auditing, file permissions, fail2ban and more. Supports Debian/Ubuntu and RHEL/Rocky/CentOS.

## Modules

| Module | What it hardens |
|---|---|
| **ssh** | Root login, password auth, empty passwords, X11, MaxAuthTries, banner, agent/TCP forwarding |
| **firewall** | UFW/firewalld/iptables — default deny, allow SSH, log dropped packets |
| **kernel** | 18 sysctl params: ASLR, SYN cookies, ICMP, source routing, martians, ptrace, dmesg restrict |
| **audit** | Install auditd + rules: identity files, SSH, cron, PAM, network, root commands, kernel modules |
| **permissions** | /etc/passwd, shadow, group, sshd_config, crontab, GRUB, world-writable cleanup, sticky bits |
| **services** | Disable insecure (telnet, rsh, tftp, avahi, cups, rpcbind), ensure essential (auditd, rsyslog, sshd) |
| **fail2ban** | Install + configure: SSH jail, 3 retries, 2h ban, systemd backend |
| **network** | Disable DCCP/SCTP/RDS/TIPC, TCP wrappers (hosts.allow/deny) |
| **auth** | Password policy (90 day max, 12 char min), inactive lock, securetty, restrict su to wheel |

## Usage

```bash
# Preview all changes (no modifications)
sudo ./harden.sh --dry-run

# Apply all hardening
sudo ./harden.sh

# Run specific modules only
sudo ./harden.sh --modules ssh,firewall,kernel

# Dry-run specific modules
sudo ./harden.sh --dry-run --modules ssh,audit,fail2ban
```

## Safety Features

- **`--dry-run`** — preview every change before applying
- **Automatic backups** — all modified files backed up to `/root/hardening_backup_<timestamp>/`
- **Idempotent** — safe to run multiple times, skips already-applied settings
- **Full logging** — every action logged to `/var/log/hardening_<timestamp>.log`
- **Undo** — restore originals with `cp -r /root/hardening_backup_<timestamp>/* /`

## Requirements

- Linux (Debian/Ubuntu or RHEL/Rocky/CentOS/Fedora)
- Root privileges
- No external dependencies (pure Bash)

## Warning

This script **modifies system configuration**. Always:
1. Run `--dry-run` first
2. Test in a non-production environment
3. Keep backups accessible
4. Verify SSH access before disconnecting

## License

MIT
