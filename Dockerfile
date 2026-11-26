# magpie 网关 + SSH + Cloudflare Tunnel 的一体镜像
#
# 基础镜像用官方 ghcr.io/yetone/magpie（Debian 13 slim，内置 magpie 二进制、
# node/npm、uv）。官方的 CMD 是 `magpie serve`，这里换成自己的 entrypoint：
#   1) sshd（用随仓库带进来的 ssh.sh 配置好，公钥在启动时写入）
#   2) cloudflared（用随仓库带进来的 tunc.sh 安装，token 在启动时从环境变量读）
#   3) magpie serve --web=...（页面和 /v1 同一个端口，orkestr 只暴露一个端口）
FROM ghcr.io/yetone/magpie:0.1.4858

USER root
ENV DEBIAN_FRONTEND=noninteractive

# openssh-server: 对外提供 SSH。orkestr 丢弃 CAP_SYS_CHROOT/SETGID/SETUID，
#   OpenSSH 9+ 在 preauth 会 chroot+setgroups 而 fatal（sshd 在监听但任何 key
#   都登不进）。用 gcc 编一个 LD_PRELOAD 垫片把这些失败降级（见 chroot-noop.c，
#   取自已验证的 alpine-box 项目）。capability 完整时行为不变。
# gcc/libc-dev: 只为构建期编译垫片
# procps: pgrep、ps
# tini: PID 1 收尸，magpie 和 cloudflared 都是子进程
# apt 加重试：orkestr 与本机都可能碰上源瞬时不可达
RUN for i in 1 2 3; do \
      apt-get update && break || sleep 3; \
    done \
 && apt-get install -y --no-install-recommends \
      openssh-server openssh-client procps tini ca-certificates curl gcc libc6-dev \
 && rm -rf /var/lib/apt/lists/* \
 && mkdir -p /run/sshd /var/log

# 特权分离兼容垫片：chroot/setgroups/setresuid 在缺 capability 时降级为成功
COPY docker/chroot-noop.c /tmp/chroot-noop.c
RUN gcc -shared -fPIC -Os -o /usr/local/lib/chroot-noop.so /tmp/chroot-noop.c -ldl \
 && chmod 0644 /usr/local/lib/chroot-noop.so \
 && rm -f /tmp/chroot-noop.c \
 && apt-get purge -y gcc libc6-dev && apt-get autoremove -y >/dev/null 2>&1 || true

COPY docker/ssh.sh /opt/glue/ssh.sh
COPY docker/tunc.sh /opt/glue/tunc.sh
COPY docker/entrypoint.sh /opt/glue/entrypoint.sh
RUN chmod 0755 /opt/glue/*.sh

# 构建期跑一遍用户给的两个脚本，把它们的配置固化进镜像：
#   ssh.sh   → sshd_config（PermitRootLogin/密码/公钥）、主机密钥、/usr/local/bin/sshx
#   tunc.sh  → 下载 cloudflared 到 /usr/local/lib/tunc/tunc、注册 `tunc` 管理器
# 容器里没有 systemd/OpenRC，两个脚本都会自动退化成「无 init，手动模式」。
RUN bash /opt/glue/ssh.sh --permit-root yes --password-auth yes --pubkey-auth yes || true
RUN bash /opt/glue/tunc.sh --no-start || true

# magpie 自己的文件（providers、gateway keys、页面 key）都落在这里
ENV HOME=/config/home \
    XDG_CONFIG_HOME=/config \
    XDG_CACHE_HOME=/config/cache \
    XDG_DATA_HOME=/config/data \
    XDG_STATE_HOME=/config/state \
    MAGPIE_ADDR=0.0.0.0:3425 \
    PORT=8080

EXPOSE 8080

ENTRYPOINT ["/usr/bin/tini", "--", "/opt/glue/entrypoint.sh"]
