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

log "starting sshd on :22"
/usr/sbin/sshd -E /var/log/sshd.log
sleep 1
if ! pgrep -x sshd >/dev/null 2>&1; then
  log "sshd failed to start; tail:"
  tail -20 /var/log/sshd.log >&2 2>/dev/null || true
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
    TUNNEL_TOKEN="$CF_TUNNEL_TOKEN" setsid "$CF_BIN" tunnel --no-autoupdate run \
      >>/var/log/cloudflared.log 2>&1 &
    log "cloudflared pid $! (log /var/log/cloudflared.log)"
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

if [ -n "${MAGPIE_GATEWAY_KEY:-}" ]; then
  # 已有同名 key 时会报错，忽略即可
  magpie gateway-key add orkestr --key "$MAGPIE_GATEWAY_KEY" >/dev/null 2>&1 || true
fi

log "magpie gateway on $MAGPIE_ADDR, page on 0.0.0.0:$PORT"
log "page link: https://<your-domain>/?k=$MAGPIE_WEB_KEY"

exec magpie serve --web="0.0.0.0:${PORT}"
