#import <Foundation/Foundation.h>
#import "ios_system/ios_system.h"
#include "herdr_pane.h"
#include <unistd.h>

// Called as a real ios_system command in the app. No modeled shell or private
// production state: this exercises the same ABI used by the original Herdr.
int parallel_probe_main(int argc, char **argv) {
    @autoreleasepool {
        NSString *directory = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
        FILE *result = fopen([[directory stringByAppendingPathComponent:@"parallel-red.txt"] fileSystemRepresentation], "w");
        if (!result) return 1;
        int a = -1, b = -1;
        void *ja = NULL, *jb = NULL;
        int first = herdr_pane_spawn("sleep 3", directory.UTF8String, 80, 24, NULL, &a, &ja);
        int second = herdr_pane_spawn("echo SECOND", directory.UTF8String, 80, 24, NULL, &b, &jb);
        fprintf(result, "first=%d second=%d expected_EBUSY=%d\n", first, second, EBUSY);
        fflush(result);
        int status = 0;
        while (ja && herdr_pane_poll(ja, &status) == 0) usleep(10000);
        if (ja) herdr_pane_release(ja);
        if (jb) herdr_pane_release(jb);
        if (a >= 0) close(a);
        if (b >= 0) close(b);
        fclose(result);
        return first == 0 && second == EBUSY ? 0 : 1;
    }
}
