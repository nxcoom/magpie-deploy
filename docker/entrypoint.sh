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

# cloudflared 的隧道要连本机 22：sshd 必须监听所有地址
if [ -f /etc/ssh/sshd_config ]; then
  grep -qE '^[[:space:]]*Port[[:space:]]+22' /etc/ssh/sshd_config || echo "Port 22" >> /etc/ssh/sshd_config
  grep -qE '^[[:space:]]*ListenAddress[[:space:]]+0\.0\.0\.0' /etc/ssh/sshd_config || echo "ListenAddress 0.0.0.0" >> /etc/ssh/sshd_config
  # 隧道进来的是「外部」连接，root 登录与公钥都必须放开
  sed -i -E 's/^[#[:space:]]*PermitRootLogin[[:space:]].*/PermitRootLogin yes/' /etc/ssh/sshd_config
  grep -qE '^[[:space:]]*PermitRootLogin' /etc/ssh/sshd_config || echo "PermitRootLogin yes" >> /etc/ssh/sshd_config
  grep -qE '^[[:space:]]*UsePAM[[:space:]]+no' /etc/ssh/sshd_config || echo "UsePAM no" >> /etc/ssh/sshd_config
fi

# 容器里 root 的 home 与权限都由我们自己铺；OpenSSH 的 StrictModes 属主检查
# 只会添乱（base 镜像 ENV HOME=/config/home 与 passwd 里的 /root 不一致）。
mkdir -p /run/sshd /var/empty /root/.ssh
chmod 0755 /run/sshd /var/empty
chown root:root /root /root/.ssh
chmod 0700 /root /root/.ssh

# ---------------------------------------------------------------- SSH 服务端
# 用 dropbear，不用 OpenSSH：OpenSSH 9+ 的权限分离在认证前必须
# chroot("/run/sshd")，而 orkestr 的容器没有 CAP_SYS_CHROOT，连接会停在
# 「拿到 banner 之后立刻 Connection closed」。ChrootDirectory none 和
# UsePrivilegeSeparation no 都不生效（后者在 8.x 起已废弃）。
# dropbear 不做 chroot，同样支持 authorized_keys 与 root 登录。
mkdir -p /etc/dropbear
DBHOST=/etc/dropbear/dropbear_ed25519_host_key
[ -f "$DBHOST" ] || dropbearkey -t ed25519 -f "$DBHOST" >/dev/null 2>&1 || true

# dropbear 只读 ~/.ssh/authorized_keys（或 -A 指定的文件）；root 的 home 是 /root
mkdir -p /root/.ssh && chmod 700 /root/.ssh
touch /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys

# 容器同样没有 CAP_SETGID。dropbear 认证成功后会 setgid(passwd 里 root 的 gid)，
# 若那个 gid(0) 与进程实际 gid 不同就需要该能力，EPERM 后直接 dropbear_exit：
#   日志  Exit (root) from <…>: Error changing user group
#   客户端 handshake failed: EOF
# 把 passwd/group 里 root 的 gid 改成运行时真实 gid，setgid 就成为无操作。
RUN_GID=$(id -g 2>/dev/null || echo 0)
log "identity: uid=$(id -u) gid=${RUN_GID} user=$(id -un)"
if [ "$RUN_GID" != "0" ]; then
  # root 的 passwd 行 gid 对齐到真实 gid
  sed -i -E "s#^root:x:0:0:#root:x:0:${RUN_GID}:#" /etc/passwd
  # 该 gid 必须在 group 里有个名字，否则 initgroups 找不到组也会 EPERM
  if ! getent group "$RUN_GID" >/dev/null 2>&1; then
    echo "containerroot:x:${RUN_GID}:root" >> /etc/group
  fi
  log "root gid realigned to ${RUN_GID} ($(getent group "$RUN_GID" | cut -d: -f1))"
fi

log "starting dropbear on :22"
# -F 前台、-E 日志到 stderr、-s 只允许公钥认证、-r 主机密钥、-p 监听地址。
# 注意别加 -w：dropbear 的 -w 是「禁止 root 登录」，会直接以
# "root login rejected" 拒掉（不是「不写 wtmp」）。
# -E 让 dropbear 把认证/会话错误写到 stderr（日志里才看得到
# "Error changing user group" 这类真因）。
/usr/sbin/dropbear -F -E -s -r "$DBHOST" -p 0.0.0.0:22 \
    -P /run/dropbear.pid 2>&1 | sed -u 's/^/[dropbear] /' &
sleep 2
if pgrep -x dropbear >/dev/null 2>&1; then
  log "dropbear up (pid $(pgrep -x dropbear | tr '\n' ' '))"
  # 打印完整指纹，方便和客户端 ssh-keygen -lf 对照
  log "authorized_keys fingerprints: $(ssh-keygen -lf /root/.ssh/authorized_keys 2>/dev/null | cut -d' ' -f2 | tr '\n' ' ')"
else
  log "dropbear failed to start"
fi
# OpenSSH 的 sshd 不在这里启动（见上面的 dropbear）：两者不能同时监听 22，
# 而 sshd 在无 CAP_SYS_CHROOT 的容器里认证前就会挂。这里只保留 ssh.sh 配好
# 的 sshd_config 供 `sshx` 菜单查看/改，实际服务端是 dropbear。
log "openssh sshd intentionally not started (dropbear serves :22)"

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
