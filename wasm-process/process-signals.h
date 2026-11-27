#ifndef ASHELL_PROCESS_SIGNALS_H
#define ASHELL_PROCESS_SIGNALS_H

#include <stdint.h>

// Optional: process.c links without the guest signal layer. signals.c can
// also link alone for programs that only need a guest-local alarm.
typedef int32_t (*ashell_wait_function)(int32_t, uint32_t, int32_t *);
__attribute__((weak)) void ashell_signal_watch_child(int32_t, int32_t, ashell_wait_function);

#endif
