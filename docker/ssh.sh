#!/bin/bash
#
# SSH 一键配置脚本（交互式菜单 + 命令行模式）
# 功能：安装/配置 SSH，管理公钥，修改用户密码，自动测试与回滚，重装 SSH 服务
# 支持发行版：Debian/Ubuntu, RHEL/CentOS/Fedora, Arch, openSUSE, Alpine (OpenRC)
# 依赖：bash, sed, grep, awk, cat, (可选) systemctl/service/rc-service, chpasswd/passwd
#
# 版本：2.1 (注册 sshx 命令；未识别 init 时改用后台方式启动 sshd)
#

set -e

# 全局变量
SSHD_CONFIG="/etc/ssh/sshd_config"
BACKUP_SUFFIX=".backup.$(date +%Y%m%d%H%M%S)"
SSHD_SERVICE=""
SSHD_INIT=""                        # systemd / openrc / sysv / none
SSHD_PIDFILE="/run/sshd.pid"
CONFIG_CHANGED=false
BACKUP_FILE=""
INSTALLED_NOW=false                 # 本次运行是否刚安装了 openssh-server

# 自身注册信息（安装为 sshx 命令）
SELF_PATH="/usr/local/bin/sshx"
SELF_URL="https://sb.vir.kdns.fr/sh/ssh.sh"

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ------------------------------------------------------------
# 工具函数
# ------------------------------------------------------------
print_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
print_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
print_title() { echo -e "${BLUE}==== $1 ====${NC}"; }

# 清屏（容器/TERM=dumb 下 clear 可能返回非零，需忽略以免 set -e 中断脚本）
clear_screen() {
    clear 2>/dev/null || true
}

# 检测操作系统和包管理器
detect_os() {
    if command -v apt &>/dev/null; then
        PKG_INSTALL="apt install -y"
        PKG_UPDATE="apt update"
        PKG_REMOVE="apt remove -y"
        PKG_LIST="openssh-server"
    elif command -v dnf &>/dev/null; then
        PKG_INSTALL="dnf install -y"
        PKG_UPDATE="dnf check-update"
        PKG_REMOVE="dnf remove -y"
        PKG_LIST="openssh-server"
    elif command -v yum &>/dev/null; then
        PKG_INSTALL="yum install -y"
        PKG_UPDATE="yum check-update"
        PKG_REMOVE="yum remove -y"
        PKG_LIST="openssh-server"
    elif command -v apk &>/dev/null; then
        PKG_INSTALL="apk add"
        PKG_UPDATE="apk update"
        PKG_REMOVE="apk del"
        PKG_LIST="openssh-server"
    elif command -v pacman &>/dev/null; then
        PKG_INSTALL="pacman -S --noconfirm"
        PKG_UPDATE="pacman -Sy"
        PKG_REMOVE="pacman -R --noconfirm"
        PKG_LIST="openssh"
    elif command -v zypper &>/dev/null; then
        PKG_INSTALL="zypper install -y"
        PKG_UPDATE="zypper refresh"
        PKG_REMOVE="zypper remove -y"
        PKG_LIST="openssh"
    else
        print_error "不支持的操作系统或包管理器，请手动安装 openssh-server。"
    fi
}

# 检查并安装 SSH 服务
install_ssh() {
    INSTALLED_NOW=false
    if command -v sshd &>/dev/null; then
        print_info "sshd 已安装，跳过安装步骤。"
        return
    fi
    print_info "正在安装 openssh-server ..."
    eval "$PKG_UPDATE" || true
    eval "$PKG_INSTALL $PKG_LIST" || print_error "安装失败，请手动安装。"
    print_info "安装完成。"
    INSTALLED_NOW=true
    ensure_host_keys
}

# 确保存在主机密钥（全新安装/精简镜像可能没有，缺了 sshd 会拒绝启动）
ensure_host_keys() {
    local keydir="/etc/ssh"
    local have=false
    local f
    for f in "$keydir"/ssh_host_*_key; do
        [ -f "$f" ] && have=true && break
    done
    [ "$have" = true ] && return 0

    if ! command -v ssh-keygen &>/dev/null; then
        print_warn "未找到 ssh-keygen，且缺少主机密钥，sshd 可能无法启动。"
        return 0
    fi

    print_info "未检测到主机密钥，正在生成 ..."
    mkdir -p "$keydir"
    ssh-keygen -A 2>/dev/null || {
        print_warn "ssh-keygen -A 失败，尝试逐类型生成。"
        for f in rsa ecdsa ed25519; do
            [ -f "$keydir/ssh_host_${f}_key" ] && continue
            ssh-keygen -q -t "$f" -N "" -f "$keydir/ssh_host_${f}_key" 2>/dev/null || true
        done
    }
    print_info "主机密钥已就绪。"
}

# 检测 init 系统与服务名称
detect_service() {
    SSHD_INIT="none"
    SSHD_SERVICE=""

    # 容器/精简系统常见：有 systemctl 但 systemd 并非 1 号进程
    local have_systemd=false
    if command -v systemctl &>/dev/null && [ "$(ps -p 1 -o comm= 2>/dev/null)" = "systemd" ]; then
        have_systemd=true
    fi

    # OpenRC (Alpine)
    if command -v rc-service &>/dev/null; then
        if [ -x "/etc/init.d/sshd" ]; then
            SSHD_INIT="openrc"; SSHD_SERVICE="sshd"
            return
        elif [ -x "/etc/init.d/ssh" ]; then
            SSHD_INIT="openrc"; SSHD_SERVICE="ssh"
            return
        fi
    fi

    # systemd
    if [ "$have_systemd" = true ]; then
        if systemctl list-unit-files 2>/dev/null | grep -q '^sshd\.service'; then
            SSHD_INIT="systemd"; SSHD_SERVICE="sshd"
            return
        elif systemctl list-unit-files 2>/dev/null | grep -q '^ssh\.service'; then
            SSHD_INIT="systemd"; SSHD_SERVICE="ssh"
            return
        fi
    fi

    # 传统 SysV init
    if [ -x "/etc/init.d/sshd" ] && command -v service &>/dev/null; then
        SSHD_INIT="sysv"; SSHD_SERVICE="sshd"
        return
    elif [ -x "/etc/init.d/ssh" ] && command -v service &>/dev/null; then
        SSHD_INIT="sysv"; SSHD_SERVICE="ssh"
        return
    fi

    SSHD_INIT="none"
}

# 判断是否 systemd socket 激活模式（Ubuntu 22.10+ 默认）
# 这种模式下监听端口由 ssh.socket 的 ListenStream= 决定，sshd_config 的 Port 完全不参与
socket_activated() {
    [ "$SSHD_INIT" = "systemd" ] || return 1
    command -v systemctl &>/dev/null || return 1
    systemctl is-enabled "${SSHD_SERVICE}.socket" &>/dev/null && return 0
    systemctl is-active "${SSHD_SERVICE}.socket" &>/dev/null && return 0
    return 1
}

# 取 socket 单元当前实际监听的端口列表（去重）
socket_listen_ports() {
    systemctl show "${SSHD_SERVICE}.socket" -p Listen 2>/dev/null \
        | tr ' ' '\n' \
        | sed -n 's/.*:\([0-9]\{1,5\}\)[^0-9]*$/\1/p' \
        | sort -u
}

# 取 sshd_config 里的 Port（支持多行 Port）
config_ports() {
    grep -iE '^[[:space:]]*Port[[:space:]]' "$SSHD_CONFIG" 2>/dev/null \
        | awk '{print $2}' | sort -u
}

# 生成/更新 socket override，让 systemd 监听指定端口
# 关键：必须显式分开写 IPv4/IPv6。只写 ListenStream=PORT 时，若原单元有
# BindIPv6Only=ipv6-only，systemd 只会建一个纯 IPv6 socket，IPv4 直接 refused。
write_socket_override() {
    local port="$1"
    local dir="/etc/systemd/system/${SSHD_SERVICE}.socket.d"
    local conf="$dir/override.conf"

    mkdir -p "$dir" || { print_warn "无法创建 $dir"; return 1; }

    cat > "$conf" <<EOF
# 由 sshx 生成：systemd socket 激活模式下端口由 ListenStream 决定，
# 改 sshd_config 的 Port 不会影响监听端口。
# 先清空继承来的 ListenStream，再显式声明 IPv4/IPv6，避免 BindIPv6Only 导致只有 v6。
[Socket]
ListenStream=
ListenStream=0.0.0.0:${port}
ListenStream=[::]:${port}
EOF

    systemctl daemon-reload 2>/dev/null || true
    print_info "已写入 $conf（监听 0.0.0.0:${port} 与 [::]:${port}）"
    return 0
}
sshd_running() {
    [ -n "$(sshd_master_pids)" ]
}

# init 是否认为服务在运行（与 sshd_running 可能不一致）
service_registered_running() {
    case "$SSHD_INIT" in
        openrc)
            [ -f "/run/openrc/started/$SSHD_SERVICE" ]
            ;;
        systemd)
            systemctl is-active --quiet "$SSHD_SERVICE" &>/dev/null
            ;;
        sysv)
            if [ -x "/etc/init.d/$SSHD_SERVICE" ]; then
                /etc/init.d/"$SSHD_SERVICE" status &>/dev/null
            else
                service "$SSHD_SERVICE" status &>/dev/null
            fi
            ;;
        *)
            return 1
            ;;
    esac
}

# 进程在跑但 init 没记录（例如脚本后台启动过），把 init 的状态补登记回来。
# 否则 rc-service/systemctl 会一直报 stopped，后续 restart 可能失败或重复拉起。
adopt_running_process() {
    [ "$SSHD_INIT" = "none" ] && return 0
    sshd_running || return 0
    service_registered_running && return 0

    print_warn "检测到 sshd 进程在运行，但 $SSHD_INIT 未记录其状态，正在同步。"
    case "$SSHD_INIT" in
        openrc)
            # 先按未登记状态清理残留，再让 init 接管
            rm -f "/run/openrc/stopping/$SSHD_SERVICE" 2>/dev/null
            if command -v rc-service &>/dev/null; then
                # 进程已在跑时 start 会因 pidfile 冲突失败，改为登记状态
                mkdir -p /run/openrc/started 2>/dev/null
                : > "/run/openrc/started/$SSHD_SERVICE" 2>/dev/null
                if [ -f "/run/openrc/started/$SSHD_SERVICE" ]; then
                    print_info "已同步 OpenRC 状态，现在 rc-service $SSHD_SERVICE status 应显示 started。"
                fi
            fi
            ;;
        systemd)
            # 让 systemd 重新加载并接管已有进程不可靠，改为重载单元后启动
            systemctl daemon-reload &>/dev/null
            print_info "已重新加载 systemd 单元。"
            ;;
        *)
            ;;
    esac
    return 0
}

# 列出 sshd 主进程 PID（仅监听进程，不含当前登录会话的子进程）
sshd_master_pids() {
    if [ -f "$SSHD_PIDFILE" ]; then
        local p
        p=$(cat "$SSHD_PIDFILE" 2>/dev/null)
        if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then
            echo "$p"
            return 0
        fi
    fi
    # 监听进程标题形如 "sshd: /usr/sbin/sshd -D [listener] ..."
    local pids
    pids=$(pgrep -f 'sshd.*\[listener\]' 2>/dev/null || true)
    if [ -n "$pids" ]; then
        echo "$pids"
        return 0
    fi
    # 兜底：排除 "sshd: user@pts/N" 这类会话子进程
    pgrep -x sshd 2>/dev/null | while read -r p; do
        case "$(ps -p "$p" -o args= 2>/dev/null)" in
            *@*) ;;
            *) echo "$p" ;;
        esac
    done
}

# 后台直接启动 sshd（init 系统无法识别时的兜底方案）
start_sshd_background() {
    if sshd_running; then
        print_info "检测到 sshd 已在运行，跳过后台启动。"
        return 0
    fi

    print_info "未识别的 init 系统，改用后台方式启动 sshd ..."

    # 配置文件不存在时 sshd 无法启动，先补一份最小可用配置
    if [ ! -f "$SSHD_CONFIG" ]; then
        mkdir -p "$(dirname "$SSHD_CONFIG")"
        # 按平台挑选可用选项：Alpine 等无 PAM 的系统写 UsePAM 会导致 sshd 报错
        local sftp_path="/usr/lib/openssh/sftp-server"
        [ -x "/usr/lib/ssh/sftp-server" ] && sftp_path="/usr/lib/ssh/sftp-server"
        {
            echo "# 由 sshx 生成的默认配置"
            # 保留 drop-in 目录：很多发行版把关键设置放在 sshd_config.d/ 下
            if [ -d /etc/ssh/sshd_config.d ]; then
                echo "Include /etc/ssh/sshd_config.d/*.conf"
            fi
            echo "Port 22"
            echo "PermitRootLogin yes"
            echo "PasswordAuthentication yes"
            echo "PubkeyAuthentication yes"
            if [ -f /etc/pam.d/sshd ]; then
                echo "UsePAM yes"
            fi
            if [ -x "$sftp_path" ]; then
                echo "Subsystem sftp $sftp_path"
            fi
        } > "$SSHD_CONFIG"
        print_info "未找到 $SSHD_CONFIG，已生成默认配置。"
    fi

    ensure_host_keys

    local sshd_bin
    sshd_bin=$(command -v sshd 2>/dev/null)
    if [ -z "$sshd_bin" ]; then
        sshd_bin="/usr/sbin/sshd"
        [ -x "$sshd_bin" ] || { print_error "找不到 sshd 可执行文件，无法启动。"; }
    fi

    mkdir -p "$(dirname "$SSHD_PIDFILE")"
    local logfile="/var/log/sshd-start.log"
    # 让 sshd 脱离当前会话；sshd 默认自身守护化
    if command -v setsid &>/dev/null; then
        setsid "$sshd_bin" -f "$SSHD_CONFIG" -E "$logfile" </dev/null &>/dev/null &
    else
        nohup "$sshd_bin" -f "$SSHD_CONFIG" -E "$logfile" </dev/null &>/dev/null &
    fi

    local _
    for _ in 1 2 3 4 5; do
        sleep 1
        if sshd_running; then
            print_info "sshd 已在后台启动（PID: $(sshd_master_pids | tr '\n' ' ' | sed 's/ $//')）。"
            print_warn "注意：该方式不随系统启动，重启机器后需重新执行本脚本。"
            return 0
        fi
    done
    print_warn "后台启动 sshd 未成功，请检查日志（$SSHD_CONFIG 语法或端口占用）。"
    if [ -s "$logfile" ]; then
        print_warn "sshd 输出（$logfile 末尾）："
        tail -5 "$logfile" 2>/dev/null | sed 's/^/    /'
    fi
    return 1
}

# 通过 init 启动 sshd（可用时优先，保证服务受 init 管理、能开机自启）
start_sshd_via_init() {
    case "$SSHD_INIT" in
        openrc)
            rc-service "$SSHD_SERVICE" start &>/dev/null
            ;;
        systemd)
            systemctl start "$SSHD_SERVICE" &>/dev/null
            ;;
        sysv)
            if [ -x "/etc/init.d/$SSHD_SERVICE" ]; then
                /etc/init.d/"$SSHD_SERVICE" start &>/dev/null
            else
                service "$SSHD_SERVICE" start &>/dev/null
            fi
            ;;
        *)
            return 1
            ;;
    esac

    local _
    for _ in 1 2 3; do
        sleep 1
        sshd_running && return 0
    done
    return 1
}

# 重启 sshd（init 无法识别或启动失败时回退到后台启动）
restart_sshd() {
    local ok=false

    # 若进程在跑但 init 没记录（如曾被脚本后台启动过），先补登记，
    # 否则 rc-service restart 会因状态不一致而失败，进而反复回退后台启动。
    adopt_running_process

    case "$SSHD_INIT" in
        openrc)
            rc-service "$SSHD_SERVICE" restart &>/dev/null && ok=true
            ;;
        systemd)
            # socket 激活模式下，监听 socket 由 .socket 单元持有。
            # 只 restart .service 会复用同一个 socket（仍是旧端口），必须重启 .socket。
            if socket_activated; then
                systemctl restart "${SSHD_SERVICE}.socket" &>/dev/null && ok=true
            else
                systemctl restart "$SSHD_SERVICE" &>/dev/null && ok=true
            fi
            ;;
        sysv)
            if [ -x "/etc/init.d/$SSHD_SERVICE" ]; then
                /etc/init.d/"$SSHD_SERVICE" restart &>/dev/null && ok=true
            else
                service "$SSHD_SERVICE" restart &>/dev/null && ok=true
            fi
            ;;
    esac

    # init 报告成功也要确认进程真的在跑（部分 SysV 脚本会假成功）
    if [ "$ok" = true ] && sshd_running; then
        return 0
    fi
    [ "$ok" = true ] && print_warn "服务脚本报告成功，但未检测到 sshd 进程。"

    # init 可用时，restart 失败通常只是状态不一致，再给一次干净的重启机会，
    # 避免在能用 init 管理的系统上退化成"后台裸进程"。
    if [ "$SSHD_INIT" != "none" ]; then
        print_warn "重启失败，尝试停止后重新启动（由 $SSHD_INIT 管理）。"
        stop_sshd
        case "$SSHD_INIT" in
            openrc)  rc-service "$SSHD_SERVICE" start &>/dev/null ;;
            systemd) systemctl start "$SSHD_SERVICE" &>/dev/null ;;
            sysv)
                if [ -x "/etc/init.d/$SSHD_SERVICE" ]; then
                    /etc/init.d/"$SSHD_SERVICE" start &>/dev/null
                else
                    service "$SSHD_SERVICE" start &>/dev/null
                fi
                ;;
        esac
        if sshd_running; then
            print_info "已通过 $SSHD_INIT 重新启动 sshd。"
            return 0
        fi
    fi

    # 最后兜底：先停掉旧进程再后台拉起
    stop_sshd
    start_sshd_background || true
    return 0
}

# 停止 sshd（用于重装）
stop_sshd() {
    case "$SSHD_INIT" in
        openrc)  rc-service "$SSHD_SERVICE" stop &>/dev/null ;;
        systemd) systemctl stop "$SSHD_SERVICE" &>/dev/null ;;
        sysv)
            if [ -x "/etc/init.d/$SSHD_SERVICE" ]; then
                /etc/init.d/"$SSHD_SERVICE" stop &>/dev/null
            else
                service "$SSHD_SERVICE" stop &>/dev/null
            fi
            ;;
    esac

    # 无论 init 是否报告成功，都确认进程确实退出了
    if ! sshd_running; then
        return 0
    fi

    # 只结束主进程，不用 pkill -x sshd：那会连带杀掉当前登录会话
    local pids
    pids=$(sshd_master_pids)
    if [ -n "$pids" ]; then
        # shellcheck disable=SC2086
        kill $pids &>/dev/null
        sleep 1
    fi
    ! sshd_running && return 0

    # shellcheck disable=SC2086
    kill -9 $pids &>/dev/null
    sleep 1
    if sshd_running; then
        print_warn "停止服务失败，请手动停止 sshd 进程。"
        return 1
    fi
    return 0
}

# 备份配置文件（如果未备份则执行）
backup_config() {
    if [ -z "$BACKUP_FILE" ]; then
        # 配置文件可能不存在（全新机器 / 刚重装完），此时无需备份
        if [ ! -f "$SSHD_CONFIG" ]; then
            print_warn "$SSHD_CONFIG 不存在，跳过备份。"
            return 0
        fi
        BACKUP_FILE="${SSHD_CONFIG}${BACKUP_SUFFIX}"
        cp -a "$SSHD_CONFIG" "$BACKUP_FILE"
        print_info "已备份 $SSHD_CONFIG 为 $BACKUP_FILE"
    fi
}

# 获取当前配置值（从 sshd_config 提取最后一个有效值）
get_config_value() {
    local key="$1"
    local file="${2:-$SSHD_CONFIG}"
    grep -i "^[[:space:]]*${key}[[:space:]]" "$file" 2>/dev/null | tail -1 | awk '{print $2}'
}

# 设置配置项（如果键存在则替换，否则追加）
set_config() {
    local key="$1"
    local value="$2"
    local file="${3:-$SSHD_CONFIG}"
    local escaped_key
    escaped_key=$(printf '%s\n' "$key" | sed 's/[.[\*^$()+?{|]/\\&/g')

    # 配置文件不存在时先建一份，否则 grep 非零会让 set -e 直接终止脚本
    if [ ! -f "$file" ]; then
        mkdir -p "$(dirname "$file")"
        : > "$file"
    fi

    if grep -q "^[[:space:]#]*${escaped_key}[[:space:]]" "$file"; then
        sed -i "s/^[[:space:]#]*${escaped_key}[[:space:]]\+.*/$key $value/" "$file"
    else
        echo "$key $value" >> "$file"
    fi
    CONFIG_CHANGED=true
}

# 确保 sshd 的权限分离目录存在。
# 精简容器里 /run 是 tmpfs，每次启动都是空的；缺这个目录时 `sshd -t`
# 会报 "Missing privilege separation directory: /run/sshd"，旧版脚本
# 把它误判成"配置语法错误"并回滚，实际配置本身没问题。
ensure_privsep_dir() {
    if [ ! -d /run/sshd ]; then
        mkdir -p /run/sshd 2>/dev/null && chmod 0755 /run/sshd 2>/dev/null || true
    fi
}

# 测试 sshd 配置语法（保留真实报错，便于区分语法错误与环境问题）
test_config() {
    if command -v sshd &>/dev/null; then
        ensure_privsep_dir
        sshd -t -f "$SSHD_CONFIG"
    else
        return 0
    fi
}

# 应用配置（测试 + 重启）
apply_config() {
    if [ "$CONFIG_CHANGED" = false ]; then
        print_info "没有需要应用的更改。"
        return
    fi
    if test_config; then
        # socket 激活模式下，Port 不参与监听，必须同步改 socket 的 ListenStream，
        # 否则改了 Port 重启后仍在旧端口监听（Ubuntu 22.10+ 默认如此）。
        if socket_activated; then
            local want_port cur_ports
            want_port=$(config_ports | head -1)
            cur_ports=$(socket_listen_ports | tr '\n' ' ' | sed 's/ $//')
            if [ -n "$want_port" ]; then
                if [ "$cur_ports" != "$want_port" ]; then
                    print_warn "检测到 systemd socket 激活模式：监听端口由 ${SSHD_SERVICE}.socket 控制。"
                    print_info "socket 当前监听: ${cur_ports:-未知}；配置要求: $want_port"
                    if [ "$want_port" = "22" ]; then
                        # 回到 22 时移除 override，恢复发行版默认
                        local dir="/etc/systemd/system/${SSHD_SERVICE}.socket.d"
                        if [ -f "$dir/override.conf" ]; then
                            rm -f "$dir/override.conf"
                            rmdir "$dir" 2>/dev/null || true
                            systemctl daemon-reload 2>/dev/null || true
                            print_info "已移除 socket override，恢复默认监听。"
                        fi
                    else
                        write_socket_override "$want_port" || true
                    fi
                fi
            fi
        fi
        print_info "配置语法通过，正在重启 sshd ..."
        restart_sshd
        print_info "配置已应用。"
        CONFIG_CHANGED=false
        [ -n "$BACKUP_FILE" ] && rm -f "$BACKUP_FILE" && BACKUP_FILE=""
    else
        print_warn "sshd 配置校验未通过（sshd -t 的上方输出为真实原因），正在回滚..."
        if [ -n "$BACKUP_FILE" ] && [ -f "$BACKUP_FILE" ]; then
            cp -f "$BACKUP_FILE" "$SSHD_CONFIG"
            print_info "已回滚至备份版本。"
        else
            print_warn "没有可用备份，配置保持原样。"
        fi
        CONFIG_CHANGED=false
        BACKUP_FILE=""
    fi
}

# ------------------------------------------------------------
# 公钥管理函数
# ------------------------------------------------------------
list_keys() {
    local user="$1"
    local auth_file
    auth_file=$(getent passwd "$user" | cut -d: -f6)/.ssh/authorized_keys
    if [ ! -f "$auth_file" ]; then
        echo "用户 $user 没有 authorized_keys 文件。"
        return
    fi
    echo "用户 $user 的已授权公钥："
    nl -w2 -s'. ' "$auth_file"
}

add_public_key() {
    local user_key="$1"
    local user="${user_key%%:*}"
    local key="${user_key#*:}"
    if [ -z "$user" ] || [ -z "$key" ]; then
        print_error "公钥格式错误，应为 user:public_key_string"
    fi
    if ! id "$user" &>/dev/null; then
        print_error "用户 $user 不存在。"
    fi
    local home_dir
    home_dir=$(getent passwd "$user" | cut -d: -f6)
    local ssh_dir="$home_dir/.ssh"
    local auth_file="$ssh_dir/authorized_keys"
    mkdir -p "$ssh_dir"
    chown "$user":"$user" "$ssh_dir"
    chmod 700 "$ssh_dir"
    if grep -qF "$key" "$auth_file" 2>/dev/null; then
        print_warn "公钥已存在，跳过添加。"
    else
        echo "$key" >> "$auth_file"
        chown "$user":"$user" "$auth_file"
        chmod 600 "$auth_file"
        print_info "公钥已添加到 $auth_file"
    fi
}

# 从文件添加公钥（支持 "user:文件路径" 或纯文件路径，默认 root）
add_public_key_file() {
    local arg="$1"
    local user="root"
    local keyfile="$arg"
    if [ "${arg%%:*}" != "$arg" ] && id "${arg%%:*}" &>/dev/null; then
        user="${arg%%:*}"
        keyfile="${arg#*:}"
    fi
    if [ ! -f "$keyfile" ]; then
        print_error "公钥文件不存在: $keyfile"
    fi
    local key
    key=$(tr -d '\r\n' < "$keyfile")
    add_public_key "$user:$key"
}

delete_public_key() {
    local user="$1"
    local line_num="$2"
    local auth_file
    auth_file=$(getent passwd "$user" | cut -d: -f6)/.ssh/authorized_keys
    if [ ! -f "$auth_file" ]; then
        print_error "用户 $user 没有 authorized_keys 文件。"
    fi
    sed -i "${line_num}d" "$auth_file"
    print_info "已删除第 $line_num 行公钥。"
}

# ------------------------------------------------------------
# 密码管理函数
# ------------------------------------------------------------
# 交互式修改密码（调用 passwd）
change_password_interactive() {
    local user="$1"
    if ! id "$user" &>/dev/null; then
        print_error "用户 $user 不存在。"
    fi
    print_info "正在为用户 $user 修改密码（请按提示输入两次新密码）"
    passwd "$user"
    if [ $? -eq 0 ]; then
        print_info "密码修改成功！"
    else
        print_error "密码修改失败。"
    fi
}

# 随机生成密码并设置
change_password_random() {
    local user="$1"
    if ! id "$user" &>/dev/null; then
        print_error "用户 $user 不存在。"
    fi
    # 生成 16 位随机密码（包含大小写字母、数字、特殊字符）
    local password
    password=$(tr -dc 'A-Za-z0-9!@#$%^&*()_+-=' < /dev/urandom 2>/dev/null | head -c 16)
    if [ -z "$password" ]; then
        # 如果 /dev/urandom 不可用，使用 openssl 或 date 备用
        if command -v openssl &>/dev/null; then
            password=$(openssl rand -base64 12 | tr -d '\n' | cut -c1-16)
        else
            password="$(date +%s%N | sha256sum | base64 | head -c 16)"
        fi
    fi
    # 设置密码
    if command -v chpasswd &>/dev/null; then
        echo "$user:$password" | chpasswd
    elif command -v passwd &>/dev/null && passwd --help 2>&1 | grep -q -- '--stdin'; then
        echo "$password" | passwd --stdin "$user"
    else
        # 最后尝试用 printf + passwd（某些系统支持）
        printf "%s\n%s\n" "$password" "$password" | passwd "$user" 2>/dev/null
    fi
    if [ $? -eq 0 ]; then
        print_info "密码已随机生成并设置。"
        echo -e "${YELLOW}新密码（请立即保存）：${GREEN}$password${NC}"
    else
        print_error "设置随机密码失败，请尝试交互式修改。"
    fi
}

# ------------------------------------------------------------
# 重装 SSH 服务函数
# ------------------------------------------------------------
reinstall_ssh() {
    clear_screen
    print_title "重装 SSH 服务"
    echo -e "${RED}警告：此操作将停止 SSH 服务并卸载 openssh-server 软件包。${NC}"
    echo -e "${RED}如果您通过 SSH 远程连接，执行后连接将中断！${NC}"
    read -p "确认继续？(y/n): " confirm
    [[ $confirm != [yY] ]] && return

    # 1. 备份配置
    read -p "是否备份当前配置？(y/n, 默认 y): " bak_confirm
    if [[ -z "$bak_confirm" || $bak_confirm == [yY] ]]; then
        backup_config
    fi

    # 2. 停止服务
    print_info "正在停止 SSH 服务..."
    stop_sshd

    # 3. 卸载软件包
    print_info "正在卸载 $PKG_LIST ..."
    eval "$PKG_REMOVE $PKG_LIST" || print_error "卸载失败，请手动处理。"

    # 4. 询问是否彻底删除配置文件（清除）
    read -p "是否删除现有配置文件 ($SSHD_CONFIG)？(y/n, 默认 n): " clean_confirm
    if [[ $clean_confirm == [yY] ]]; then
        if [ -f "$SSHD_CONFIG" ]; then
            rm -f "$SSHD_CONFIG"
            print_info "已删除 $SSHD_CONFIG"
        fi
        # 可选删除其他可能残留（如 sshd_config.d 等），保留主要
    fi

    # 5. 重新安装
    print_info "正在重新安装 $PKG_LIST ..."
    install_ssh   # 此函数会检测是否已安装，若不存在则安装
    # 重装会带来新的 init 脚本/unit，必须重新探测，否则仍用旧结论
    detect_service

    # 6. 恢复配置（如果有备份且用户选择）
    if [ -n "$BACKUP_FILE" ] && [ -f "$BACKUP_FILE" ]; then
        read -p "是否恢复之前备份的配置文件？(y/n, 默认 n): " restore_confirm
        if [[ $restore_confirm == [yY] ]]; then
            cp -f "$BACKUP_FILE" "$SSHD_CONFIG"
            print_info "已恢复配置 $BACKUP_FILE"
            CONFIG_CHANGED=true
        else
            print_info "使用默认配置。"
            # 如果用户不恢复，但之前备份文件存在，删除备份以免干扰
            rm -f "$BACKUP_FILE"
            BACKUP_FILE=""
        fi
    else
        print_info "没有可恢复的备份，使用默认配置。"
    fi

    # 7. 重启服务
    print_info "正在重启 SSH 服务..."
    restart_sshd

    print_info "SSH 服务重装完成。"
    read -p "按回车返回菜单..."
}

# ------------------------------------------------------------
# 菜单功能
# ------------------------------------------------------------
show_current_config() {
    clear_screen
    print_title "当前 SSH 配置（有效值）"
    echo "------------------------------------------------"
    echo "Port:               $(get_config_value Port)"
    echo "Protocol:           $(get_config_value Protocol)"
    echo "AddressFamily:      $(get_config_value AddressFamily)"
    echo "ListenAddress:      $(get_config_value ListenAddress)"
    echo "PermitRootLogin:    $(get_config_value PermitRootLogin)"
    echo "PasswordAuthentication: $(get_config_value PasswordAuthentication)"
    echo "PubkeyAuthentication:   $(get_config_value PubkeyAuthentication)"
    echo "ChallengeResponseAuthentication: $(get_config_value ChallengeResponseAuthentication)"
    echo "KerberosAuthentication: $(get_config_value KerberosAuthentication)"
    echo "GSSAPIAuthentication: $(get_config_value GSSAPIAuthentication)"
    echo "PermitEmptyPasswords: $(get_config_value PermitEmptyPasswords)"
    echo "LoginGraceTime:     $(get_config_value LoginGraceTime)"
    echo "MaxAuthTries:       $(get_config_value MaxAuthTries)"
    echo "MaxSessions:        $(get_config_value MaxSessions)"
    echo "ClientAliveInterval: $(get_config_value ClientAliveInterval)"
    echo "ClientAliveCountMax: $(get_config_value ClientAliveCountMax)"
    echo "AllowUsers:         $(get_config_value AllowUsers)"
    echo "DenyUsers:          $(get_config_value DenyUsers)"
    echo "AllowGroups:        $(get_config_value AllowGroups)"
    echo "DenyGroups:         $(get_config_value DenyGroups)"
    echo "Banner:             $(get_config_value Banner)"
    echo "Subsystem:          $(get_config_value Subsystem)"
    echo "AllowTcpForwarding: $(get_config_value AllowTcpForwarding)"
    echo "PrintMotd:          $(get_config_value PrintMotd)"
    echo "PrintLastLog:       $(get_config_value PrintLastLog)"
    echo "UseDNS:             $(get_config_value UseDNS)"
    echo "------------------------------------------------"
    # socket 激活模式下，真正决定监听端口的是 .socket 而不是 Port，必须显式提示
    if socket_activated; then
        echo -e "${YELLOW}[注意] systemd socket 激活模式：实际监听端口由 ${SSHD_SERVICE}.socket 决定${NC}"
        echo "  socket 实际监听: $(socket_listen_ports | tr '\n' ' ' | sed 's/ $//')"
        echo "  （修改 Port 后执行 [9]，脚本会同步改写 socket）"
    fi
    echo "------------------------------------------------"
    read -p "按回车键返回菜单..."
}

menu_basic() {
    while true; do
        clear_screen
        print_title "基本设置"
        echo "1. 设置端口 (当前: $(get_config_value Port))"
        echo "2. 设置协议版本 (当前: $(get_config_value Protocol))"
        echo "3. 设置地址族 (当前: $(get_config_value AddressFamily))"
        echo "4. 设置监听地址 (当前: $(get_config_value ListenAddress))"
        echo "5. 返回主菜单"
        read -p "请选择 [1-5]: " choice
        case $choice in
            1) read -p "输入新端口号: " val; set_config Port "$val" ;;
            2) read -p "输入协议 (1/2/2,1): " val; set_config Protocol "$val" ;;
            3) read -p "输入地址族 (any/inet/inet6): " val; set_config AddressFamily "$val" ;;
            4) read -p "输入监听地址 (如 0.0.0.0): " val; set_config ListenAddress "$val" ;;
            5) break ;;
            *) print_warn "无效选择"; sleep 1 ;;
        esac
    done
}

menu_auth() {
    while true; do
        clear_screen
        print_title "认证设置"
        echo "1. 允许 root 登录 (当前: $(get_config_value PermitRootLogin))"
        echo "2. 密码认证 (当前: $(get_config_value PasswordAuthentication))"
        echo "3. 公钥认证 (当前: $(get_config_value PubkeyAuthentication))"
        echo "4. 质询响应认证 (当前: $(get_config_value ChallengeResponseAuthentication))"
        echo "5. Kerberos 认证 (当前: $(get_config_value KerberosAuthentication))"
        echo "6. GSSAPI 认证 (当前: $(get_config_value GSSAPIAuthentication))"
        echo "7. 允许空密码 (当前: $(get_config_value PermitEmptyPasswords))"
        echo "8. 返回主菜单"
        read -p "请选择 [1-8]: " choice
        case $choice in
            1) read -p "输入 (yes/no/prohibit-password/without-password/forced-commands-only): " val; set_config PermitRootLogin "$val" ;;
            2) read -p "输入 (yes/no): " val; set_config PasswordAuthentication "$val" ;;
            3) read -p "输入 (yes/no): " val; set_config PubkeyAuthentication "$val" ;;
            4) read -p "输入 (yes/no): " val; set_config ChallengeResponseAuthentication "$val" ;;
            5) read -p "输入 (yes/no): " val; set_config KerberosAuthentication "$val" ;;
            6) read -p "输入 (yes/no): " val; set_config GSSAPIAuthentication "$val" ;;
            7) read -p "输入 (yes/no): " val; set_config PermitEmptyPasswords "$val" ;;
            8) break ;;
            *) print_warn "无效选择"; sleep 1 ;;
        esac
    done
}

menu_access() {
    while true; do
        clear_screen
        print_title "访问控制"
        echo "1. 允许用户 (当前: $(get_config_value AllowUsers))"
        echo "2. 拒绝用户 (当前: $(get_config_value DenyUsers))"
        echo "3. 允许组 (当前: $(get_config_value AllowGroups))"
        echo "4. 拒绝组 (当前: $(get_config_value DenyGroups))"
        echo "5. 返回主菜单"
        read -p "请选择 [1-5]: " choice
        case $choice in
            1) read -p "输入允许的用户列表 (空格分隔): " val; set_config AllowUsers "$val" ;;
            2) read -p "输入拒绝的用户列表: " val; set_config DenyUsers "$val" ;;
            3) read -p "输入允许的组列表: " val; set_config AllowGroups "$val" ;;
            4) read -p "输入拒绝的组列表: " val; set_config DenyGroups "$val" ;;
            5) break ;;
            *) print_warn "无效选择"; sleep 1 ;;
        esac
    done
}

menu_other() {
    while true; do
        clear_screen
        print_title "其他选项"
        echo "1. 登录超时 (LoginGraceTime) (当前: $(get_config_value LoginGraceTime))"
        echo "2. 最大认证尝试次数 (当前: $(get_config_value MaxAuthTries))"
        echo "3. 最大会话数 (当前: $(get_config_value MaxSessions))"
        echo "4. 客户端保活间隔 (秒) (当前: $(get_config_value ClientAliveInterval))"
        echo "5. 保活失败最大次数 (当前: $(get_config_value ClientAliveCountMax))"
        echo "6. 登录 Banner 文件 (当前: $(get_config_value Banner))"
        echo "7. 子系统 (当前: $(get_config_value Subsystem))"
        echo "8. 显示 MOTD (当前: $(get_config_value PrintMotd))"
        echo "9. 显示上次登录 (当前: $(get_config_value PrintLastLog))"
        echo "10. 使用 DNS (当前: $(get_config_value UseDNS))"
        echo "11. 开启端口转发 AllowTcpForwarding (当前: $(get_config_value AllowTcpForwarding))"
        echo "12. 返回主菜单"
        read -p "请选择 [1-12]: " choice
        case $choice in
            1) read -p "输入秒数 (0 表示无限制): " val; set_config LoginGraceTime "$val" ;;
            2) read -p "输入次数: " val; set_config MaxAuthTries "$val" ;;
            3) read -p "输入会话数: " val; set_config MaxSessions "$val" ;;
            4) read -p "输入秒数 (0 禁用): " val; set_config ClientAliveInterval "$val" ;;
            5) read -p "输入次数 (0 禁用): " val; set_config ClientAliveCountMax "$val" ;;
            6) read -p "输入 Banner 文件路径: " val; set_config Banner "$val" ;;
            7) read -p "输入子系统 (如 sftp /usr/lib/openssh/sftp-server): " val; set_config Subsystem "$val" ;;
            8) read -p "输入 (yes/no): " val; set_config PrintMotd "$val" ;;
            9) read -p "输入 (yes/no): " val; set_config PrintLastLog "$val" ;;
            10) read -p "输入 (yes/no): " val; set_config UseDNS "$val" ;;
            11) read -p "输入 (yes/no, 回车默认 yes 开启): " val; [ -z "$val" ] && val="yes"; set_config AllowTcpForwarding "$val" ;;
            12) break ;;
            *) print_warn "无效选择"; sleep 1 ;;
        esac
    done
}

menu_keys() {
    while true; do
        clear_screen
        print_title "公钥管理"
        echo "1. 为某用户添加公钥（输入公钥内容）"
        echo "2. 从文件为某用户添加公钥"
        echo "3. 查看某用户的公钥列表"
        echo "4. 删除某用户的指定公钥（按行号）"
        echo "5. 返回主菜单"
        read -p "请选择 [1-5]: " choice
        case $choice in
            1)
                read -p "输入用户名: " user
                read -p "输入公钥内容: " key
                add_public_key "$user:$key"
                read -p "按回车继续..."
                ;;
            2)
                read -p "输入用户名: " user
                read -p "输入公钥文件路径: " keyfile
                if [ -f "$keyfile" ]; then
                    key=$(cat "$keyfile" | tr -d '\n')
                    add_public_key "$user:$key"
                else
                    print_error "文件不存在。"
                fi
                read -p "按回车继续..."
                ;;
            3)
                read -p "输入用户名: " user
                list_keys "$user"
                read -p "按回车继续..."
                ;;
            4)
                read -p "输入用户名: " user
                list_keys "$user"
                read -p "输入要删除的行号: " line
                delete_public_key "$user" "$line"
                read -p "按回车继续..."
                ;;
            5) break ;;
            *) print_warn "无效选择"; sleep 1 ;;
        esac
    done
}

# 密码管理菜单
menu_password() {
    while true; do
        clear_screen
        print_title "用户密码管理"
        echo "1. 交互式修改指定用户密码（手动输入）"
        echo "2. 为指定用户随机生成并设置强密码"
        echo "3. 返回主菜单"
        read -p "请选择 [1-3]: " choice
        case $choice in
            1)
                read -p "输入用户名: " user
                change_password_interactive "$user"
                read -p "按回车继续..."
                ;;
            2)
                read -p "输入用户名: " user
                change_password_random "$user"
                read -p "按回车继续..."
                ;;
            3) break ;;
            *) print_warn "无效选择"; sleep 1 ;;
        esac
    done
}

menu_backup() {
    clear_screen
    print_title "备份管理"
    backups=$(ls -t /etc/ssh/sshd_config.backup.* 2>/dev/null)
    if [ -z "$backups" ]; then
        echo "没有找到备份文件。"
        read -p "按回车返回..."
        return
    fi
    echo "可用的备份文件："
    select backup in $backups "取消"; do
        if [ "$backup" = "取消" ] || [ -z "$backup" ]; then
            break
        elif [ -n "$backup" ] && [ -f "$backup" ]; then
            read -p "确认恢复 $backup ? (y/n): " confirm
            if [[ $confirm == [yY] ]]; then
                cp -a "$backup" "$SSHD_CONFIG"
                print_info "已恢复 $backup"
                CONFIG_CHANGED=true
                apply_config
            fi
            break
        else
            echo "无效选择。"
        fi
    done
    read -p "按回车返回..."
}

main_menu() {
    while true; do
        clear_screen
        print_title "SSH 一键配置工具 - 主菜单"
        echo "1. 查看当前配置"
        echo "2. 基本设置（端口/协议/地址）"
        echo "3. 认证设置（密码/公钥/root登录）"
        echo "4. 访问控制（用户/组）"
        echo "5. 其他选项（保活/超时/DNS等）"
        echo "6. 公钥管理"
        echo "7. 用户密码管理"
        echo "8. 备份管理"
        echo "9. 应用配置并重启 SSH（测试 + 重启）"
        echo "10. 重装 SSH 服务"
        echo "11. 退出"
        echo "---------------------------------------------"
        echo -e "${YELLOW}提示：所有修改暂存于配置文件中，请执行 [9] 使生效。${NC}"
        read -p "请选择 [1-11]: " choice
        case $choice in
            1) show_current_config ;;
            2) menu_basic ;;
            3) menu_auth ;;
            4) menu_access ;;
            5) menu_other ;;
            6) menu_keys ;;
            7) menu_password ;;
            8) menu_backup ;;
            9) apply_config; read -p "按回车继续..." ;;
            10) reinstall_ssh ;;
            11)
                if [ "$CONFIG_CHANGED" = true ]; then
                    read -p "有未应用的更改，确定退出？(y/n): " confirm
                    [[ $confirm != [yY] ]] && continue
                fi
                print_info "退出。"
                exit 0
                ;;
            *) print_warn "无效选择"; sleep 1 ;;
        esac
    done
}

# ------------------------------------------------------------
# 命令行参数模式（原有功能）
# ------------------------------------------------------------
cmdline_mode() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --port) PORT="$2"; shift 2 ;;
            --protocol) PROTOCOL="$2"; shift 2 ;;
            --address-family) ADDRESS_FAMILY="$2"; shift 2 ;;
            --listen-address) LISTEN_ADDRESS="$2"; shift 2 ;;
            --permit-root) PERMIT_ROOT="$2"; shift 2 ;;
            --password-auth) PASSWORD_AUTH="$(normalize_bool "$2")"; shift 2 ;;
            --pubkey-auth) PUBKEY_AUTH="$(normalize_bool "$2")"; shift 2 ;;
            --challenge-response) CHALLENGE_RESPONSE="$(normalize_bool "$2")"; shift 2 ;;
            --kerberos-auth) KERBEROS_AUTH="$(normalize_bool "$2")"; shift 2 ;;
            --gssapi-auth) GSSAPI_AUTH="$(normalize_bool "$2")"; shift 2 ;;
            --permit-empty-passwords) PERMIT_EMPTY="$(normalize_bool "$2")"; shift 2 ;;
            --login-grace-time) LOGIN_GRACE_TIME="$2"; shift 2 ;;
            --max-auth-tries) MAX_AUTH_TRIES="$2"; shift 2 ;;
            --max-sessions) MAX_SESSIONS="$2"; shift 2 ;;
            --client-alive-interval) CLIENT_ALIVE_INTERVAL="$2"; shift 2 ;;
            --client-alive-count-max) CLIENT_ALIVE_COUNT_MAX="$2"; shift 2 ;;
            --allow-users) ALLOW_USERS="$2"; shift 2 ;;
            --deny-users) DENY_USERS="$2"; shift 2 ;;
            --allow-groups) ALLOW_GROUPS="$2"; shift 2 ;;
            --deny-groups) DENY_GROUPS="$2"; shift 2 ;;
            --banner) BANNER="$2"; shift 2 ;;
            --subsystem) SUBSYSTEM="$2"; shift 2 ;;
            --print-motd) PRINT_MOTD="$(normalize_bool "$2")"; shift 2 ;;
            --print-lastlog) PRINT_LASTLOG="$(normalize_bool "$2")"; shift 2 ;;
            --use-dns) USE_DNS="$(normalize_bool "$2")"; shift 2 ;;
            --allow-tcp-forwarding) ALLOW_TCP_FORWARDING="$(normalize_bool "$2")"; shift 2 ;;
            --add-key) ADD_KEY="$2"; shift 2 ;;
            --add-key-file) ADD_KEY_FILE="$2"; shift 2 ;;
            --help) usage; exit 0 ;;
            *) print_error "未知选项: $1" ;;
        esac
    done

    [ -n "$PORT" ] && set_config "Port" "$PORT"
    [ -n "$PROTOCOL" ] && set_config "Protocol" "$PROTOCOL"
    [ -n "$ADDRESS_FAMILY" ] && set_config "AddressFamily" "$ADDRESS_FAMILY"
    [ -n "$LISTEN_ADDRESS" ] && set_config "ListenAddress" "$LISTEN_ADDRESS"
    [ -n "$PERMIT_ROOT" ] && set_config "PermitRootLogin" "$PERMIT_ROOT"
    [ -n "$PASSWORD_AUTH" ] && set_config "PasswordAuthentication" "$PASSWORD_AUTH"
    [ -n "$PUBKEY_AUTH" ] && set_config "PubkeyAuthentication" "$PUBKEY_AUTH"
    [ -n "$CHALLENGE_RESPONSE" ] && set_config "ChallengeResponseAuthentication" "$CHALLENGE_RESPONSE"
    [ -n "$KERBEROS_AUTH" ] && set_config "KerberosAuthentication" "$KERBEROS_AUTH"
    [ -n "$GSSAPI_AUTH" ] && set_config "GSSAPIAuthentication" "$GSSAPI_AUTH"
    [ -n "$PERMIT_EMPTY" ] && set_config "PermitEmptyPasswords" "$PERMIT_EMPTY"
    [ -n "$LOGIN_GRACE_TIME" ] && set_config "LoginGraceTime" "$LOGIN_GRACE_TIME"
    [ -n "$MAX_AUTH_TRIES" ] && set_config "MaxAuthTries" "$MAX_AUTH_TRIES"
    [ -n "$MAX_SESSIONS" ] && set_config "MaxSessions" "$MAX_SESSIONS"
    [ -n "$CLIENT_ALIVE_INTERVAL" ] && set_config "ClientAliveInterval" "$CLIENT_ALIVE_INTERVAL"
    [ -n "$CLIENT_ALIVE_COUNT_MAX" ] && set_config "ClientAliveCountMax" "$CLIENT_ALIVE_COUNT_MAX"
    [ -n "$ALLOW_USERS" ] && set_config "AllowUsers" "$ALLOW_USERS"
    [ -n "$DENY_USERS" ] && set_config "DenyUsers" "$DENY_USERS"
    [ -n "$ALLOW_GROUPS" ] && set_config "AllowGroups" "$ALLOW_GROUPS"
    [ -n "$DENY_GROUPS" ] && set_config "DenyGroups" "$DENY_GROUPS"
    [ -n "$BANNER" ] && set_config "Banner" "$BANNER"
    [ -n "$SUBSYSTEM" ] && set_config "Subsystem" "$SUBSYSTEM"
    [ -n "$PRINT_MOTD" ] && set_config "PrintMotd" "$PRINT_MOTD"
    [ -n "$PRINT_LASTLOG" ] && set_config "PrintLastLog" "$PRINT_LASTLOG"
    [ -n "$USE_DNS" ] && set_config "UseDNS" "$USE_DNS"
    [ -n "$ALLOW_TCP_FORWARDING" ] && set_config "AllowTcpForwarding" "$ALLOW_TCP_FORWARDING"

    [ -n "$ADD_KEY" ] && add_public_key "$ADD_KEY"
    [ -n "$ADD_KEY_FILE" ] && add_public_key_file "$ADD_KEY_FILE"

    if [ "$CONFIG_CHANGED" = true ]; then
        if test_config; then
            print_info "配置语法通过，正在重启 sshd ..."
            restart_sshd
            print_info "命令行设置完成。"
        else
            print_warn "sshd 配置校验未通过，上方 sshd -t 的输出为真实原因，请检查后重试。"
        fi
    else
        print_info "未更改任何配置。"
    fi
}

normalize_bool() {
    case "$1" in
        yes|on|true|1) echo "yes" ;;
        no|off|false|0) echo "no" ;;
        *) echo "$1" ;;
    esac
}

usage() {
    cat <<EOF
用法: $0 [选项]                  # 命令行模式（不带参数进入交互菜单）
选项（同菜单功能）:
  --port PORT
  --protocol PROTO
  --address-family FAMILY
  --listen-address ADDR
  --permit-root VALUE
  --password-auth VALUE
  --pubkey-auth VALUE
  --challenge-response VALUE
  --kerberos-auth VALUE
  --gssapi-auth VALUE
  --permit-empty-passwords VALUE
  --login-grace-time SECONDS
  --max-auth-tries NUM
  --max-sessions NUM
  --client-alive-interval SECONDS
  --client-alive-count-max COUNT
  --allow-users "user list"
  --deny-users "user list"
  --allow-groups "group list"
  --deny-groups "group list"
  --banner FILE
  --subsystem "cmd"
  --print-motd VALUE
  --print-lastlog VALUE
  --use-dns VALUE
  --allow-tcp-forwarding VALUE
  --add-key USER:PUBKEY
  --add-key-file USER:FILE
  --help
EOF
    exit 0
}

# ------------------------------------------------------------
# 自身注册：安装为 sshx 命令，之后直接执行 sshx 即进入菜单
# ------------------------------------------------------------
is_self_script() {
    [ -f "$1" ] && grep -q 'SSH 一键配置脚本' "$1" 2>/dev/null
}

# 取到当前脚本的源码内容（支持 curl | bash 形式运行）
self_content() {
    if [ -n "${BASH_SOURCE[0]:-}" ] && is_self_script "${BASH_SOURCE[0]}"; then
        cat "${BASH_SOURCE[0]}"
        return 0
    fi
    if [ -f "$0" ] && is_self_script "$0"; then
        cat "$0"
        return 0
    fi
    if [ -n "${BASH_EXECUTION_STRING:-}" ] && printf '%s' "$BASH_EXECUTION_STRING" | grep -q 'SSH 一键配置脚本'; then
        printf '%s\n' "$BASH_EXECUTION_STRING"
        return 0
    fi
    if command -v curl &>/dev/null; then
        curl -fsSL --max-time 20 "$SELF_URL" && return 0
    elif command -v wget &>/dev/null; then
        wget -qO- --timeout=20 "$SELF_URL" && return 0
    fi
    return 1
}

# 注册 sshx 命令（已是最新则跳过）
register_self() {
    local target="$SELF_PATH"
    local bindir
    bindir=$(dirname "$target")

    if [ ! -d "$bindir" ]; then
        mkdir -p "$bindir" 2>/dev/null || { print_warn "无法创建 $bindir，跳过 sshx 命令注册。"; return 0; }
    fi
    if [ ! -w "$bindir" ]; then
        print_warn "$bindir 不可写，跳过 sshx 命令注册。"
        return 0
    fi

    # 当前就是通过 sshx 命令运行时无需重复安装
    if [ -f "$target" ] && [ -f "$0" ] && \
       [ "$(readlink -f "$0" 2>/dev/null)" = "$(readlink -f "$target" 2>/dev/null)" ]; then
        return 0
    fi

    local content
    if ! content=$(self_content); then
        print_warn "无法获取脚本内容，跳过 sshx 命令注册。"
        return 0
    fi

    # 内容一致则跳过，避免每次运行都覆盖（命令替换已去掉末尾换行，故忽略换行差异）
    if [ -f "$target" ] && [ "$(cat "$target")" = "$content" ]; then
        [ -x "$target" ] || chmod 755 "$target" 2>/dev/null || true
        return 0
    fi

    local tmp
    tmp=$(mktemp "${TMPDIR:-/tmp}/sshx.XXXXXX") || { print_warn "创建临时文件失败，跳过注册。"; return 0; }
    printf '%s\n' "$content" > "$tmp"
    if ! bash -n "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        print_warn "脚本语法检查失败，跳过 sshx 命令注册。"
        return 0
    fi
    chmod 755 "$tmp"
    # 用 mv 原子替换，避免正在运行的脚本被写坏
    if mv -f "$tmp" "$target"; then
        print_info "已注册命令：$target（直接输入 sshx 进入菜单）"
    else
        rm -f "$tmp"
        print_warn "安装到 $target 失败，请手动复制。"
    fi
    return 0
}

# ------------------------------------------------------------
# 主入口
# ------------------------------------------------------------
main() {
    if [ "$EUID" -ne 0 ]; then
        print_error "请使用 root 权限运行此脚本 (sudo $0 ...)"
    fi

    register_self

    detect_os
    install_ssh
    ensure_privsep_dir
    detect_service

    # 首次安装的机器上 sshd 通常没在跑。需要主动拉起服务的两种情况：
    #   1) 本次刚装完包（新装的服务默认不会自动跑起来）
    #   2) init 系统无法识别（只能后台启动）
    # 有 init 时优先交给 init 管理，避免产生"进程在跑但 init 认为 stopped"的割裂状态。
    if ! sshd_running; then
        if [ "$SSHD_INIT" != "none" ] && { [ "$INSTALLED_NOW" = true ] || [ "$SSHD_INIT" = "openrc" ]; }; then
            start_sshd_via_init || start_sshd_background || true
        elif [ "$INSTALLED_NOW" = true ] || [ "$SSHD_INIT" = "none" ]; then
            start_sshd_background || true
        fi
    else
        adopt_running_process
    fi

    if [ $# -eq 0 ]; then
        backup_config
        main_menu
    else
        cmdline_mode "$@"
    fi
}

main "$@"