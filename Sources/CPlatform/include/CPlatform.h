#ifndef CORE_CPLATFORM_H
#define CORE_CPLATFORM_H

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdbool.h>
#include <stdlib.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/xattr.h>
#include <sys/wait.h>
#include <unistd.h>

#if defined(__APPLE__)
#include <sys/acl.h>
#endif

int platform_flock(int descriptor, int operation);
int platform_access(int directory, const char *name, int mode);
const char *platform_entry_name(const struct dirent *entry);
bool platform_system_alias(const char *name);
int platform_exchange(int directory, const char *name, const char *destination);
int platform_sync(int descriptor);
int platform_copy_data(int source, int destination);
int platform_copy_metadata(int source, int destination, mode_t mode);
int platform_copy_link_metadata(int sourceDirectory, const char *source,
                                int destinationDirectory, const char *destination);

// Returns a POSIX error number, as posix_spawn does. The caller owns all fds.
// In the child only stdin, stdout, stderr and the specified lock survive exec.
int platform_spawn(pid_t *pid, const char *executable, char *const argv[],
                   char *const environment[], const char *directory, int lock,
                   bool inheritInput, int output, int error);

#endif
