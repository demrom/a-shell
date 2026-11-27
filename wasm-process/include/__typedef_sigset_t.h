#ifndef __wasilibc___typedef_sigset_t_h
#define __wasilibc___typedef_sigset_t_h

// WASI SDK 34 uses a one-byte placeholder. Define the overlay type at the
// same SDK seam so poll.h and sys/select.h agree in either include order.
#include <stdint.h>
typedef uint64_t sigset_t;

#endif
