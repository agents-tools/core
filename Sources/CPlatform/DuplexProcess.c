#define _GNU_SOURCE 1
#include "CPlatform.h"
#include <spawn.h>
#include <string.h>
#if defined(__APPLE__)
#include <sys/sysctl.h>
#include <sys/proc.h>
#else
#include <dirent.h>
#include <stdio.h>
#include <time.h>
#include <linux/magic.h>
#include <sys/vfs.h>
#endif

int platform_duplex_spawn(pid_t *pid, const char *executable, char *const argv[],
                          char *const environment[], const char *directory,
                          int descriptors[3]) {
  struct sigaction childAction;
  if (sigaction(SIGCHLD, NULL, &childAction) < 0) return errno;
  if (childAction.sa_handler == SIG_IGN || (childAction.sa_flags & SA_NOCLDWAIT)) return EINVAL;
  int pipes[6] = {-1,-1,-1,-1,-1,-1};
  int result = 0;
  for (int i = 0; i < 6; i += 2) {
#if defined(__APPLE__)
    if (pipe(&pipes[i]) < 0) { result = errno; goto cleanup; }
    for (int j = i; j < i + 2; j++) {
      if (fcntl(pipes[j], F_SETFD, FD_CLOEXEC) < 0) { result = errno; goto cleanup; }
    }
#else
    if (pipe2(&pipes[i], O_CLOEXEC) < 0) { result = errno; goto cleanup; }
#endif
    for (int j = i; j < i + 2; j++) {
      if (pipes[j] < 3) {
        int replacement = fcntl(pipes[j], F_DUPFD_CLOEXEC, 3);
        if (replacement < 0) { result = errno; goto cleanup; }
        close(pipes[j]); pipes[j] = replacement;
      }
    }
  }
  posix_spawn_file_actions_t actions;
  posix_spawnattr_t attributes;
  result = posix_spawn_file_actions_init(&actions);
  if (result) goto cleanup;
  result = posix_spawnattr_init(&attributes);
  if (result) { posix_spawn_file_actions_destroy(&actions); goto cleanup; }
#define CHECK(call) do { result = (call); if (result) goto destroy; } while (0)
  short flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF;
#if defined(__APPLE__)
  flags |= POSIX_SPAWN_CLOEXEC_DEFAULT;
#endif
  sigset_t mask, defaults;
  sigemptyset(&mask); sigemptyset(&defaults);
  sigaddset(&defaults, SIGPIPE); sigaddset(&defaults, SIGTERM);
  sigaddset(&defaults, SIGINT); sigaddset(&defaults, SIGHUP);
  CHECK(posix_spawnattr_setflags(&attributes, flags));
  CHECK(posix_spawnattr_setpgroup(&attributes, 0));
  CHECK(posix_spawnattr_setsigmask(&attributes, &mask));
  CHECK(posix_spawnattr_setsigdefault(&attributes, &defaults));
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  CHECK(posix_spawn_file_actions_addchdir_np(&actions, directory));
#pragma clang diagnostic pop
  CHECK(posix_spawn_file_actions_adddup2(&actions, pipes[0], 0));
  CHECK(posix_spawn_file_actions_adddup2(&actions, pipes[3], 1));
  CHECK(posix_spawn_file_actions_adddup2(&actions, pipes[5], 2));
#if !defined(__APPLE__)
  CHECK(posix_spawn_file_actions_addclosefrom_np(&actions, 3));
#endif
  // Parent ends are nonblocking; child standard streams retain ordinary blocking I/O.
  for (int i = 0; i < 3; i++) {
    int fd = pipes[(int[]){1,2,4}[i]];
    if (fcntl(fd, F_SETFL, O_NONBLOCK) < 0) { result = errno; goto destroy; }
  }
  result = posix_spawn(pid, executable, &actions, &attributes, argv, environment);
  if (!result) {
    descriptors[0] = pipes[1]; pipes[1] = -1;
    descriptors[1] = pipes[2]; pipes[2] = -1;
    descriptors[2] = pipes[4]; pipes[4] = -1;
  }
destroy:
  posix_spawnattr_destroy(&attributes);
  posix_spawn_file_actions_destroy(&actions);
#undef CHECK
cleanup:
  for (int i = 0; i < 6; i++) if (pipes[i] >= 0) close(pipes[i]);
  return result;
}

int platform_duplex_observe(pid_t pid, bool *exited) {
  siginfo_t info;
  memset(&info, 0, sizeof(info));
  int result;
  do { result = waitid(P_PID, (id_t)pid, &info, WEXITED | WNOHANG | WNOWAIT); }
  while (result < 0 && errno == EINTR);
  if (result < 0) return errno;
  *exited = info.si_pid == pid;
  return 0;
}

ssize_t platform_duplex_write(int descriptor, const void *bytes, size_t count) {
  sigset_t blocked, previous, pending;
  sigemptyset(&blocked); sigaddset(&blocked, SIGPIPE);
  int result = pthread_sigmask(SIG_BLOCK, &blocked, &previous);
  if (result) { errno = result; return -1; }
  sigpending(&pending);
  bool wasPending = sigismember(&pending, SIGPIPE) == 1;
  ssize_t written;
  do { written = write(descriptor, bytes, count); } while (written < 0 && errno == EINTR);
  int error = errno;
  if (written < 0 && error == EPIPE && !wasPending && sigismember(&previous, SIGPIPE) != 1) {
    sigpending(&pending);
    if (sigismember(&pending, SIGPIPE) == 1) { int signal; sigwait(&blocked, &signal); }
  }
  pthread_sigmask(SIG_SETMASK, &previous, NULL);
  errno = error;
  return written;
}

#if !defined(__APPLE__)
static int duplex_proc_scan_budget(const struct timespec *start) {
  struct timespec now;
  if (clock_gettime(CLOCK_MONOTONIC, &now) < 0) return errno;
  if ((now.tv_sec - start->tv_sec) * 1000000000LL + now.tv_nsec - start->tv_nsec >= 20000000)
    return EAGAIN;
  return 0;
}

// Require a complete bounded kernel record; a short read is not an EOF proof.
static int duplex_proc_read_record(int fd, char *record, size_t capacity,
                                   const struct timespec *start) {
  size_t used = 0;
  for (;;) {
    int result = duplex_proc_scan_budget(start);
    if (result) return result;
    ssize_t count = read(fd, record + used, capacity - 1 - used);
    if (count < 0) return errno;
    if (count == 0) {
      if (used == 0) return EINVAL;
      record[used] = 0;
      return 0;
    }
    used += (size_t)count;
    if (used == capacity - 1) return EOVERFLOW;
  }
}

// mountinfo escapes whitespace in paths; its post-separator options are tokens.
static int duplex_proc_mount_options(char *line, unsigned long long mountID) {
  char *end;
  errno = 0;
  unsigned long long identifier = strtoull(line, &end, 10);
  if (errno || end == line || *end != ' ') return EINVAL;
  if (identifier != mountID) return ENOENT;
  char *separator = strstr(end, " - ");
  char type[32], source[256], options[4096], extra;
  if (!separator || sscanf(separator + 3, "%31s %255s %4095s %c", type, source, options, &extra) != 3)
    return EINVAL;
  if (strcmp(type, "proc") != 0) return ENOTSUP;
  char *saved = NULL;
  for (char *option = strtok_r(options, ",", &saved); option; option = strtok_r(NULL, ",", &saved)) {
    if (strncmp(option, "hidepid", 7) == 0 && strcmp(option, "hidepid=0") != 0) return ENOTSUP;
  }
  return 0;
}

static int duplex_proc_complete_view(int proc, const struct timespec *start) {
  struct statfs filesystem;
  if (fstatfs(proc, &filesystem) < 0) return errno;
  if (filesystem.f_type != PROC_SUPER_MAGIC) return ENOTSUP;
  // fdinfo identifies this open proc root, including bind mounts/overmounts.
  char path[64], descriptorInfo[1024];
  int length = snprintf(path, sizeof(path), "self/fdinfo/%d", proc);
  if (length < 0 || (size_t)length >= sizeof(path)) return EOVERFLOW;
  int fd = openat(proc, path, O_RDONLY | O_CLOEXEC);
  if (fd < 0) return errno;
  int error = duplex_proc_read_record(fd, descriptorInfo, sizeof(descriptorInfo), start);
  close(fd);
  if (error) return error;
  unsigned long long mountID = 0;
  char *saved = NULL;
  for (char *line = strtok_r(descriptorInfo, "\n", &saved); line; line = strtok_r(NULL, "\n", &saved)) {
    if (strncmp(line, "mnt_id:", 7) == 0) {
      char extra;
      if (sscanf(line, "mnt_id: %llu %c", &mountID, &extra) != 1) return EINVAL;
      break;
    }
  }
  if (mountID == 0) return ENOTSUP;
  fd = openat(proc, "self/mountinfo", O_RDONLY | O_CLOEXEC);
  if (fd < 0) return errno;
  char line[8192], chunk[4096];
  size_t used = 0, total = 0;
  int result = ENOTSUP;
  for (;;) {
    result = duplex_proc_scan_budget(start);
    if (result) break;
    ssize_t count = read(fd, chunk, sizeof(chunk));
    if (count < 0) { result = errno; break; }
    if (count == 0) { result = ENOTSUP; break; }
    if ((size_t)count > 1024 * 1024 - total) { result = EOVERFLOW; break; }
    total += (size_t)count;
    for (ssize_t i = 0; i < count; i++) {
      if (chunk[i] == '\n') {
        line[used] = 0;
        result = duplex_proc_mount_options(line, mountID);
        if (result != ENOENT) goto complete;
        used = 0;
      } else {
        if (used == sizeof(line) - 1) { result = EOVERFLOW; goto complete; }
        line[used++] = chunk[i];
      }
    }
  }
complete:
  close(fd);
  return result;
}

static int duplex_proc_state(char *stat, char *state, long *group, long *threads) {
  // comm may contain spaces and ')'; the final ')' ends that field.
  char *fields = strrchr(stat, ')');
  if (!fields) return EINVAL;
  char *saved = NULL;
  char *field = strtok_r(fields + 1, " \n", &saved);
  for (int index = 0; index <= 17; index++, field = strtok_r(NULL, " \n", &saved)) {
    if (!field) return EINVAL;
    if (index == 0) {
      if (strlen(field) != 1) return EINVAL;
      *state = field[0];
    } else if (index == 2 || index == 17) {
      char *end;
      errno = 0;
      long number = strtol(field, &end, 10);
      if (errno || end == field || *end != 0 || (index == 17 ? number <= 0 : number < 0)) return EINVAL;
      if (index == 2) *group = number; else *threads = number;
    }
  }
  return 0;
}
#endif

int platform_duplex_group_quiescent(pid_t pid, bool *quiescent) {
  *quiescent = false;
#if defined(__APPLE__)
  // Zombie-only groups need no signal. Inspect only this reserved group;
  // an all-zombie group cannot fork.
  int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PGRP, pid};
  size_t size = 0;
  if (sysctl(mib, 4, NULL, &size, NULL, 0) < 0) return errno;
  if (size > 1024 * 1024) return EOVERFLOW; // Bounded cleanup inspection bytes.
  if (size == 0) { *quiescent = true; return 0; }
  struct kinfo_proc *members = malloc(size);
  if (!members) return ENOMEM;
  int result = sysctl(mib, 4, members, &size, NULL, 0);
  int error = errno;
  bool live = false;
  if (result == 0) {
    for (size_t i = 0; i < size / sizeof(*members); i++) {
      if (members[i].kp_proc.p_stat != SZOMB) { live = true; break; }
    }
  }
  free(members);
  if (result < 0) return error;
  *quiescent = !live;
  return 0;
#else
  // /proc is a runtime prerequisite. Bound both scan work and elapsed inspection;
  // an unreadable or incomplete snapshot cannot establish group quiescence.
  DIR *processes = opendir("/proc");
  if (!processes) return errno;
  struct timespec start;
  if (clock_gettime(CLOCK_MONOTONIC, &start) < 0) {
    int error = errno; closedir(processes); return error;
  }
  int result = duplex_proc_complete_view(dirfd(processes), &start);
  if (result) { closedir(processes); return result; }
  bool leaderSeen = false;
  size_t entries = 0;
  for (;;) {
    if (++entries > 65536) { result = EOVERFLOW; break; }
    result = duplex_proc_scan_budget(&start);
    if (result) break;
    errno = 0;
    struct dirent *entry = readdir(processes);
    if (!entry) {
      result = errno;
      if (!result && !leaderSeen) result = ESRCH;
      if (!result) *quiescent = true;
      break;
    }
    if (!entry->d_name[0] || strspn(entry->d_name, "0123456789") != strlen(entry->d_name)) continue;
    char path[sizeof(entry->d_name) + 6];
    int length = snprintf(path, sizeof(path), "%s/stat", entry->d_name);
    if (length < 0 || (size_t)length >= sizeof(path)) { result = EOVERFLOW; break; }
    int fd = openat(dirfd(processes), path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) { result = errno; break; }
    char stat[4096];
    result = duplex_proc_read_record(fd, stat, sizeof(stat), &start);
    close(fd);
    if (result) break;
    char state;
    long group, threads;
    result = duplex_proc_state(stat, &state, &group, &threads);
    if (result) break;
    if (group != pid) continue;
    if (strtol(entry->d_name, NULL, 10) == pid) leaderSeen = true;
    // A zombie main thread can still have live workers after pthread_exit.
    // num_threads includes the leader: exactly one zombie task proves no worker.
    if (state != 'Z' || threads != 1) break;
  }
  closedir(processes);
  return result;
#endif
}

int platform_duplex_signal(pid_t pid, int signal) {
#if defined(__APPLE__)
  bool quiescent = false;
  int result = platform_duplex_group_quiescent(pid, &quiescent);
  if (result || quiescent) return result;
#endif
  if (kill(-pid, signal) == 0 || errno == ESRCH) return 0;
  return errno;
}
