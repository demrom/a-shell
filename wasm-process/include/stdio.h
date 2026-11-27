#ifndef ASHELL_STDIO_H
#define ASHELL_STDIO_H

#include_next <stdio.h>

#ifdef __cplusplus
extern "C" {
#endif

FILE *popen(const char *, const char *);
int pclose(FILE *);

#ifdef __cplusplus
}
#endif

#endif
