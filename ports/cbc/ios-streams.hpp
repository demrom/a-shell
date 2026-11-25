#pragma once

// Rebind only the COIN-OR translation units. On Mach-O the asm names include
// the leading underscore. -fno-builtin prevents Clang bypassing these aliases.
#pragma redefine_extname printf _cbc_ios_printf
#pragma redefine_extname puts _cbc_ios_puts
#pragma redefine_extname perror _cbc_ios_perror
#pragma redefine_extname getenv _ios_getenv
#pragma redefine_extname exit _ios_exit
#pragma redefine_extname abort _cbc_ios_abort

#include <cstdio>
#include <cstdlib>
#include <iostream>

extern "C" FILE *ios_stdin();
extern "C" FILE *ios_stdout();
extern "C" FILE *ios_stderr();

#undef stdin
#undef stdout
#undef stderr
#define stdin (ios_stdin())
#define stdout (ios_stdout())
#define stderr (ios_stderr())

// The solver writes diagnostics using both std::cout and C stdio. Introduce
// the accessors for qualified and unqualified uses after loading <iostream>.
std::ostream &cbc_ios_cout();
std::ostream &cbc_ios_cerr();
namespace std {
using ::cbc_ios_cout;
using ::cbc_ios_cerr;
}
#define cout cbc_ios_cout()
#define cerr cbc_ios_cerr()
