#include <grp.h>
#include <pwd.h>
#include <stddef.h>

// Preview 1 exposes no guest account database. Report "not found" without
// changing errno or guessing names for numeric IDs from file metadata.
struct passwd *getpwnam(const char *name) { (void)name; return NULL; }
struct passwd *getpwuid(uid_t id) { (void)id; return NULL; }
struct group *getgrnam(const char *name) { (void)name; return NULL; }
struct group *getgrgid(gid_t id) { (void)id; return NULL; }
