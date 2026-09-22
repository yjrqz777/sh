#!/usr/bin/env bash
#
# Enable SSH on a VPS and allow root password login.
#
# Usage (as root on the VPS):
#   bash enable-ssh.sh 'new-root-password'
#   ROOT_PASSWORD='new-root-password' bash enable-ssh.sh
#   bash enable-ssh.sh                # interactive password prompt
#
# This script only does two things: enable the SSH service and allow root password login.
#
set -uo pipefail

C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_CYAN=$'\033[36m'; C_OFF=$'\033[0m'
info() { printf '%s[INFO]%s %s\n' "$C_CYAN" "$C_OFF" "$*"; }
ok()   { printf '%s[ OK ]%s %s\n' "$C_GREEN" "$C_OFF" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$C_YELLOW" "$C_OFF" "$*"; }
die()  { printf '%s[FAIL]%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "must run as root: sudo bash $0 'new-root-password'"

# ------------------------------------------------------------- 1. get password
NEW_PASSWORD="${1:-${ROOT_PASSWORD:-}}"
if [ -z "$NEW_PASSWORD" ]; then
    if [ -t 0 ]; then
        printf 'Enter new root password: '
        read -rs NEW_PASSWORD
        printf '\nConfirm new root password: '
        read -rs CONFIRM
        printf '\n'
        [ "$NEW_PASSWORD" = "$CONFIRM" ] || die "passwords do not match"
    else
        die "no password given. usage: bash $0 'new-root-password'"
    fi
fi
[ -n "$NEW_PASSWORD" ] || die "password must not be empty"
case "$NEW_PASSWORD" in
    *$'\n'*) die "password must not contain a newline" ;;
esac

# --------------------------------------------------------- 2. detect system
SSHD_BIN=""
for p in /usr/sbin/sshd /usr/local/sbin/sshd /sbin/sshd /usr/bin/sshd; do
    [ -x "$p" ] && SSHD_BIN="$p" && break
done

PKG=""
if   command -v apt-get >/dev/null 2>&1; then PKG=apt
elif command -v dnf     >/dev/null 2>&1; then PKG=dnf
elif command -v yum     >/dev/null 2>&1; then PKG=yum
elif command -v apk     >/dev/null 2>&1; then PKG=apk
elif command -v zypper  >/dev/null 2>&1; then PKG=zypper
elif command -v pacman  >/dev/null 2>&1; then PKG=pacman
fi
info "package manager: ${PKG:-unknown}"

# --------------------------------------------------- 3. install openssh-server
install_sshd() {
    info "sshd not found, installing openssh-server ..."
    case "$PKG" in
        apt)    DEBIAN_FRONTEND=noninteractive apt-get update -qq && \
                DEBIAN_FRONTEND=noninteractive apt-get install -y -qq openssh-server ;;
        dnf)    dnf install -y -q openssh-server ;;
        yum)    yum install -y -q openssh-server ;;
        apk)    apk add --no-cache openssh ;;
        zypper) zypper --non-interactive install openssh ;;
        pacman) pacman -Sy --noconfirm --needed openssh ;;
        *)      return 1 ;;
    esac
}

if [ -z "$SSHD_BIN" ]; then
    install_sshd || die "failed to install openssh-server, install it manually and retry"
    for p in /usr/sbin/sshd /usr/local/sbin/sshd /sbin/sshd /usr/bin/sshd; do
        [ -x "$p" ] && SSHD_BIN="$p" && break
    done
    [ -n "$SSHD_BIN" ] || die "sshd still not found after install"
fi
ok "sshd binary: $SSHD_BIN"

SSH_DIR=/etc/ssh
MAIN_CONF="$SSH_DIR/sshd_config"
DROPIN_DIR="$SSH_DIR/sshd_config.d"
DROPIN="$DROPIN_DIR/00-enable-ssh-root.conf"
[ -e "$MAIN_CONF" ] || die "$MAIN_CONF not found"
mkdir -p "$DROPIN_DIR"

# ------------------------------------------------------ 4. detect listen port
PORTS=""
if "$SSHD_BIN" -T >/dev/null 2>&1; then
    PORTS=$("$SSHD_BIN" -T 2>/dev/null | awk '$1=="port"{print $2}' | sort -u | tr '\n' ' ')
fi
[ -n "${PORTS// /}" ] || PORTS=$(awk 'tolower($1)=="port"{print $2}' "$MAIN_CONF" 2>/dev/null | tr '\n' ' ')
PORTS="${PORTS:-22}"
PORTS=$(printf '%s' "$PORTS" | tr -s ' ')
info "current SSH port(s): $PORTS"

# ------------------------------------------- 5. back up and write sshd config
BACKUP="$MAIN_CONF.bak.enable-ssh"
[ -e "$BACKUP" ] || cp -a "$MAIN_CONF" "$BACKUP"
info "original config backed up to $BACKUP"

# 5.1 make sure the main config includes sshd_config.d
if ! grep -qiE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' "$MAIN_CONF"; then
    TMP=$(mktemp)
    printf 'Include /etc/ssh/sshd_config.d/*.conf\n' > "$TMP"
    cat "$MAIN_CONF" >> "$TMP"
    cat "$TMP" > "$MAIN_CONF"
    rm -f "$TMP"
    info "added Include directive at the top of the main config"
fi

# 5.2 comment out conflicting directives in the main config
if grep -qiE '^[[:space:]]*(PermitRootLogin|PasswordAuthentication|KbdInteractiveAuthentication|ChallengeResponseAuthentication)' "$MAIN_CONF"; then
    sed -i -E 's|^[[:space:]]*(PermitRootLogin|PasswordAuthentication|KbdInteractiveAuthentication|ChallengeResponseAuthentication)|# [enable-ssh.sh] \1|I' "$MAIN_CONF"
    info "commented out conflicting directives in the main config"
fi

# 5.3 comment out conflicting directives in other drop-ins (e.g. written by cloud-init)
for f in "$DROPIN_DIR"/*.conf; do
    [ -e "$f" ] || continue
    [ "$f" = "$DROPIN" ] && continue
    if grep -qiE '^[[:space:]]*(PermitRootLogin|PasswordAuthentication|KbdInteractiveAuthentication|ChallengeResponseAuthentication)' "$f"; then
        [ -e "$f.bak.enable-ssh" ] || cp -a "$f" "$f.bak.enable-ssh"
        sed -i -E 's|^[[:space:]]*(PermitRootLogin|PasswordAuthentication|KbdInteractiveAuthentication|ChallengeResponseAuthentication)|# [enable-ssh.sh] \1|I' "$f"
        info "commented out conflicting config: $f"
    fi
done

# 5.4 write our own config (00- prefix so it is read first)
cat > "$DROPIN" <<'SSHD_CONF'
# written by enable-ssh.sh: enable SSH and allow root password login
PermitRootLogin yes
PasswordAuthentication yes
KbdInteractiveAuthentication yes
ChallengeResponseAuthentication yes
PubkeyAuthentication yes
UsePAM yes
SSHD_CONF
chmod 600 "$DROPIN"
ok "config written: $DROPIN"

# 5.5 syntax check, roll back on failure
if ! ERR=$("$SSHD_BIN" -t 2>&1); then
    printf '%s\n' "$ERR" >&2
    rm -f "$DROPIN"
    cat "$BACKUP" > "$MAIN_CONF"
    die "sshd config check failed, rolled back to the original config"
fi
ok "sshd config syntax check passed"

# ------------------------------------------------------ 6. set root password
printf 'root:%s\n' "$NEW_PASSWORD" | chpasswd || die "failed to set root password"
passwd -u root >/dev/null 2>&1 || usermod -U root >/dev/null 2>&1 || true
chage -E -1 -M 99999 root >/dev/null 2>&1 || true
unset NEW_PASSWORD CONFIRM
ok "root password set, account unlocked"

# --------------------------------------------------------- 7. open SSH port
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi '^Status: active'; then
    for p in $PORTS; do ufw allow "$p/tcp" >/dev/null 2>&1; done
    ok "ufw: allowed port(s) $PORTS"
elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    for p in $PORTS; do firewall-cmd --permanent --add-port="$p/tcp" >/dev/null 2>&1; done
    firewall-cmd --reload >/dev/null 2>&1
    ok "firewalld: allowed port(s) $PORTS"
else
    info "no active ufw/firewalld found, skipping firewall rules"
fi

# --------------------------------------------- 8. enable and start SSH service
SVC=""
if command -v systemctl >/dev/null 2>&1; then
    if systemctl list-unit-files 2>/dev/null | grep -q '^sshd\.service'; then SVC=sshd
    elif systemctl list-unit-files 2>/dev/null | grep -q '^ssh\.service'; then SVC=ssh
    fi
fi

started=0
if [ -n "$SVC" ]; then
    systemctl unmask "$SVC" >/dev/null 2>&1 || true
    systemctl enable "$SVC" >/dev/null 2>&1 || true
    if systemctl restart "$SVC" >/dev/null 2>&1 || systemctl start "$SVC" >/dev/null 2>&1; then
        started=1
        ok "service enabled and restarted: $SVC"
    fi
    if [ "$started" -eq 0 ] && [ "$SVC" = ssh ] && systemctl list-unit-files 2>/dev/null | grep -q '^ssh\.socket'; then
        systemctl enable --now ssh.socket >/dev/null 2>&1 && started=1 && ok "ssh.socket enabled"
    fi
fi

if [ "$started" -eq 0 ]; then
    if   command -v service >/dev/null 2>&1 && service ssh restart >/dev/null 2>&1; then started=1; ok "ssh restarted via service"
    elif command -v service >/dev/null 2>&1 && service sshd restart >/dev/null 2>&1; then started=1; ok "sshd restarted via service"
    elif "$SSHD_BIN" >/dev/null 2>&1; then started=1; warn "started sshd directly (no systemd/service)"
    fi
fi
[ "$started" -eq 1 ] || warn "could not start SSH service, check: systemctl status ${SVC:-ssh}"

# ------------------------------------------------------------- 9. check result
sleep 1
printf '\n%s===== RESULT =====%s\n' "$C_GREEN" "$C_OFF"

listening=""
if command -v ss >/dev/null 2>&1; then
    listening=$(ss -lntH 2>/dev/null | awk '{print $4}')
elif command -v netstat >/dev/null 2>&1; then
    listening=$(netstat -lnt 2>/dev/null | awk 'NR>2{print $4}')
fi

listen_ok=0
for p in $PORTS; do
    if printf '%s\n' "$listening" | grep -qE "[:.]$p\$"; then
        ok "SSH is listening on port $p"
        listen_ok=1
    else
        warn "port $p is not listening"
    fi
done

if pgrep -x sshd >/dev/null 2>&1; then
    ok "sshd process is running"
else
    warn "no sshd process found"
fi

EFFECTIVE=$("$SSHD_BIN" -T 2>/dev/null | awk '$1=="permitrootlogin"||$1=="passwordauthentication"{print $1" = "$2}')
[ -n "$EFFECTIVE" ] && printf 'effective settings:\n%s\n' "$EFFECTIVE"

IPS=$( { command -v ip >/dev/null 2>&1 && ip -4 addr show scope global 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1; } | sort -u | tr '\n' ' ')
printf '\nlogin with any of these (use the port shown above):\n'
for ip in $IPS; do
    for p in $PORTS; do
        if [ "$p" = "22" ]; then printf '  ssh root@%s\n' "$ip"
        else printf '  ssh -p %s root@%s\n' "$p" "$ip"; fi
    done
done

if [ "$listen_ok" -eq 1 ]; then
    ok "done, root password login is enabled"
    exit 0
else
    warn "config written but nothing is listening, check your cloud security group and retry"
    exit 1
fi
