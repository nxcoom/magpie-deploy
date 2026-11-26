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

# 容器里 root 的 home 与权限都由我们自己铺，StrictModes 的属主检查只会添乱
# （base 镜像 ENV HOME=/config/home 与 passwd 里的 /root 不一致时尤其容易踩）；
# 公钥路径写死，避免相对路径按 HOME 解析到别处。
mkdir -p /run/sshd /var/empty /root/.ssh
chmod 0755 /run/sshd /var/empty
chown root:root /root /root/.ssh
chmod 0700 /root /root/.ssh

# 权限分离用户：sshd 在发完 banner 后 fork 到 privsep 用户，缺了它就会在
# 认证之前直接断开（表现正是「连上、看到版本号、然后 Connection closed」）。
id sshd >/dev/null 2>&1 || useradd -r -g nogroup -d /var/empty -s /usr/sbin/nologin sshd 2>/dev/null || true

# sshd 取「第一次出现的值生效」，所以 drop-in 要在主配置的 Include 之后
# 才被读到；ssh.sh 生成的精简配置里可能没有 Include，这里补在最前面。
mkdir -p /etc/ssh/sshd_config.d
if ! grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config.d' /etc/ssh/sshd_config 2>/dev/null; then
  { echo "Include /etc/ssh/sshd_config.d/*.conf"; cat /etc/ssh/sshd_config 2>/dev/null; } > /tmp/sshd_config.new \
    && mv /tmp/sshd_config.new /etc/ssh/sshd_config
fi

cat > /etc/ssh/sshd_config.d/99-glue.conf <<'CONF'
PermitRootLogin yes
PubkeyAuthentication yes
AuthorizedKeysFile /root/.ssh/authorized_keys
StrictModes no
UsePAM no
LogLevel VERBOSE
CONF

log "starting sshd on :22"
# -D 必须加：没有它 sshd 先 fork 再返回，本进程一退出 systemd 之外的
# 容器里就跟着退；-e 让日志留在 stderr（-E 写文件也保留）。
: > /var/log/sshd.log
/usr/sbin/sshd -D -E /var/log/sshd.log &
SSHD_PID=$!
# sshd 的日志同时打到容器 stdout：认证类问题只看容器日志就能定位
( tail -F /var/log/sshd.log 2>/dev/null | sed -u 's/^/[sshd] /' ) &
sleep 2
if ! kill -0 "$SSHD_PID" 2>/dev/null; then
  log "sshd failed to start; tail:"
  tail -20 /var/log/sshd.log >&2 2>/dev/null || true
else
  log "sshd up (pid $SSHD_PID)"
  log "authorized_keys now: $(cut -d' ' -f1,3 /root/.ssh/authorized_keys 2>/dev/null | tr '\n' ' ')"
fi

# ---------------------------------------------------------------- cloudflared
if [ -n "${CF_TUNNEL_TOKEN:-}" ]; then
  log "starting cloudflared tunnel"
  if [ -x /usr/local/lib/tunc/tunc ]; then
    CF_BIN=/usr/local/lib/tunc/tunc
  elif command -v cloudflared >/dev/null 2>&1; then
    CF_BIN="$(command -v cloudflared)"
  else
    CF_BIN=""
  fi
  if [ -n "$CF_BIN" ]; then
    # 同时写文件与 stdout：容器日志里才看得到 cloudflared 报的 origin 错误
    # （隧道 ingress 由 Cloudflare 控制台托管，容器侧看不到规则，只能从
    #  dial 失败的目标端口反推）。
    TUNNEL_TOKEN="$CF_TUNNEL_TOKEN" setsid "$CF_BIN" tunnel --no-autoupdate run 2>&1 \
      | tee -a /var/log/cloudflared.log &
    log "cloudflared pid $! (log /var/log/cloudflared.log, also stdout)"
  else
    log "no cloudflared binary found; skipping tunnel"
  fi
else
  log "CF_TUNNEL_TOKEN unset; no tunnel"
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
