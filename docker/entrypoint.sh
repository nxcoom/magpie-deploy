#!/bin/bash
# 容器入口：sshd + cloudflared + magpie 三个进程一起跑。
#
# 环境变量：
#   SSH_AUTHORIZED_KEY   启动时写进 /root/.ssh/authorized_keys 的公钥（可多行/多个）
#   SSH_ROOT_PASSWORD    可选，root 密码（不给就只用公钥）
#   CF_TUNNEL_TOKEN      cloudflared tunnel token；不给就不起隧道
#   MAGPIE_WEB_KEY       页面访问 key（不给则每次启动随机生成，日志里打出来）
#   MAGPIE_PORT          对外端口，默认 8080（orkestr 的资源端口）
#   MAGPIE_GATEWAY_KEY   可选，启动时若还没有 gateway key 就建一个并打印出来
set -u

log() { printf '[entrypoint] %s\n' "$*" >&2; }

PORT="${MAGPIE_PORT:-8080}"

# ---------------------------------------------------------------- sshd
mkdir -p /run/sshd /root/.ssh
chmod 700 /root/.ssh

if [ -n "${SSH_AUTHORIZED_KEY:-}" ]; then
  : > /root/.ssh/authorized_keys
  printf '%s\n' "$SSH_AUTHORIZED_KEY" | sed '/^[[:space:]]*$/d' >> /root/.ssh/authorized_keys
  chmod 600 /root/.ssh/authorized_keys
  log "authorized_keys: $(grep -c . /root/.ssh/authorized_keys) key(s)"
fi

if [ -n "${SSH_ROOT_PASSWORD:-}" ]; then
  echo "root:${SSH_ROOT_PASSWORD}" | chpasswd
  log "root password set"
fi

# 公钥文件不存在时 sshd 会拒绝带 AuthorizedKeysFile 的配置；确保它存在
touch /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys

# 主机密钥：镜像构建时可能已生成，容器若换了 rootfs 就再生成一遍
ssh-keygen -A >/dev/null 2>&1 || true

# 端口/监听地址只在 drop-in (99-glue.conf) 里声明一次。主配置里若也有
# Port/ListenAddress，sshd 会逐条 bind，第一条成功后其余全报
# "Address already in use"。所以这里把主配置里的都注释掉。
if [ -f /etc/ssh/sshd_config ]; then
  sed -i -E 's/^[[:space:]]*(Port[[:space:]]|ListenAddress[[:space:]])/#\1/' /etc/ssh/sshd_config
fi

# 容器里 root 的 home 与权限都由我们自己铺；OpenSSH 的 StrictModes 属主检查
# 只会添乱（base 镜像 ENV HOME=/config/home 与 passwd 里的 /root 不一致）。
mkdir -p /run/sshd /var/empty /root/.ssh
chmod 0755 /run/sshd /var/empty
chown root:root /root /root/.ssh
chmod 0700 /root /root/.ssh

# ---------------------------------------------------------------- SSH 服务端
# 用 OpenSSH + 特权分离垫片。orkestr 丢弃 CAP_SYS_CHROOT/SETGID/SETUID，
# OpenSSH 9+ 在 preauth 阶段会 chroot("/run/sshd") 并 setgroups/setresuid，
# 任一失败就 fatal，表现为「拿到 banner 后立刻断开 / 认证成功后 Error
# changing user group」。chroot-noop.so 把这些 EPERM 降级为成功（capability
# 完整时行为不变）。这套取自 alpine-box 项目，已在其上验证过。
CHROOT_SHIM=/usr/local/lib/chroot-noop.so
SSHD=/usr/sbin/sshd

mkdir -p /root/.ssh && chmod 700 /root/.ssh
touch /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys

# ssh.sh 建的精简配置补上服务端必要项
mkdir -p /etc/ssh/sshd_config.d
if [ -f /etc/ssh/sshd_config ]; then
  grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config.d' /etc/ssh/sshd_config || {
    { echo "Include /etc/ssh/sshd_config.d/*.conf"; cat /etc/ssh/sshd_config; } > /tmp/sc.new \
      && mv /tmp/sc.new /etc/ssh/sshd_config
  }
fi
cat > /etc/ssh/sshd_config.d/99-glue.conf <<'CONF'
Port 22
ListenAddress 0.0.0.0
PermitRootLogin yes
PubkeyAuthentication yes
PasswordAuthentication no
AuthorizedKeysFile /root/.ssh/authorized_keys
UsePAM no
StrictModes no
LogLevel VERBOSE
CONF

log "identity: uid=$(id -u) gid=$(id -g) user=$(id -un)"
if [ -f "$CHROOT_SHIM" ]; then
  log "sshd 启用特权分离兼容垫片 ($CHROOT_SHIM)"
else
  log "WARNING: $CHROOT_SHIM 缺失，无 capability 的平台上 SSH 会登不进"
fi

log "starting sshd on :22"
# -D 前台（无 init 的容器里必须），-e 日志到 stderr
LD_PRELOAD="$CHROOT_SHIM" "$SSHD" -D -e 2>&1 | sed -u 's/^/[sshd] /' &
sleep 2
if pgrep -x sshd >/dev/null 2>&1; then
  log "sshd up (pid $(pgrep -x sshd | tr '\n' ' '))"
  log "authorized_keys fingerprints: $(ssh-keygen -lf /root/.ssh/authorized_keys 2>/dev/null | cut -d' ' -f2 | tr '\n' ' ')"
else
  log "sshd failed to start; config check:"
  LD_PRELOAD="$CHROOT_SHIM" "$SSHD" -t 2>&1 | sed -u 's/^/[sshd-t] /' || true
fi

# ---------------------------------------------------------------- cloudflared
# 支持多条隧道：CF_TUNNEL_TOKEN 是主 token，CF_TUNNEL_TOKEN_2..5 各跑一条。
# 每条隧道的 ingress 由 Cloudflare 控制台托管，容器侧看不到规则。
if [ -x /usr/local/lib/tunc/tunc ]; then
  CF_BIN=/usr/local/lib/tunc/tunc
elif command -v cloudflared >/dev/null 2>&1; then
  CF_BIN="$(command -v cloudflared)"
else
  CF_BIN=""
fi

if [ -z "$CF_BIN" ]; then
  log "no cloudflared binary found; skipping tunnels"
else
  started=0
  for n in "" _2 _3 _4 _5; do
    var="CF_TUNNEL_TOKEN${n}"
    eval "tok=\${$var:-}"
    [ -n "$tok" ] || continue
    # 同时写文件与 stdout：容器日志里才看得到 cloudflared 报的 origin 错误
    TUNNEL_TOKEN="$tok" setsid "$CF_BIN" tunnel --no-autoupdate run 2>&1 \
      | sed -u "s/^/[tunnel${n}] /" &
    log "tunnel${n:- (primary)} started, pid $!"
    started=$((started + 1))
  done
  [ "$started" -gt 0 ] || log "CF_TUNNEL_TOKEN unset; no tunnel"
fi

# ---------------------------------------------------------------- magpie
export MAGPIE_ADDR="${MAGPIE_ADDR:-0.0.0.0:3425}"
if [ -z "${MAGPIE_WEB_KEY:-}" ]; then
  MAGPIE_WEB_KEY="$(openssl rand -hex 16)"
fi
export MAGPIE_WEB_KEY

# gateway key 在网关起来之后补：/config 上可能还有滚动更新留下的旧 pod
# 握着锁，启动期直接 add 会静默失败（第一次部署就踩到了）。所以放到后台，
# 等网关应答后再试，结果写进日志而不是吞掉。
ensure_gateway_key() {
  [ -n "${MAGPIE_GATEWAY_KEY:-}" ] || return 0
  for _ in $(seq 1 60); do
    if magpie healthcheck --addr "$MAGPIE_ADDR" >/dev/null 2>&1; then
      if magpie gateway-key list 2>/dev/null | grep -q ' orkestr '; then
        log "gateway key orkestr already present"
        return 0
      fi
      # magpie 拒绝以 sk-magpie- 开头的自有 key（那是它自己生成的形状）
      if out=$(magpie gateway-key add orkestr --key "$MAGPIE_GATEWAY_KEY" 2>&1); then
        log "gateway key orkestr created"
      else
        log "gateway key add failed: $out"
      fi
      return 0
    fi
    sleep 2
  done
  log "gateway key: gateway never answered at $MAGPIE_ADDR"
}
ensure_gateway_key &

log "magpie gateway on $MAGPIE_ADDR, page on 0.0.0.0:$PORT"
log "page link: https://<your-domain>/?k=$MAGPIE_WEB_KEY"

exec magpie serve --web="0.0.0.0:${PORT}"
