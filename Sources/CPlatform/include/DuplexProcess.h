#ifndef CORE_DUPLEX_PROCESS_H
#define CORE_DUPLEX_PROCESS_H
#include <stdbool.h>
#include <sys/types.h>
#include <stddef.h>

// Owns a new process group. Only descriptors 0...2 survive exec.
// Success transfers nonblocking parent stdin/stdout/stderr fds to the caller.
int platform_duplex_spawn(pid_t *pid, const char *executable, char *const argv[],
                          char *const environment[], const char *directory,
                          int directory_descriptor, int descriptors[3]);
// Observe without reaping, reserving the leader's identity for group cleanup.
int platform_duplex_observe(pid_t pid, bool *exited);
// Requires the leader to remain owned and unreaped; failure leaves false.
int platform_duplex_group_quiescent(pid_t pid, bool *quiescent);
int platform_duplex_signal(pid_t pid, int signal);
ssize_t platform_duplex_write(int descriptor, const void *bytes, size_t count);
#endif
