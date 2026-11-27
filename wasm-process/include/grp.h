#ifndef ASHELL_WASI_GRP_H
#define ASHELL_WASI_GRP_H

#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

struct group {
    char *gr_name;
    gid_t gr_gid;
    char **gr_mem;
};

struct group *getgrnam(const char *);
struct group *getgrgid(gid_t);

#ifdef __cplusplus
}
#endif
#endif
