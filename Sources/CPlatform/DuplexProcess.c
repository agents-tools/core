#define _GNU_SOURCE 1
#include "CPlatform.h"
#include <spawn.h>
#include <string.h>
#if defined(__APPLE__)
#include <sys/sysctl.h>
#include <sys/proc.h>
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

int platform_duplex_signal(pid_t pid, int signal) {
#if defined(__APPLE__)
  // Zombie-only groups need no signal. Inspect only this reserved group;
  // an all-zombie group cannot fork.
  int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PGRP, pid};
  size_t size = 0;
  if (sysctl(mib, 4, NULL, &size, NULL, 0) < 0) return errno;
  if (size > 1024 * 1024) return EOVERFLOW; // Bounded cleanup inspection bytes.
  if (size == 0) return 0;
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
  if (!live) return 0;
#endif
  if (kill(-pid, signal) == 0 || errno == ESRCH) return 0;
  return errno;
}
