/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-app-test: run an app on a headless window server and drive it.
 * Starts finch-windowserver, launches the app's executable with the
 * server's socket, waits for its windows (the window list), posts input
 * at points relative to a window, and reports what the app printed and
 * what the screen shows. Finch-only; compare with the expected output.
 *
 *   finch-app-test SERVER APP-EXECUTABLE STEP...
 *
 * Steps (points; window-relative ones are from the top left of the named
 * window, title bar included):
 *   wait:N            wait N milliseconds
 *   window:TITLE      wait for a window titled TITLE and make it the current one
 *   click:X,Y         click at X,Y in the current window
 *   type:TEXT         type TEXT (ASCII)
 *   key:CODE,CHAR     press a key (macOS virtual key code, character as a number)
 *   cmd:CHAR          press Command-CHAR
 *   sample:X,Y,LABEL  print the screen's colour at X,Y in the current window
 *   windows           print the window list (titles and sizes)
 *   screenshot:PATH   save the screen as a PNG
 *   output            print what the app has written since the last time
 */
#include <CoreGraphics/CoreGraphics.h>
#include <ImageIO/ImageIO.h>
#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>
#include "../WindowServer/FinchWSProtocol.h"

extern char **environ;
bool FWSConnect(void);
void FWSPostEvent(const FWSEvent *e);
void FWSSetCursorVisible(bool v);
CGImageRef FWSCopyScreenImage(void);
FWSWindowInfo *FWSCopyWindowList(uint32_t *count);

static int app_out = -1;
static FWSRect current;
static double scale = 2;

static void
post(uint32_t type, double x, double y, uint16_t ch, uint32_t code, uint64_t mods)
{
    FWSEvent e;
    memset(&e, 0, sizeof e);
    e.type = type;
    e.screen_x = x, e.screen_y = y;
    e.key_code = code;
    e.modifiers = mods;
    if (ch) {
        e.characters[0] = e.unmodified[0] = ch;
        e.length = 1;
    }
    FWSPostEvent(&e);
    usleep(20000);
}

static void
key(uint16_t ch, uint32_t code, uint64_t mods)
{
    post(FWS_EVENT_KEY_DOWN, 0, 0, ch, code, mods);
    post(FWS_EVENT_KEY_UP, 0, 0, ch, code, mods);
}

static bool
find_window(const char *title, int ms)
{
    for (int waited = 0; waited <= ms; waited += 50) {
        uint32_t n = 0;
        FWSWindowInfo *list = FWSCopyWindowList(&n);
        for (uint32_t i = 0; i < n; i++) {
            if (list[i].on_screen && !strcmp(list[i].title, title)) {
                current = list[i].frame;
                free(list);
                return true;
            }
        }
        free(list);
        usleep(50000);
    }
    return false;
}

static void
drain_output(bool print)
{
    char buf[4096];
    ssize_t n;
    while ((n = read(app_out, buf, sizeof buf)) > 0)
        if (print)
            fwrite(buf, 1, (size_t)n, stdout);
}

int
main(int argc, char **argv)
{
    if (argc < 3) {
        fprintf(stderr, "usage: %s SERVER APP-EXECUTABLE STEP...\n", argv[0]);
        return 2;
    }
    setvbuf(stdout, NULL, _IOLBF, 0);
    char sock[64];
    snprintf(sock, sizeof sock, "/tmp/finch-app-test.%d", getpid());
    setenv(FWS_SOCKET_ENV, sock, 1);
    pid_t server, app;
    char *sargs[] = {argv[1], "--headless", "--size", "1024x768", "--scale", "2", NULL};
    if (posix_spawn(&server, argv[1], NULL, NULL, sargs, environ)) {
        printf("can't start %s\n", argv[1]);
        return 1;
    }
    for (int i = 0; i < 100 && !FWSConnect(); i++)
        usleep(20000);
    FWSSetCursorVisible(false);
    int pipefd[2];
    pipe(pipefd);
    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_adddup2(&fa, pipefd[1], 1);
    posix_spawn_file_actions_adddup2(&fa, pipefd[1], 2);
    char *aargs[] = {argv[2], NULL};
    if (posix_spawn(&app, argv[2], &fa, NULL, aargs, environ)) {
        printf("can't start %s\n", argv[2]);
        kill(server, SIGTERM);
        return 1;
    }
    close(pipefd[1]);
    app_out = pipefd[0];
    fcntl(app_out, F_SETFL, O_NONBLOCK);

    for (int i = 3; i < argc; i++) {
        const char *s = argv[i];
        double x, y;
        int n, c;
        char label[64];
        if (sscanf(s, "wait:%d", &n) == 1) {
            usleep((useconds_t)n * 1000);
        } else if (!strncmp(s, "window:", 7)) {
            bool found = find_window(s + 7, 15000);
            printf("window \"%s\": %s", s + 7, found ? "shown" : "not found\n");
            if (found)
                printf(" %gx%g\n", current.width, current.height);
        } else if (sscanf(s, "click:%lf,%lf", &x, &y) == 2) {
            double sx = current.x + x, sy = current.y + y;
            post(FWS_EVENT_MOUSE_MOVED, sx, sy, 0, 0, 0);
            post(FWS_EVENT_LEFT_DOWN, sx, sy, 0, 0, 0);
            post(FWS_EVENT_LEFT_UP, sx, sy, 0, 0, 0);
        } else if (!strncmp(s, "type:", 5)) {
            for (const char *p = s + 5; *p; p++)
                key((uint16_t)(unsigned char)*p, 0, 0);
        } else if (sscanf(s, "key:%d,%d", &n, &c) == 2) {
            key((uint16_t)c, (uint32_t)n, 0);
        } else if (!strncmp(s, "cmd:", 4) && s[4]) {
            key((uint16_t)(unsigned char)s[4], 0, kCGEventFlagMaskCommand);
        } else if (sscanf(s, "sample:%lf,%lf,%63s", &x, &y, label) == 3) {
            usleep(200000);
            CGImageRef im = FWSCopyScreenImage();
            CFDataRef d = CGDataProviderCopyData(CGImageGetDataProvider(im));
            size_t bpr = CGImageGetBytesPerRow(im);
            const uint8_t *px = CFDataGetBytePtr(d) + (size_t)((current.y + y) * scale) * bpr +
                                (size_t)((current.x + x) * scale) * 4;
            printf("%s: %d %d %d\n", label, px[2], px[1], px[0]);
            CFRelease(d);
            CGImageRelease(im);
        } else if (!strncmp(s, "screenshot:", 11)) {
            usleep(200000);
            CGImageRef im = FWSCopyScreenImage();
            CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)s + 11, (CFIndex)strlen(s + 11), false);
            CGImageDestinationRef d = CGImageDestinationCreateWithURL(url, CFSTR("public.png"), 1, NULL);
            if (d) {
                CGImageDestinationAddImage(d, im, NULL);
                printf("screenshot %s: %s\n", s + 11, CGImageDestinationFinalize(d) ? "saved" : "failed");
                CFRelease(d);
            }
            CFRelease(url);
            CGImageRelease(im);
        } else if (!strcmp(s, "windows")) {
            uint32_t count = 0;
            FWSWindowInfo *list = FWSCopyWindowList(&count);
            for (uint32_t k = 0; k < count; k++)
                if (list[k].on_screen)
                    printf("  window \"%s\" %gx%g level %d\n", list[k].title, list[k].frame.width,
                           list[k].frame.height, list[k].level);
            free(list);
        } else if (!strcmp(s, "output")) {
            usleep(300000);
            drain_output(true);
        } else {
            printf("unknown step %s\n", s);
        }
    }
    usleep(300000);
    drain_output(true);
    int status = 0;
    kill(app, SIGTERM);
    waitpid(app, &status, 0);
    kill(server, SIGTERM);
    waitpid(server, NULL, 0);
    unlink(sock);
    return 0;
}
