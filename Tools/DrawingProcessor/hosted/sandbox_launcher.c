#define _GNU_SOURCE
#include <arpa/inet.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <grp.h>
#include <sys/mount.h>
#include <linux/audit.h>
#include <linux/capability.h>
#include <linux/filter.h>
#include <linux/io_uring.h>
#include <linux/mount.h>
#include <linux/seccomp.h>
#include <linux/sched.h>
#include <linux/unistd.h>
#include <netinet/in.h>
#include <sched.h>
#include <signal.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/ptrace.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/statfs.h>
#include <sys/statvfs.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <sys/uio.h>
#include <sys/wait.h>
#include <unistd.h>

#if !defined(__x86_64__)
#error "The hosted probe is intentionally pinned to Linux amd64."
#endif

#ifndef CLOSE_RANGE_UNSHARE
#define CLOSE_RANGE_UNSHARE (1U << 1)
#endif
#ifndef TMPFS_MAGIC
#define TMPFS_MAGIC 0x01021994
#endif

#define PROBE_SCHEMA "snaglist-drawing-sandbox-probe-v1"
#define SCRATCH_PATH "/run/snaglist-hosted-probe"
#define DEPENDENCY_PATH "/opt/snaglist-drawing"
#define SCRATCH_BYTES (512ULL * 1024ULL * 1024ULL)
#define SCRATCH_INODES 4096ULL
#define SANDBOX_UID 65532
#define OUTPUT_FD 3

struct ns_identity { dev_t dev; ino_t ino; };
struct original_namespaces {
    struct ns_identity user_ns, mount_ns, pid_ns, net_ns;
};

static void emit_unavailable(const char *stage, int error_number) {
    dprintf(STDOUT_FILENO,
            "{\"schema\":\"%s\",\"status\":\"unavailable\","
            "\"identifier\":\"drawing_sandbox_unavailable\","
            "\"stage\":\"%s\",\"errno\":%d}\n",
            PROBE_SCHEMA, stage, error_number);
}

static int write_all(int fd, const char *value) {
    size_t left = strlen(value);
    while (left) {
        ssize_t written = write(fd, value, left);
        if (written < 0) return -1;
        value += written; left -= (size_t)written;
    }
    return 0;
}

static int write_file(const char *path, const char *value) {
    int fd = open(path, O_WRONLY | O_CLOEXEC);
    if (fd < 0) return -1;
    int result = write_all(fd, value);
    int saved = errno;
    close(fd); errno = saved;
    return result;
}

static int namespace_identity(const char *name, struct ns_identity *result) {
    char path[64];
    if (snprintf(path, sizeof(path), "/proc/self/ns/%s", name) >= (int)sizeof(path)) return -1;
    struct stat value;
    if (stat(path, &value) < 0) return -1;
    result->dev = value.st_dev; result->ino = value.st_ino;
    return 0;
}

static int same_namespace(struct ns_identity a, struct ns_identity b) {
    return a.dev == b.dev && a.ino == b.ino;
}

static int prepare_user_namespace(uid_t outside_uid, gid_t outside_gid) {
    char map[80];
    if (unshare(CLONE_NEWUSER) < 0) return -1;
    if (write_file("/proc/self/setgroups", "deny\n") < 0 && errno != ENOENT) return -1;
    if (snprintf(map, sizeof(map), "0 %u 1\n", (unsigned)outside_uid) >= (int)sizeof(map) ||
        write_file("/proc/self/uid_map", map) < 0) return -1;
    if (snprintf(map, sizeof(map), "0 %u 1\n", (unsigned)outside_gid) >= (int)sizeof(map) ||
        write_file("/proc/self/gid_map", map) < 0) return -1;
    return 0;
}

static int remount_root_read_only(void) {
    if (mount(NULL, "/", NULL, MS_REC | MS_PRIVATE, NULL) < 0) return -1;
    struct mount_attr attributes = { .attr_set = MOUNT_ATTR_RDONLY };
    return (int)syscall(SYS_mount_setattr, AT_FDCWD, "/", AT_RECURSIVE,
                        &attributes, sizeof(attributes));
}

static int drop_capabilities(void) {
    if (prctl(PR_CAP_AMBIENT, PR_CAP_AMBIENT_CLEAR_ALL, 0, 0, 0) < 0 && errno != EINVAL) return -1;
    for (int capability = 0; capability <= 63; capability++) {
        if (prctl(PR_CAPBSET_DROP, capability, 0, 0, 0) < 0 && errno != EINVAL) return -1;
    }
    struct __user_cap_header_struct header = { _LINUX_CAPABILITY_VERSION_3, 0 };
    struct __user_cap_data_struct values[2] = {{0}};
    if (syscall(SYS_capset, &header, values) < 0) return -1;
    return 0;
}

#define ALLOW_SYSCALL(name) \
    BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, SYS_##name, 0, 1), \
    BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW)

static int install_probe_allowlist(void) {
    struct sock_filter filter[] = {
        BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, arch)),
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, AUDIT_ARCH_X86_64, 1, 0),
        BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_KILL_PROCESS),
        BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, nr)),
        ALLOW_SYSCALL(read), ALLOW_SYSCALL(write), ALLOW_SYSCALL(close),
        ALLOW_SYSCALL(openat), ALLOW_SYSCALL(newfstatat), ALLOW_SYSCALL(fstat),
        ALLOW_SYSCALL(statfs), ALLOW_SYSCALL(fstatfs), ALLOW_SYSCALL(fcntl),
        ALLOW_SYSCALL(getdents64), ALLOW_SYSCALL(readlink), ALLOW_SYSCALL(readlinkat),
        ALLOW_SYSCALL(lseek), ALLOW_SYSCALL(getpid), ALLOW_SYSCALL(getppid),
        ALLOW_SYSCALL(getuid), ALLOW_SYSCALL(geteuid), ALLOW_SYSCALL(getgid), ALLOW_SYSCALL(getegid),
        ALLOW_SYSCALL(clock_gettime), ALLOW_SYSCALL(rt_sigaction), ALLOW_SYSCALL(rt_sigprocmask),
        ALLOW_SYSCALL(rt_sigreturn), ALLOW_SYSCALL(brk), ALLOW_SYSCALL(mmap),
        ALLOW_SYSCALL(mprotect), ALLOW_SYSCALL(munmap), ALLOW_SYSCALL(arch_prctl),
        ALLOW_SYSCALL(set_tid_address), ALLOW_SYSCALL(set_robust_list), ALLOW_SYSCALL(futex),
#ifdef SYS_rseq
        ALLOW_SYSCALL(rseq),
#endif
        ALLOW_SYSCALL(exit), ALLOW_SYSCALL(exit_group),
        BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ERRNO | (EPERM & SECCOMP_RET_DATA)),
    };
    struct sock_fprog program = {
        .len = (unsigned short)(sizeof(filter) / sizeof(filter[0])), .filter = filter
    };
    if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) < 0) return -1;
    if (prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &program) < 0) return -1;
    return 0;
}

static int read_small_file(const char *path, char *buffer, size_t capacity) {
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return -1;
    ssize_t count = read(fd, buffer, capacity - 1);
    int saved = errno;
    close(fd); errno = saved;
    if (count < 0 || (size_t)count >= capacity - 1) return -1;
    buffer[count] = '\0';
    return 0;
}

static int status_hex_is_zero(const char *status, const char *label) {
    const char *line = strstr(status, label);
    if (!line) return 0;
    line += strlen(label);
    while (*line == ' ' || *line == '\t') line++;
    char *end = NULL;
    errno = 0;
    unsigned long long value = strtoull(line, &end, 16);
    return errno == 0 && end != line && value == 0;
}

static int status_decimal_is(const char *status, const char *label, long expected) {
    const char *line = strstr(status, label);
    if (!line) return 0;
    line += strlen(label);
    while (*line == ' ' || *line == '\t') line++;
    char *end = NULL;
    errno = 0;
    long value = strtol(line, &end, 10);
    return errno == 0 && end != line && value == expected;
}

static int namespace_map_is(const char *path, unsigned long long outside_id) {
    char contents[160];
    unsigned long long inside = 0, outside = 0, length = 0;
    char extra = '\0';
    if (read_small_file(path, contents, sizeof(contents)) < 0) return 0;
    return sscanf(contents, "%llu %llu %llu %c", &inside, &outside, &length, &extra) == 3 &&
           inside == 0 && outside == outside_id && length == 1;
}

static int only_pid_one_visible(void) {
    int fd = open("/proc", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (fd < 0) return 0;
    char buffer[4096];
    int numeric = 0;
    for (;;) {
        int count = (int)syscall(SYS_getdents64, fd, buffer, sizeof(buffer));
        if (count < 0) { close(fd); return 0; }
        if (count == 0) break;
        for (int offset = 0; offset < count;) {
            struct linux_dirent64 { uint64_t ino; int64_t off; unsigned short reclen; unsigned char type; char name[]; };
            struct linux_dirent64 *entry = (struct linux_dirent64 *)(buffer + offset);
            if (entry->reclen == 0) { close(fd); return 0; }
            int digits = entry->name[0] != '\0';
            for (const char *p = entry->name; *p; p++) if (*p < '0' || *p > '9') digits = 0;
            if (digits) {
                numeric++;
                if (strcmp(entry->name, "1") != 0) { close(fd); return 0; }
            }
            offset += (int)entry->reclen;
        }
    }
    close(fd);
    return numeric == 1;
}

static int denied(long result) { return result == -1 && errno == EPERM; }

static int run_hostile_probes(const struct original_namespaces *original, int inherited_socket_fd) {
    /* Preserve only the output capability. Every other inherited descriptor, including
       the synthetic supervisor socket and stdio, is removed before confinement tests. */
    if (inherited_socket_fd < 4 || fcntl(inherited_socket_fd, F_GETFD) < 0) return 10;
    if (syscall(SYS_close_range, 4U, ~0U, CLOSE_RANGE_UNSHARE) < 0) return 11;
    close(0); close(1); close(2);
    errno = 0;
    if (fcntl(inherited_socket_fd, F_GETFD) != -1 || errno != EBADF) return 12;

    if (clearenv() != 0 || setenv("LANG", "C.UTF-8", 1) != 0 || setenv("TZ", "UTC", 1) != 0) return 13;
    if (drop_capabilities() < 0) return 14;
    if (install_probe_allowlist() < 0) return 15;

    if (getpid() != 1 || getppid() != 0 || getuid() != 0 || getgid() != 0) return 16;
    struct ns_identity user_ns, mount_ns, pid_ns, net_ns;
    if (namespace_identity("user", &user_ns) || namespace_identity("mnt", &mount_ns) ||
        namespace_identity("pid", &pid_ns) || namespace_identity("net", &net_ns)) return 17;
    if (same_namespace(user_ns, original->user_ns) || same_namespace(mount_ns, original->mount_ns) ||
        same_namespace(pid_ns, original->pid_ns) || same_namespace(net_ns, original->net_ns)) return 18;
    if (!namespace_map_is("/proc/self/uid_map", SANDBOX_UID) ||
        !namespace_map_is("/proc/self/gid_map", SANDBOX_UID)) return 19;

    char status[8192];
    if (read_small_file("/proc/self/status", status, sizeof(status)) < 0) return 20;
    if (!status_hex_is_zero(status, "CapInh:") || !status_hex_is_zero(status, "CapPrm:") ||
        !status_hex_is_zero(status, "CapEff:") || !status_hex_is_zero(status, "CapBnd:") ||
        !status_hex_is_zero(status, "CapAmb:") || !status_decimal_is(status, "NoNewPrivs:", 1) ||
        !status_decimal_is(status, "Seccomp:", 2)) return 21;
    if (!only_pid_one_visible()) return 22;

    struct statvfs root, dependencies, scratch;
    struct statfs scratch_type;
    if (statvfs("/", &root) || statvfs(DEPENDENCY_PATH, &dependencies) ||
        statvfs(SCRATCH_PATH, &scratch) || statfs(SCRATCH_PATH, &scratch_type)) return 23;
    if (!(root.f_flag & ST_RDONLY) || !(dependencies.f_flag & ST_RDONLY)) return 24;
    if (scratch_type.f_type != TMPFS_MAGIC || (scratch.f_flag & ST_RDONLY) ||
        !(scratch.f_flag & ST_NODEV) || !(scratch.f_flag & ST_NOSUID) || !(scratch.f_flag & ST_NOEXEC)) return 25;
    unsigned long long bytes = (unsigned long long)scratch.f_blocks * scratch.f_frsize;
    if (bytes != SCRATCH_BYTES || scratch.f_files != SCRATCH_INODES) return 26;
    errno = 0;
    int root_write = open("/snaglist-hosted-probe-write", O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
    if (root_write >= 0 || errno != EROFS) { if (root_write >= 0) close(root_write); return 27; }
    errno = 0;
    int dependency_write = open(DEPENDENCY_PATH "/probe-write", O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
    if (dependency_write >= 0 || errno != EROFS) {
        if (dependency_write >= 0) close(dependency_write);
        return 28;
    }

    struct sockaddr_in address = { .sin_family = AF_INET, .sin_port = htons(53), .sin_addr.s_addr = htonl(0x7f000001) };
    errno = 0; if (!denied(syscall(SYS_socket, AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0))) return 29;
    errno = 0; if (!denied(syscall(SYS_socket, AF_INET6, SOCK_STREAM | SOCK_CLOEXEC, 0))) return 30;
    errno = 0; if (!denied(syscall(SYS_socket, AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0))) return 31;
    errno = 0; if (!denied(syscall(SYS_socket, AF_INET, SOCK_RAW | SOCK_CLOEXEC, IPPROTO_RAW))) return 32;
    errno = 0; if (!denied(syscall(SYS_connect, -1, &address, sizeof(address)))) return 33;
    errno = 0; if (!denied(syscall(SYS_sendto, -1, "x", 1, 0, &address, sizeof(address)))) return 34;
    errno = 0; if (!denied(syscall(SYS_clone, SIGCHLD, 0, 0, 0, 0))) return 35;
#ifdef SYS_clone3
    errno = 0; if (!denied(syscall(SYS_clone3, NULL, 0))) return 36;
#endif
    errno = 0; if (!denied(syscall(SYS_fork))) return 37;
    errno = 0; if (!denied(syscall(SYS_vfork))) return 38;
    errno = 0; if (!denied(syscall(SYS_ptrace, PTRACE_TRACEME, 0, 0))) return 39;
#ifdef SYS_process_vm_readv
    errno = 0; if (!denied(syscall(SYS_process_vm_readv, getpid(), NULL, 0, NULL, 0, 0))) return 40;
#endif
#ifdef SYS_pidfd_getfd
    errno = 0; if (!denied(syscall(SYS_pidfd_getfd, -1, 0, 0))) return 41;
#endif
    errno = 0; if (!denied(syscall(SYS_unshare, CLONE_NEWNS))) return 42;
    errno = 0; if (!denied(syscall(SYS_mount, "none", "/", "tmpfs", 0, NULL))) return 43;
#ifdef SYS_io_uring_setup
    errno = 0; if (!denied(syscall(SYS_io_uring_setup, 1, NULL))) return 44;
#endif
    errno = 0; if (!denied(syscall(SYS_setuid, 1))) return 45;

    int marker = openat(OUTPUT_FD, "probe-ok", O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
    if (marker < 0 || write_all(marker, "sandbox-ready-v1\n") < 0 || close(marker) < 0) return 46;
    return 0;
}

static int namespace_init(const struct original_namespaces *original, int output_fd, int inherited_socket_fd) {
    /* Overmount the inherited proc view with one bound to this PID namespace.
       If the kernel will not permit that from the new user namespace, the probe fails. */
    if (mount("proc", "/proc", "proc", MS_RDONLY | MS_NOSUID | MS_NODEV | MS_NOEXEC, "hidepid=2") < 0) return 51;
    if (output_fd != OUTPUT_FD) {
        if (dup3(output_fd, OUTPUT_FD, O_CLOEXEC) < 0) return 52;
        close(output_fd);
    }
    return run_hostile_probes(original, inherited_socket_fd);
}

static int enter_parser_namespaces(const struct original_namespaces *original, int output_fd, int inherited_socket_fd) {
    if (unshare(CLONE_NEWNS | CLONE_NEWNET | CLONE_NEWPID) < 0) return 60;
    pid_t child = fork();
    if (child < 0) return 61;
    if (child == 0) _exit(namespace_init(original, output_fd, inherited_socket_fd));
    int status = 0;
    if (waitpid(child, &status, 0) != child || !WIFEXITED(status)) return 62;
    return WEXITSTATUS(status);
}

static int validate_marker(int output_fd) {
    int fd = openat(output_fd, "probe-ok", O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return -1;
    struct stat value;
    char content[32] = {0};
    ssize_t count = read(fd, content, sizeof(content) - 1);
    int saved = errno;
    if (fstat(fd, &value) < 0) { close(fd); return -1; }
    close(fd); errno = saved;
    return count == 17 && S_ISREG(value.st_mode) && value.st_nlink == 1 &&
           strcmp(content, "sandbox-ready-v1\n") == 0 ? 0 : -1;
}

int main(int argc, char **argv) {
    if (argc != 2 || strcmp(argv[1], "--probe") != 0) {
        emit_unavailable("probe_only", EINVAL); return 64;
    }
    if (geteuid() != 0) { emit_unavailable("trusted_bootstrap_user", EPERM); return 78; }
    struct original_namespaces original;
    if (namespace_identity("user", &original.user_ns) || namespace_identity("mnt", &original.mount_ns) ||
        namespace_identity("pid", &original.pid_ns) || namespace_identity("net", &original.net_ns)) {
        emit_unavailable("namespace_inventory", errno); return 78;
    }
    /* Map namespace root to an ordinary outside account while the inherited proc
       view is still writable. The bootstrap and confined child share this user
       namespace; the child later gets separate mount, network and PID views. */
    if (setgroups(0, NULL) < 0 || setresgid(SANDBOX_UID, SANDBOX_UID, SANDBOX_UID) < 0 ||
        setresuid(SANDBOX_UID, SANDBOX_UID, SANDBOX_UID) < 0 ||
        prepare_user_namespace(SANDBOX_UID, SANDBOX_UID) < 0) {
        emit_unavailable("bootstrap_user_namespace", errno); return 78;
    }
    if (unshare(CLONE_NEWNS) < 0 || mount(NULL, "/", NULL, MS_REC | MS_PRIVATE, NULL) < 0) {
        emit_unavailable("trusted_mount_namespace", errno); return 78;
    }
    struct stat scratch_directory;
    errno = 0;
    if (lstat(SCRATCH_PATH, &scratch_directory) < 0 || !S_ISDIR(scratch_directory.st_mode) ||
        scratch_directory.st_uid != 0 || scratch_directory.st_gid != 0 ||
        (scratch_directory.st_mode & 0777) != 0700) {
        emit_unavailable("scratch_directory", errno ? errno : EACCES); return 78;
    }
    if (remount_root_read_only() < 0) { emit_unavailable("readonly_root", errno); return 78; }
    if (mount("tmpfs", SCRATCH_PATH, "tmpfs", MS_NOSUID | MS_NODEV | MS_NOEXEC,
              "size=536870912,nr_inodes=4096,mode=0700") < 0) {
        emit_unavailable("bounded_tmpfs", errno); return 78;
    }
    int output_fd = open(SCRATCH_PATH, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (output_fd < 0) { emit_unavailable("scratch_descriptor", errno); return 78; }
    int inherited[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, inherited) < 0) { emit_unavailable("inherited_fd_fixture", errno); return 78; }
    pid_t setup = fork();
    if (setup < 0) { emit_unavailable("namespace_launcher", errno); return 78; }
    if (setup == 0) {
        close(inherited[1]);
        _exit(enter_parser_namespaces(&original, output_fd, inherited[0]));
    }
    close(inherited[0]); close(inherited[1]);
    int status = 0;
    if (waitpid(setup, &status, 0) != setup || !WIFEXITED(status) || WEXITSTATUS(status) != 0 || validate_marker(output_fd) < 0) {
        int code = WIFEXITED(status) ? WEXITSTATUS(status) : 255;
        emit_unavailable("hostile_probe", code); return 78;
    }
    dprintf(STDOUT_FILENO,
        "{\"schema\":\"%s\",\"status\":\"ready\",\"scratchBytes\":%llu,"
        "\"scratchInodes\":%llu,\"checks\":["
        "\"user_namespace\",\"mount_namespace\",\"pid_namespace\",\"network_namespace\","
        "\"readonly_root\",\"readonly_dependencies\",\"bounded_tmpfs\",\"inherited_fds_closed\","
        "\"no_new_privs\",\"capabilities_zero\",\"seccomp_active\",\"network_denied\","
        "\"dns_denied\",\"process_creation_denied\",\"ptrace_denied\","
        "\"process_memory_denied\",\"pidfd_getfd_denied\",\"namespace_changes_denied\","
        "\"mount_changes_denied\",\"io_uring_denied\",\"privilege_changes_denied\"]}\n",
        PROBE_SCHEMA, SCRATCH_BYTES, SCRATCH_INODES);
    return 0;
}
