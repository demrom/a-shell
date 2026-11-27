#include <errno.h>
#include <grp.h>
#include <pwd.h>
#include <stdio.h>

int main(void) {
    // A Preview 1 guest has numeric IDs but no ambient user or group database.
    errno = 0;
    if (getpwuid(0) || errno || getpwnam("root") || errno) return 90;
    if (getgrgid(0) || errno || getgrnam("root") || errno) return 91;
    errno = ERANGE;
    if (getpwuid(12345) || getgrgid(12345) || errno != ERANGE) return 92;
    return puts("process-accounts-empty-ok") < 0;
}
