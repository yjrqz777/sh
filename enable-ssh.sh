#!/usr/bin/env bash
#
# 一键检查并开启 VPS 的 SSH 服务，并配置 root 密码登录
#
# 用法（在 VPS 上以 root 执行）：
#   bash enable-ssh.sh '你的root新密码'
#   ROOT_PASSWORD='你的root新密码' bash enable-ssh.sh
#   bash enable-ssh.sh                # 交互式输入密码
#
# 只做两件事：开启 SSH 服务、允许 root 密码登录。
#
set -uo pipefail

C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_CYAN=$'\033[36m'; C_OFF=$'\033[0m'
info() { printf '%s[信息]%s %s\n' "$C_CYAN" "$C_OFF" "$*"; }
ok()   { printf '%s[完成]%s %s\n' "$C_GREEN" "$C_OFF" "$*"; }
warn() { printf '%s[注意]%s %s\n' "$C_YELLOW" "$C_OFF" "$*"; }
die()  { printf '%s[错误]%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "请以 root 运行：sudo bash $0 '你的root新密码'"

# ---------------------------------------------------------------- 1. 取密码
NEW_PASSWORD="${1:-${ROOT_PASSWORD:-}}"
if [ -z "$NEW_PASSWORD" ]; then
    if [ -t 0 ]; then
        printf '请输入要设置的 root 密码：'
        read -rs NEW_PASSWORD
        printf '\n请再输入一次确认：'
        read -rs CONFIRM
        printf '\n'
        [ "$NEW_PASSWORD" = "$CONFIRM" ] || die "两次输入的密码不一致"
    else
        die "未提供密码。用法：bash $0 '你的root新密码'"
    fi
fi
[ -n "$NEW_PASSWORD" ] || die "密码不能为空"
case "$NEW_PASSWORD" in
    *$'\n'*) die "密码中不能包含换行符" ;;
esac

# ---------------------------------------------------------- 2. 识别系统类型
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
info "包管理器：${PKG:-未识别}"

# ------------------------------------------------------ 3. 安装 openssh-server
install_sshd() {
    info "未检测到 sshd，开始安装 openssh-server ..."
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
    install_sshd || die "安装 openssh-server 失败，请手动安装后重试"
    for p in /usr/sbin/sshd /usr/local/sbin/sshd /sbin/sshd /usr/bin/sshd; do
        [ -x "$p" ] && SSHD_BIN="$p" && break
    done
    [ -n "$SSHD_BIN" ] || die "安装后仍未找到 sshd"
fi
ok "sshd 路径：$SSHD_BIN"

SSH_DIR=/etc/ssh
MAIN_CONF="$SSH_DIR/sshd_config"
DROPIN_DIR="$SSH_DIR/sshd_config.d"
DROPIN="$DROPIN_DIR/00-enable-ssh-root.conf"
[ -e "$MAIN_CONF" ] || die "找不到 $MAIN_CONF"
mkdir -p "$DROPIN_DIR"

# ------------------------------------------------------ 4. 判断当前监听端口
PORTS=""
if "$SSHD_BIN" -T >/dev/null 2>&1; then
    PORTS=$("$SSHD_BIN" -T 2>/dev/null | awk '$1=="port"{print $2}' | sort -u | tr '\n' ' ')
fi
[ -n "${PORTS// /}" ] || PORTS=$(awk 'tolower($1)=="port"{print $2}' "$MAIN_CONF" 2>/dev/null | tr '\n' ' ')
PORTS="${PORTS:-22}"
PORTS=$(printf '%s' "$PORTS" | tr -s ' ')
info "当前 SSH 端口：$PORTS"

# ------------------------------------------------- 5. 备份并写 sshd 配置
BACKUP="$MAIN_CONF.bak.enable-ssh"
[ -e "$BACKUP" ] || cp -a "$MAIN_CONF" "$BACKUP"
info "已备份原配置到 $BACKUP"

# 5.1 确保主配置顶部引入 sshd_config.d
if ! grep -qiE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' "$MAIN_CONF"; then
    TMP=$(mktemp)
    printf 'Include /etc/ssh/sshd_config.d/*.conf\n' > "$TMP"
    cat "$MAIN_CONF" >> "$TMP"
    cat "$TMP" > "$MAIN_CONF"
    rm -f "$TMP"
    info "已在主配置顶部加入 Include 指令"
fi

# 5.2 注释掉主配置里与 root 密码登录冲突的旧指令
if grep -qiE '^[[:space:]]*(PermitRootLogin|PasswordAuthentication|KbdInteractiveAuthentication|ChallengeResponseAuthentication)' "$MAIN_CONF"; then
    sed -i -E 's|^[[:space:]]*(PermitRootLogin|PasswordAuthentication|KbdInteractiveAuthentication|ChallengeResponseAuthentication)|# [enable-ssh.sh] \1|I' "$MAIN_CONF"
    info "已注释主配置中的冲突指令"
fi

# 5.3 注释掉其它 drop-in 里冲突的指令（例如 cloud-init 写入的）
for f in "$DROPIN_DIR"/*.conf; do
    [ -e "$f" ] || continue
    [ "$f" = "$DROPIN" ] && continue
    if grep -qiE '^[[:space:]]*(PermitRootLogin|PasswordAuthentication|KbdInteractiveAuthentication|ChallengeResponseAuthentication)' "$f"; then
        [ -e "$f.bak.enable-ssh" ] || cp -a "$f" "$f.bak.enable-ssh"
        sed -i -E 's|^[[:space:]]*(PermitRootLogin|PasswordAuthentication|KbdInteractiveAuthentication|ChallengeResponseAuthentication)|# [enable-ssh.sh] \1|I' "$f"
        info "已注释冲突配置：$f"
    fi
done

# 5.4 写入本脚本的配置（00- 前缀保证最先被读取）
cat > "$DROPIN" <<'SSHD_CONF'
# 由 enable-ssh.sh 写入：开启 SSH 并允许 root 密码登录
PermitRootLogin yes
PasswordAuthentication yes
KbdInteractiveAuthentication yes
ChallengeResponseAuthentication yes
PubkeyAuthentication yes
UsePAM yes
SSHD_CONF
chmod 600 "$DROPIN"
ok "已写入配置：$DROPIN"

# 5.5 语法检查，失败则回滚
if ! ERR=$("$SSHD_BIN" -t 2>&1); then
    printf '%s\n' "$ERR" >&2
    rm -f "$DROPIN"
    cat "$BACKUP" > "$MAIN_CONF"
    die "sshd 配置校验失败，已回滚到原配置"
fi
ok "sshd 配置语法校验通过"

# ------------------------------------------------------- 6. 设置 root 密码
printf 'root:%s\n' "$NEW_PASSWORD" | chpasswd || die "设置 root 密码失败"
passwd -u root >/dev/null 2>&1 || usermod -U root >/dev/null 2>&1 || true
chage -E -1 -M 99999 root >/dev/null 2>&1 || true
unset NEW_PASSWORD CONFIRM
ok "root 密码已设置，账号已解锁"

# --------------------------------------------------------- 7. 放行 SSH 端口
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi '^Status: active'; then
    for p in $PORTS; do ufw allow "$p/tcp" >/dev/null 2>&1; done
    ok "ufw 已放行端口：$PORTS"
elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    for p in $PORTS; do firewall-cmd --permanent --add-port="$p/tcp" >/dev/null 2>&1; done
    firewall-cmd --reload >/dev/null 2>&1
    ok "firewalld 已放行端口：$PORTS"
else
    info "未检测到启用中的 ufw/firewalld，跳过防火墙放行"
fi

# --------------------------------------------------- 8. 启用并启动 SSH 服务
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
        ok "已启用并重启服务：$SVC"
    fi
    if [ "$started" -eq 0 ] && [ "$SVC" = ssh ] && systemctl list-unit-files 2>/dev/null | grep -q '^ssh\.socket'; then
        systemctl enable --now ssh.socket >/dev/null 2>&1 && started=1 && ok "已启用 ssh.socket"
    fi
fi

if [ "$started" -eq 0 ]; then
    if   command -v service >/dev/null 2>&1 && service ssh restart >/dev/null 2>&1; then started=1; ok "已通过 service 重启 ssh"
    elif command -v service >/dev/null 2>&1 && service sshd restart >/dev/null 2>&1; then started=1; ok "已通过 service 重启 sshd"
    elif "$SSHD_BIN" >/dev/null 2>&1; then started=1; warn "已直接拉起 sshd 进程（无 systemd/service）"
    fi
fi
[ "$started" -eq 1 ] || warn "无法启动 SSH 服务，请手动检查：systemctl status ${SVC:-ssh}"

# ------------------------------------------------------------ 9. 结果检查
sleep 1
printf '\n%s===== 检查结果 =====%s\n' "$C_GREEN" "$C_OFF"

listening=""
if command -v ss >/dev/null 2>&1; then
    listening=$(ss -lntH 2>/dev/null | awk '{print $4}')
elif command -v netstat >/dev/null 2>&1; then
    listening=$(netstat -lnt 2>/dev/null | awk 'NR>2{print $4}')
fi

listen_ok=0
for p in $PORTS; do
    if printf '%s\n' "$listening" | grep -qE "[:.]$p\$"; then
        ok "SSH 正在监听端口 $p"
        listen_ok=1
    else
        warn "未检测到端口 $p 在监听"
    fi
done

if pgrep -x sshd >/dev/null 2>&1; then
    ok "sshd 进程运行中"
else
    warn "未发现 sshd 进程"
fi

EFFECTIVE=$("$SSHD_BIN" -T 2>/dev/null | awk '$1=="permitrootlogin"||$1=="passwordauthentication"{print $1" = "$2}')
[ -n "$EFFECTIVE" ] && printf '生效配置：\n%s\n' "$EFFECTIVE"

IPS=$( { command -v ip >/dev/null 2>&1 && ip -4 addr show scope global 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1; } | sort -u | tr '\n' ' ')
printf '\n用下面任一条命令登录（端口取上面实际监听值）：\n'
for ip in $IPS; do
    for p in $PORTS; do
        if [ "$p" = "22" ]; then printf '  ssh root@%s\n' "$ip"
        else printf '  ssh -p %s root@%s\n' "$p" "$ip"; fi
    done
done

if [ "$listen_ok" -eq 1 ]; then
    ok "全部完成，root 密码登录已开启"
    exit 0
else
    warn "配置已写入，但未检测到监听，请检查安全组/云平台防火墙后再试"
    exit 1
fi
