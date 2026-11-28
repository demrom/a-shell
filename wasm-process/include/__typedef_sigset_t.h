#ifndef __wasilibc___typedef_sigset_t_h
#define __wasilibc___typedef_sigset_t_h

// WASI SDK 34 uses a one-byte placeholder. Define the overlay type at the
// same SDK seam so poll.h and sys/select.h agree in either include order.
// Do not include stdint.h: a replacement can re-enter sys/select.h here.
typedef __UINT64_TYPE__ sigset_t;

#endif
