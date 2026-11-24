#ifndef CORE_CPLATFORM_H
#define CORE_CPLATFORM_H

#include "DuplexProcess.h"

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
void platform_raise_open_file_limit(void);
int platform_access(int directory, const char *name, int mode);
const char *platform_entry_name(const struct dirent *entry);
bool platform_system_alias(const char *name);
int platform_exchange(int sourceDirectory, const char *name, int destinationDirectory, const char *destination);
int platform_rename_exclusive(int sourceDirectory, const char *name, int destinationDirectory, const char *destination);
bool platform_same_generation(const struct stat *first, const struct stat *second);
int platform_sync(int descriptor);
int platform_copy_data(int source, int destination);
int platform_copy_metadata(int source, int destination, mode_t mode);
int platform_copy_link_metadata(int sourceDirectory, const char *source,
                                int destinationDirectory, const char *destination);

// ACL bytes are descriptor-derived, ordered, and platform-specific: Darwin's
// external ACL representation or Linux's POSIX ACL xattr format. No names or
// directory-service lookups participate in capture or evaluation.
enum {
  PLATFORM_ACCESS_OWNER_DENIED = 1,
  PLATFORM_ACCESS_EXTERNAL_READ = 2,
  PLATFORM_ACCESS_EXTERNAL_WRITE = 4,
  PLATFORM_ACCESS_EXTERNAL_SEARCH = 8,
  PLATFORM_ACCESS_EXTERNAL_CONTROL = 16
};
struct platform_file_access {
  struct stat info;
  void *acl;
  size_t acl_size;
  void *default_acl;
  size_t default_acl_size;
  unsigned int assessment;
};
// Failure never changes the object. Success owns allocations released by dispose.
int platform_read_file_access(int descriptor, struct platform_file_access *result);
void platform_dispose_file_access(struct platform_file_access *value);

// Returns a POSIX error number, as posix_spawn does. The caller owns all fds.
// In the child only stdin, stdout, stderr and the specified lock survive exec.
int platform_spawn(pid_t *pid, const char *executable, char *const argv[],
                   char *const environment[], const char *directory, int lock,
                   bool inheritInput, int output, int error);

#endif
