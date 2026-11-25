#include <cerrno>
#include <clocale>
#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <exception>
#include <ostream>
#include <pthread.h>
#include <streambuf>

#include "CoinError.hpp"

extern "C" {
FILE *ios_stdin();
FILE *ios_stdout();
FILE *ios_stderr();
[[noreturn]] void ios_exit(int status);
}

extern "C" int cbc_ios_printf(const char *format, ...)
{
    va_list args;
    va_start(args, format);
    int result = vfprintf(ios_stdout(), format, args);
    va_end(args);
    return result;
}

extern "C" int cbc_ios_puts(const char *line)
{
    return fprintf(ios_stdout(), "%s\n", line);
}

extern "C" void cbc_ios_perror(const char *prefix)
{
    int code = errno;
    fprintf(ios_stderr(), "%s%s%s\n", prefix ? prefix : "", prefix && *prefix ? ": " : "", strerror(code));
    errno = code;
}

extern "C" [[noreturn]] void cbc_ios_abort()
{
    fputs("cbc: solver aborted\n", ios_stderr());
    ios_exit(1);
}

namespace {
class FileOutput : public std::streambuf {
public:
    explicit FileOutput(FILE *(*file)()) : file_(file) {}

private:
    std::streamsize xsputn(const char *bytes, std::streamsize count) override
    {
        return fwrite(bytes, 1, count, file_());
    }

    int_type overflow(int_type byte) override
    {
        if (traits_type::eq_int_type(byte, traits_type::eof())) return traits_type::not_eof(byte);
        return fputc(traits_type::to_char_type(byte), file_()) == EOF ? traits_type::eof() : byte;
    }

    int sync() override { return fflush(file_()); }
    FILE *(*file_)();
};

pthread_mutex_t solverLock = PTHREAD_MUTEX_INITIALIZER;

struct CommandLocale {
    locale_t current;
    locale_t previous;
};
}

std::ostream &cbc_ios_cout()
{
    thread_local FileOutput buffer(ios_stdout);
    thread_local std::ostream stream(&buffer);
    return stream;
}

std::ostream &cbc_ios_cerr()
{
    thread_local FileOutput buffer(ios_stderr);
    thread_local std::ostream stream(&buffer);
    return stream;
}

int cbc_cli_main(int argc, const char **argv);
void cbc_ios_reset_parser();
extern FILE *CbcOrClpReadCommand;

static void finishCommand(void *context)
{
    if (CbcOrClpReadCommand && CbcOrClpReadCommand != ios_stdin()) fclose(CbcOrClpReadCommand);
    CbcOrClpReadCommand = nullptr;
    auto &locale = *static_cast<CommandLocale *>(context);
    uselocale(locale.previous);
    freelocale(locale.current);
    pthread_mutex_unlock(&solverLock);
}

int main(int argc, char **argv)
{
    CommandLocale locale{newlocale(LC_ALL_MASK, "C", nullptr), nullptr};
    if (!locale.current) {
        cbc_ios_perror("cbc: newlocale");
        return 1;
    }
    locale.previous = uselocale(locale.current);
    // The upstream CLI has mutable solver and parser globals. Serialize only
    // CBC commands, and release the lock on normal return and ios_exit.
    pthread_mutex_lock(&solverLock);
    int status = 1;
    pthread_cleanup_push(finishCommand, &locale);
    cbc_ios_reset_parser();
    CbcOrClpReadCommand = ios_stdin();
    try {
        status = cbc_cli_main(argc, const_cast<const char **>(argv));
    } catch (const CoinError &error) {
        fprintf(ios_stderr(), "cbc: %s\n", error.message().c_str());
    } catch (const std::exception &error) {
        fprintf(ios_stderr(), "cbc: %s\n", error.what());
    }
    pthread_cleanup_pop(1);
    return status;
}
