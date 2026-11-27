#include <pthread.h>
#include <signal.h>
#include <stdint.h>

_Static_assert(sizeof(sigset_t) == sizeof(uint64_t), "signal ABI width");
