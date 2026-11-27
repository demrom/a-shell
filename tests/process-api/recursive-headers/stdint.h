// Model a replacement stdint.h whose transitive headers need sigset_t.
#include <__typedef_sigset_t.h>
extern sigset_t sigset_include_probe;
#include_next <stdint.h>
