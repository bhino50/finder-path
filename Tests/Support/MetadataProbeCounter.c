// Test-only DYLD interposer. Loaded with DYLD_INSERT_LIBRARIES, it counts
// filesystem metadata calls whose path contains kMarker so a test can prove
// that code running on the main actor never touches a saved folder path.
// The counter is exported for dlsym(RTLD_DEFAULT, ...) so a test run without
// the interposer fails instead of passing vacuously.
#include <stdatomic.h>
#include <string.h>
#include <sys/attr.h>
#include <sys/stat.h>
#include <unistd.h>

#define INTERPOSE(replacement, original) \
    __attribute__((used)) static const struct { const void *r; const void *o; } \
    interpose_##original __attribute__((section("__DATA,__interpose"))) = { \
        (const void *)&replacement, (const void *)&original \
    };

static const char kMarker[] = "FinderPathNoStatProbe";
static _Atomic long probeCount = 0;

static void note(const char *path) {
    if (path != NULL && strstr(path, kMarker) != NULL) {
        atomic_fetch_add(&probeCount, 1);
    }
}

__attribute__((visibility("default"))) long fp_metadata_probe_count(void) {
    return atomic_load(&probeCount);
}

static int counted_stat(const char *path, struct stat *buffer) {
    note(path);
    return stat(path, buffer);
}

static int counted_lstat(const char *path, struct stat *buffer) {
    note(path);
    return lstat(path, buffer);
}

static int counted_fstatat(int fd, const char *path, struct stat *buffer, int flags) {
    note(path);
    return fstatat(fd, path, buffer, flags);
}

static int counted_getattrlist(const char *path, void *list, void *buffer, size_t size, unsigned int options) {
    note(path);
    return getattrlist(path, list, buffer, size, options);
}

static int counted_getattrlistat(int fd, const char *path, void *list, void *buffer, size_t size,
                                 unsigned long options) {
    note(path);
    return getattrlistat(fd, path, list, buffer, size, options);
}

static int counted_access(const char *path, int mode) {
    note(path);
    return access(path, mode);
}

INTERPOSE(counted_stat, stat)
INTERPOSE(counted_lstat, lstat)
INTERPOSE(counted_fstatat, fstatat)
INTERPOSE(counted_getattrlist, getattrlist)
INTERPOSE(counted_getattrlistat, getattrlistat)
INTERPOSE(counted_access, access)
