#define _GNU_SOURCE 1
#include "CPlatform.h"

#include <stdio.h>
#include <string.h>
#include <spawn.h>

#if defined(__APPLE__)
#include <copyfile.h>
#else
#include <sys/syscall.h>
#endif

int platform_flock(int descriptor, int operation) {
  return flock(descriptor, operation);
}

int platform_access(int directory, const char *name, int mode) {
  return faccessat(directory, name, mode, AT_EACCESS);
}

const char *platform_entry_name(const struct dirent *entry) {
  return entry->d_name;
}

bool platform_system_alias(const char *name) {
#if defined(__APPLE__)
  return strcmp(name, "var") == 0 || strcmp(name, "tmp") == 0 || strcmp(name, "etc") == 0;
#else
  (void)name;
  return false;
#endif
}

int platform_exchange(int directory, const char *name, const char *destination) {
#if defined(__APPLE__)
  return renameatx_np(directory, name, directory, destination, RENAME_SWAP);
#else
  // Call the kernel primitive without relying on the libc Swift overlay.
  return (int)syscall(SYS_renameat2, directory, name, directory, destination, 2 /* RENAME_EXCHANGE */);
#endif
}

int platform_rename_exclusive(int directory, const char *name, const char *destination) {
#if defined(__APPLE__)
  return renameatx_np(directory, name, directory, destination, RENAME_EXCL);
#else
  return (int)syscall(SYS_renameat2, directory, name, directory, destination, 1 /* RENAME_NOREPLACE */);
#endif
}

bool platform_same_generation(const struct stat *first, const struct stat *second) {
#if defined(__APPLE__)
#define MTIME st_mtimespec
#define CTIME st_ctimespec
#else
#define MTIME st_mtim
#define CTIME st_ctim
#endif
  return first->st_dev == second->st_dev && first->st_ino == second->st_ino &&
    first->st_mode == second->st_mode && first->st_size == second->st_size &&
    first->MTIME.tv_sec == second->MTIME.tv_sec && first->MTIME.tv_nsec == second->MTIME.tv_nsec &&
    first->CTIME.tv_sec == second->CTIME.tv_sec && first->CTIME.tv_nsec == second->CTIME.tv_nsec;
#undef MTIME
#undef CTIME
}

int platform_sync(int descriptor) {
  int result;
  do { result = fsync(descriptor); } while (result < 0 && errno == EINTR);
#if defined(__APPLE__)
  if (result == 0) {
    do { result = fcntl(descriptor, F_FULLFSYNC); } while (result < 0 && errno == EINTR);
  }
#endif
  return result;
}

int platform_copy_data(int source, int destination) {
#if defined(__APPLE__)
  return fcopyfile(source, destination, NULL, COPYFILE_DATA);
#else
  char buffer[65536];
  for (;;) {
    ssize_t count;
    do { count = read(source, buffer, sizeof(buffer)); } while (count < 0 && errno == EINTR);
    if (count < 0) return -1;
    if (count == 0) return 0;
    ssize_t offset = 0;
    while (offset < count) {
      ssize_t written = write(destination, buffer + offset, (size_t)(count - offset));
      if (written < 0 && errno == EINTR) continue;
      if (written <= 0) {
        if (written == 0) errno = EIO;
        return -1;
      }
      offset += written;
    }
  }
#endif
}

#if !defined(__APPLE__)
// POSIX ACLs are Linux system.posix_acl_* xattrs. Copy them along with all other
// attributes, without requiring libacl or an external executable.
static int copy_xattrs(int source, int destination, const char *sourceLink,
                       const char *destinationLink) {
  ssize_t size = sourceLink ? llistxattr(sourceLink, NULL, 0) : flistxattr(source, NULL, 0);
  if (size < 0) return errno == ENOTSUP ? 0 : -1;
  char *names = malloc(size ? (size_t)size : 1);
  if (!names) { errno = ENOMEM; return -1; }
  ssize_t count = sourceLink ? llistxattr(sourceLink, names, (size_t)size)
                             : flistxattr(source, names, (size_t)size);
  if (count < 0 || count > size) {
    if (count > size) errno = ERANGE;
    free(names);
    return -1;
  }
  // A new entry may inherit a default ACL from its parent. Remove destination
  // attributes absent from the source before restoring the source's metadata.
  ssize_t targetSize = destinationLink ? llistxattr(destinationLink, NULL, 0)
                                       : flistxattr(destination, NULL, 0);
  if (targetSize < 0) { free(names); return -1; }
  char *targetNames = malloc(targetSize ? (size_t)targetSize : 1);
  if (!targetNames) { free(names); errno = ENOMEM; return -1; }
  ssize_t targetCount = destinationLink ? llistxattr(destinationLink, targetNames, (size_t)targetSize)
                                        : flistxattr(destination, targetNames, (size_t)targetSize);
  if (targetCount < 0 || targetCount > targetSize) {
    if (targetCount > targetSize) errno = ERANGE;
    free(targetNames);
    free(names);
    return -1;
  }
  int result = 0;
  for (ssize_t offset = 0; offset < targetCount;) {
    const char *name = targetNames + offset;
    offset += (ssize_t)strlen(name) + 1;
    bool found = false;
    for (ssize_t i = 0; i < count; i += (ssize_t)strlen(names + i) + 1) {
      if (strcmp(name, names + i) == 0) { found = true; break; }
    }
    if (!found) {
      result = destinationLink ? lremovexattr(destinationLink, name)
                                : fremovexattr(destination, name);
      if (result < 0) break;
    }
  }
  free(targetNames);
  if (result < 0) { free(names); return -1; }
  // Setting an access ACL may make the destination read-only. Install it only
  // after every other xattr, while the staging file still has owner write access.
  for (int pass = 0; pass < 2 && result == 0; ++pass) {
    for (ssize_t offset = 0; offset < count;) {
      const char *name = names + offset;
      offset += (ssize_t)strlen(name) + 1;
      bool accessACL = strcmp(name, "system.posix_acl_access") == 0;
      if (accessACL != (pass == 1)) continue;
      ssize_t length = sourceLink ? lgetxattr(sourceLink, name, NULL, 0)
                                  : fgetxattr(source, name, NULL, 0);
      if (length < 0) { result = -1; break; }
      void *value = malloc(length ? (size_t)length : 1);
      if (!value) { errno = ENOMEM; result = -1; break; }
      ssize_t readCount = sourceLink ? lgetxattr(sourceLink, name, value, (size_t)length)
                                     : fgetxattr(source, name, value, (size_t)length);
      if (readCount < 0 || readCount > length) {
        if (readCount > length) errno = ERANGE;
        free(value);
        result = -1;
        break;
      }
      result = destinationLink ? lsetxattr(destinationLink, name, value, (size_t)readCount, 0)
                                : fsetxattr(destination, name, value, (size_t)readCount, 0);
      free(value);
      if (result < 0) break;
    }
  }
  int error = errno;
  free(names);
  errno = error;
  return result;
}
#endif

int platform_copy_metadata(int source, int destination, mode_t mode) {
#if defined(__APPLE__)
  if (fcopyfile(source, destination, NULL, COPYFILE_METADATA) < 0) return -1;
#else
  struct stat info;
  if (fstat(source, &info) < 0) return -1;
  // Inherited default ACLs can restrict even a freshly created staging entry.
  if (fchmod(destination, S_ISDIR(mode) ? 0700 : 0600) < 0) return -1;
  if (copy_xattrs(source, destination, NULL, NULL) < 0) return -1;
  const struct timespec times[2] = {info.st_atim, info.st_mtim};
  if (futimens(destination, times) < 0) return -1;
#endif
  if (fchmod(destination, mode & 07777) < 0) return -1;
  return platform_sync(destination);
}

int platform_copy_link_metadata(int sourceDirectory, const char *source,
                                int destinationDirectory, const char *destination) {
#if defined(__APPLE__)
  int origin = openat(sourceDirectory, source, O_RDONLY | O_SYMLINK | O_CLOEXEC);
  if (origin < 0) return -1;
  int target = openat(destinationDirectory, destination, O_RDONLY | O_SYMLINK | O_CLOEXEC);
  int result = -1;
  struct stat info;
  if (target >= 0 && fstat(origin, &info) == 0) {
    result = platform_copy_metadata(origin, target, info.st_mode);
  }
  int error = errno;
  close(origin);
  if (target >= 0) close(target);
  errno = error;
  return result;
#else
  // /proc/self/fd keeps both parent paths anchored to the pinned descriptors;
  // l*xattr and AT_SYMLINK_NOFOLLOW operate on the links, never their targets.
  char origin[64 + NAME_MAX], target[64 + NAME_MAX];
  int n = snprintf(origin, sizeof(origin), "/proc/self/fd/%d/%s", sourceDirectory, source);
  int m = snprintf(target, sizeof(target), "/proc/self/fd/%d/%s", destinationDirectory, destination);
  if (n < 0 || m < 0 || (size_t)n >= sizeof(origin) || (size_t)m >= sizeof(target)) {
    errno = ENAMETOOLONG;
    return -1;
  }
  struct stat info;
  if (fstatat(sourceDirectory, source, &info, AT_SYMLINK_NOFOLLOW) < 0) return -1;
  if (!S_ISLNK(info.st_mode)) { errno = EINVAL; return -1; }
  if (copy_xattrs(-1, -1, origin, target) < 0) return -1;
  const struct timespec times[2] = {info.st_atim, info.st_mtim};
  return utimensat(destinationDirectory, destination, times, AT_SYMLINK_NOFOLLOW);
#endif
}

int platform_spawn(pid_t *pid, const char *executable, char *const argv[],
                   char *const environment[], const char *directory, int lock,
                   bool inheritInput, int output, int error) {
  posix_spawn_file_actions_t actions;
  posix_spawnattr_t attributes;
  int result = posix_spawn_file_actions_init(&actions);
  if (result != 0) return result;
  result = posix_spawnattr_init(&attributes);
  if (result != 0) { posix_spawn_file_actions_destroy(&actions); return result; }
#define CHECK(call) do { result = (call); if (result != 0) goto done; } while (0)
#if defined(__APPLE__)
  CHECK(posix_spawnattr_setflags(&attributes, POSIX_SPAWN_CLOEXEC_DEFAULT));
  if (inheritInput) CHECK(posix_spawn_file_actions_addinherit_np(&actions, STDIN_FILENO));
#else
  if (inheritInput) CHECK(posix_spawn_file_actions_adddup2(&actions, STDIN_FILENO, STDIN_FILENO));
#endif
  if (!inheritInput) {
    CHECK(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0));
  }
  // The _np spelling is required on macOS 15 and glibc 2.34.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  if (directory) CHECK(posix_spawn_file_actions_addchdir_np(&actions, directory));
#pragma clang diagnostic pop
  CHECK(posix_spawn_file_actions_adddup2(&actions, output, STDOUT_FILENO));
  CHECK(posix_spawn_file_actions_adddup2(&actions, error, STDERR_FILENO));
#if defined(__APPLE__)
  CHECK(posix_spawn_file_actions_addinherit_np(&actions, lock));
#else
  // All sources have been duplicated above fd 2 by the caller. Install the lock
  // last at fd 3, then close everything higher without enumerating a racy fd list.
  CHECK(posix_spawn_file_actions_adddup2(&actions, lock, 3));
  CHECK(posix_spawn_file_actions_addclosefrom_np(&actions, 4));
#endif
  result = posix_spawn(pid, executable, &actions, &attributes, argv, environment);
done:
  posix_spawnattr_destroy(&attributes);
  posix_spawn_file_actions_destroy(&actions);
#undef CHECK
  return result;
}
