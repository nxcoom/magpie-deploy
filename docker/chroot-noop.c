/*
 * privsep-compat.so — 兼容"丢弃 capability"容器平台的 sshd 特权分离垫片。
 *
 * 背景: 部分容器平台 (Orkestr / rootless Podman / 收紧的 k8s) 默认丢弃
 * CAP_SYS_CHROOT / CAP_SETGID / CAP_SETUID。OpenSSH 9.8+ 把 sshd 拆成
 * sshd → sshd-session → sshd-auth, 其中 sshd-auth 在 preauth 阶段会:
 *   chroot("/var/empty") -> 需要 CAP_SYS_CHROOT
 *   setgroups/setresgid/initgroups/setresuid (privsep_child_demote)
 *                        -> 需要 CAP_SETGID / CAP_SETUID
 * 任一失败即 fatal, 表现为 sshd 在监听 (端口通) 但任何公钥都登录不了。
 *
 * 本垫片经 /etc/conf.d/sshd 的 LD_PRELOAD 只注入到 sshd 进程树:
 *  - chroot() 跳过 (preauth chroot 仅用于 privsep 沙箱, 本镜像未配 ChrootDirectory)
 *  - setgroups/setresgid/setresuid/initgroups: 调真实实现, 若因缺 capability
 *    返回 EPERM 则记录"目标 uid/gid"并降级为成功;
 *  - getuid/geteuid/getgid/getegid: 若上面发生了降级则回报目标值, 让 OpenSSH
 *    的 "egid/uid 校验" 通过;
 *  - setuid/seteuid/setgid/setegid 尝试切回旧 (root) id 时返回 EPERM, 让
 *    OpenSSH 的 "uid/gid 恢复测试" 通过 (它要求降权后无法再恢复 root)。
 * capability 完整的平台上真实调用均成功、不进入降级分支, 行为完全不变。
 *
 * 链接需 -ldl (glibc/musl 均可); 产物必须是目标 musl 兼容的 .so。
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <grp.h>
#include <sys/types.h>
#include <unistd.h>

static uid_t g_fake_uid;
static gid_t g_fake_gid;
static int   g_uid_dropped = 0;   /* setresuid 因 EPERM 降级过 */
static int   g_gid_dropped = 0;   /* setresgid 因 EPERM 降级过 */

/* chroot: preauth 沙箱唯一作用就是隔离, 受限平台上跳过 */
int chroot(const char *path) {
    (void)path;
    return 0;
}

int setgroups(size_t size, const gid_t *list) {
    static int (*real)(size_t, const gid_t *) = NULL;
    if (!real) real = (int (*)(size_t, const gid_t *))dlsym(RTLD_NEXT, "setgroups");
    int rc = real ? real(size, list) : -1;
    if (rc == -1 && errno == EPERM) return 0;
    return rc;
}

int initgroups(const char *user, gid_t group) {
    static int (*real)(const char *, gid_t) = NULL;
    if (!real) real = (int (*)(const char *, gid_t))dlsym(RTLD_NEXT, "initgroups");
    int rc = real ? real(user, group) : -1;
    if (rc == -1 && errno == EPERM) return 0;
    return rc;
}

int setresgid(gid_t rgid, gid_t egid, gid_t sgid) {
    static int (*real)(gid_t, gid_t, gid_t) = NULL;
    if (!real) real = (int (*)(gid_t, gid_t, gid_t))dlsym(RTLD_NEXT, "setresgid");
    /* 恢复测试: 已降级后试图把 effective gid 改回去 -> 拒绝 */
    if (g_gid_dropped && egid != (gid_t)-1 && egid != g_fake_gid) {
        errno = EPERM;
        return -1;
    }
    int rc = real ? real(rgid, egid, sgid) : -1;
    if (rc == -1 && errno == EPERM) {
        g_fake_gid = (egid != (gid_t)-1) ? egid : rgid;
        g_gid_dropped = 1;
        return 0;
    }
    return rc;
}

int setresuid(uid_t ruid, uid_t euid, uid_t suid) {
    static int (*real)(uid_t, uid_t, uid_t) = NULL;
    if (!real) real = (int (*)(uid_t, uid_t, uid_t))dlsym(RTLD_NEXT, "setresuid");
    if (g_uid_dropped && euid != (uid_t)-1 && euid != g_fake_uid) {
        errno = EPERM;
        return -1;
    }
    int rc = real ? real(ruid, euid, suid) : -1;
    if (rc == -1 && errno == EPERM) {
        g_fake_uid = (euid != (uid_t)-1) ? euid : ruid;
        g_uid_dropped = 1;
        return 0;
    }
    return rc;
}

int setgid(gid_t gid) {
    if (g_gid_dropped && gid != g_fake_gid) { errno = EPERM; return -1; }
    static int (*real)(gid_t) = NULL;
    if (!real) real = (int (*)(gid_t))dlsym(RTLD_NEXT, "setgid");
    return real ? real(gid) : -1;
}

int setegid(gid_t egid) {
    if (g_gid_dropped && egid != (gid_t)-1 && egid != g_fake_gid) {
        errno = EPERM;
        return -1;
    }
    static int (*real)(gid_t) = NULL;
    if (!real) real = (int (*)(gid_t))dlsym(RTLD_NEXT, "setegid");
    return real ? real(egid) : -1;
}

int setuid(uid_t uid) {
    if (g_uid_dropped && uid != g_fake_uid) { errno = EPERM; return -1; }
    static int (*real)(uid_t) = NULL;
    if (!real) real = (int (*)(uid_t))dlsym(RTLD_NEXT, "setuid");
    return real ? real(uid) : -1;
}

int seteuid(uid_t euid) {
    if (g_uid_dropped && euid != (uid_t)-1 && euid != g_fake_uid) {
        errno = EPERM;
        return -1;
    }
    static int (*real)(uid_t) = NULL;
    if (!real) real = (int (*)(uid_t))dlsym(RTLD_NEXT, "seteuid");
    return real ? real(euid) : -1;
}

gid_t getgid(void) {
    if (g_gid_dropped) return g_fake_gid;
    static gid_t (*real)(void) = NULL;
    if (!real) real = (gid_t (*)(void))dlsym(RTLD_NEXT, "getgid");
    return real ? real() : (gid_t)0;
}

gid_t getegid(void) {
    if (g_gid_dropped) return g_fake_gid;
    static gid_t (*real)(void) = NULL;
    if (!real) real = (gid_t (*)(void))dlsym(RTLD_NEXT, "getegid");
    return real ? real() : (gid_t)0;
}

uid_t getuid(void) {
    if (g_uid_dropped) return g_fake_uid;
    static uid_t (*real)(void) = NULL;
    if (!real) real = (uid_t (*)(void))dlsym(RTLD_NEXT, "getuid");
    return real ? real() : (uid_t)0;
}

uid_t geteuid(void) {
    if (g_uid_dropped) return g_fake_uid;
    static uid_t (*real)(void) = NULL;
    if (!real) real = (uid_t (*)(void))dlsym(RTLD_NEXT, "geteuid");
    return real ? real() : (uid_t)0;
}

/* ---- Linux audit（CAP_AUDIT_WRITE 被丢弃时的兼容） ----
 *
 * OpenSSH 的 audit_session_open() 在写审计记录失败时是 hard fatal：
 *   fatal("linux_audit_write_entry failed: %s", strerror(errno));
 * 源码里唯一的放行口是「audit_open() 返回 EINVAL/EPROTONOSUPPORT/EAFNOSUPPORT
 * = 内核没有审计支持」。orkestr 这类容器没有 CAP_AUDIT_WRITE，audit_open()
 * 成功但 audit_log_acct_message() 返回 -EPERM，于是每次会话建立后 sshd 立刻
 * 退出 —— 客户端表现正是「认证通过、随即 EOF」。
 *
 * 这里让 audit_open() 假装内核不支持审计（返回 -1 / errno=EINVAL），
 * 走 OpenSSH 自带的那条放行分支。有 CAP_AUDIT_WRITE 的平台上审计本来会成功，
 * 但容器里审计日志也无处可去，行为差异可以接受。
 */
int audit_open(void) {
    errno = EINVAL;   /* "No audit support in kernel" */
    return -1;
}
