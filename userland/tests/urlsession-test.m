/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-urlsession-test: the URL loading system: requests and their headers,
 * responses, and NSURLSession loading file:, data: and http: URLs (from a
 * small HTTP server on the loopback interface, with redirects and chunked
 * bodies), with completion handlers and delegates. Prints everything; run it
 * against Apple's Foundation and Finch's (DYLD_FRAMEWORK_PATH) and diff all
 * but the first line.
 */
#import <Foundation/Foundation.h>
#include <arpa/inet.h>
#include <dlfcn.h>
#include <netinet/in.h>
#include <pthread.h>
#include <stdio.h>
#include <sys/socket.h>
#include <unistd.h>

static int port;

/* Serves one canned response per connection, chosen by the request path. */
static void *
serve(void *arg)
{
    int listener = (int)(intptr_t)arg;
    for (;;) {
        int fd = accept(listener, NULL, NULL);
        if (fd < 0)
            break;
        char req[4096];
        ssize_t n = 0, r;
        while (n < (ssize_t)sizeof req - 1 && (r = read(fd, req + n, sizeof req - 1 - n)) > 0) {
            n += r;
            req[n] = 0;
            if (strstr(req, "\r\n\r\n")) {
                const char *cl = strcasestr(req, "Content-Length:");
                long body = cl ? atol(cl + 15) : 0;
                if (n - (strstr(req, "\r\n\r\n") + 4 - req) >= body)
                    break;
            }
        }
        req[n] = 0;
        char path[256] = "";
        char method[16] = "";
        sscanf(req, "%15s %255s", method, path);
        char out[8192];
        if (!strcmp(path, "/hello")) {
            snprintf(out, sizeof out,
                     "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: 6\r\nX-Test: one\r\n\r\nhello\n");
        } else if (!strcmp(path, "/chunked")) {
            snprintf(out, sizeof out,
                     "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n"
                     "5\r\n{\"a\":\r\n3\r\n 1}\r\n0\r\n\r\n");
        } else if (!strcmp(path, "/redirect")) {
            snprintf(out, sizeof out, "HTTP/1.1 302 Found\r\nLocation: /hello\r\nContent-Length: 0\r\n\r\n");
        } else if (!strcmp(path, "/echo")) {
            const char *ua = strcasestr(req, "\r\nX-Echo:");
            char value[64] = "";
            if (ua)
                sscanf(ua + 9, " %63[^\r]", value);
            const char *body = strstr(req, "\r\n\r\n") + 4;
            char text[512];
            snprintf(text, sizeof text, "%s %s body=%s", method, value, body);
            snprintf(out, sizeof out, "HTTP/1.1 201 Created\r\nContent-Type: text/plain\r\nContent-Length: %zu\r\n\r\n%s",
                     strlen(text), text);
        } else {
            snprintf(out, sizeof out, "HTTP/1.1 404 Not Found\r\nContent-Type: text/html\r\nContent-Length: 9\r\n\r\nnot found");
        }
        write(fd, out, strlen(out));
        shutdown(fd, SHUT_WR);
        char drain[256];
        while (read(fd, drain, sizeof drain) > 0)
            ;
        close(fd);
    }
    return NULL;
}

static void
start_server(void)
{
    int s = socket(AF_INET, SOCK_STREAM, 0);
    int one = 1;
    setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    struct sockaddr_in a = {.sin_len = sizeof a, .sin_family = AF_INET, .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};
    bind(s, (struct sockaddr *)&a, sizeof a);
    listen(s, 8);
    socklen_t len = sizeof a;
    getsockname(s, (struct sockaddr *)&a, &len);
    port = ntohs(a.sin_port);
    pthread_t t;
    pthread_create(&t, NULL, serve, (void *)(intptr_t)s);
}

static NSURL *
local(NSString *path)
{
    return [NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%d%@", port, path]];
}

/* The response, minus what varies between runs (ports, dates). */
static void
print_result(NSString *label, NSData *data, NSURLResponse *response, NSError *error)
{
    printf("%s:\n", label.UTF8String);
    if (error) {
        printf("  error %s %ld\n", error.domain.UTF8String, (long)error.code);
        return;
    }
    NSString *url = response.URL.absoluteString;
    url = [url stringByReplacingOccurrencesOfString:[NSString stringWithFormat:@":%d", port] withString:@":PORT"];
    printf("  class %s url %s\n", NSStringFromClass([response class]).UTF8String, url.UTF8String);
    printf("  MIME %s encoding %s length %lld suggested %s\n", response.MIMEType.UTF8String ?: "(nil)",
           response.textEncodingName.UTF8String ?: "(nil)", response.expectedContentLength,
           response.suggestedFilename.UTF8String);
    if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
        NSHTTPURLResponse *h = (NSHTTPURLResponse *)response;
        printf("  status %ld x-test %s\n", (long)h.statusCode, [h valueForHTTPHeaderField:@"x-TEST"].UTF8String ?: "(nil)");
    }
    printf("  data (%lu) %s\n", (unsigned long)data.length,
           [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] stringByReplacingOccurrencesOfString:@"\n"
                                                                                                         withString:@"\\n"]
               .UTF8String);
}

static void
load(NSString *label, NSURLRequest *request)
{
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [[[NSURLSession sharedSession] dataTaskWithRequest:request
                                     completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                                       print_result(label, data, response, error);
                                       dispatch_semaphore_signal(done);
                                     }] resume];
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
}

@interface Delegate : NSObject <NSURLSessionDataDelegate>
@property (retain) NSMutableData *data;
@property (retain) dispatch_semaphore_t done;
@end

@implementation Delegate
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data
{
    [self.data appendData:data];
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error
{
    printf("delegate: complete error %ld state %ld data %s\n", (long)error.code, (long)task.state,
           [[NSString alloc] initWithData:self.data encoding:NSUTF8StringEncoding].UTF8String);
    dispatch_semaphore_signal(self.done);
}
@end

int
main(void)
{
    @autoreleasepool {
        Dl_info info;
        dladdr((__bridge const void *)[NSURLSession class], &info);
        printf("NSURLSession from %s\n", info.dli_fname);
        start_server();

        /* Requests. */
        NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"http://example.com/a?b=c"]];
        printf("method %s timeout %.0f cache %lu cookies %d\n", r.HTTPMethod.UTF8String, r.timeoutInterval,
               (unsigned long)r.cachePolicy, r.HTTPShouldHandleCookies);
        printf("headers %s\n", r.allHTTPHeaderFields ? "set" : "(nil)");
        [r setValue:@"text/plain" forHTTPHeaderField:@"Content-Type"];
        [r addValue:@"a" forHTTPHeaderField:@"Accept"];
        [r addValue:@"b" forHTTPHeaderField:@"accept"];
        printf("content-type %s accept %s count %lu\n", [r valueForHTTPHeaderField:@"content-type"].UTF8String,
               [r valueForHTTPHeaderField:@"ACCEPT"].UTF8String, (unsigned long)r.allHTTPHeaderFields.count);
        [r setValue:nil forHTTPHeaderField:@"CONTENT-TYPE"];
        printf("after removal count %lu\n", (unsigned long)r.allHTTPHeaderFields.count);
        r.HTTPMethod = @"POST";
        r.HTTPBody = [@"x=1" dataUsingEncoding:NSUTF8StringEncoding];
        NSURLRequest *copy = [r copy];
        NSMutableURLRequest *mcopy = [copy mutableCopy];
        printf("copy class %s equal %d method %s body %lu\n", NSStringFromClass([copy class]).UTF8String,
               [copy isEqual:r], copy.HTTPMethod.UTF8String, (unsigned long)copy.HTTPBody.length);
        mcopy.HTTPMethod = @"PUT";
        printf("mutated copy equal %d original %s\n", [mcopy isEqual:r], r.HTTPMethod.UTF8String);
        NSURLRequest *plain = [NSURLRequest requestWithURL:[NSURL URLWithString:@"http://example.com/"]];
        printf("immutable copy same %d\n", [plain copy] == plain);
        NSData *archived = [NSKeyedArchiver archivedDataWithRootObject:r requiringSecureCoding:YES error:NULL];
        NSURLRequest *back = [NSKeyedUnarchiver unarchivedObjectOfClass:[NSURLRequest class] fromData:archived error:NULL];
        printf("archived %s %s accept %s body %lu\n", back.HTTPMethod.UTF8String, back.URL.absoluteString.UTF8String,
               [back valueForHTTPHeaderField:@"Accept"].UTF8String, (unsigned long)back.HTTPBody.length);

        /* Responses. */
        NSHTTPURLResponse *h = [[NSHTTPURLResponse alloc]
             initWithURL:[NSURL URLWithString:@"https://example.com/dir/"]
              statusCode:404
             HTTPVersion:@"HTTP/1.1"
            headerFields:@{@"content-type" : @"text/html; charset=ISO-8859-1", @"Content-Length" : @"42"}];
        printf("response MIME %s encoding %s length %lld suggested %s status %ld\n", h.MIMEType.UTF8String,
               h.textEncodingName.UTF8String, h.expectedContentLength, h.suggestedFilename.UTF8String, (long)h.statusCode);
        for (NSNumber *code in @[ @200, @204, @301, @404, @418, @500, @503 ])
            printf("  %d: %s\n", code.intValue, [NSHTTPURLResponse localizedStringForStatusCode:code.integerValue].UTF8String);
        NSURLResponse *plainResponse = [[NSURLResponse alloc] initWithURL:[NSURL URLWithString:@"http://example.com/report.pdf"]
                                                                  MIMEType:@"application/pdf"
                                                     expectedContentLength:-1
                                                          textEncodingName:nil];
        printf("plain response suggested %s length %lld\n", plainResponse.suggestedFilename.UTF8String,
               plainResponse.expectedContentLength);

        /* Loading. */
        NSString *file = [NSTemporaryDirectory() stringByAppendingPathComponent:@"finch-urlsession-test.txt"];
        [@"file contents" writeToFile:file atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        load(@"file", [NSURLRequest requestWithURL:[NSURL fileURLWithPath:file]]);
        load(@"missing file", [NSURLRequest requestWithURL:[NSURL fileURLWithPath:@"/nonexistent/finch"]]);
        load(@"data base64", [NSURLRequest requestWithURL:[NSURL URLWithString:@"data:text/plain;base64,aGVsbG8gZGF0YQ=="]]);
        load(@"data plain", [NSURLRequest requestWithURL:[NSURL URLWithString:@"data:,a%20b"]]);
        load(@"unsupported", [NSURLRequest requestWithURL:[NSURL URLWithString:@"gopher://example.com/"]]);
        load(@"http", [NSURLRequest requestWithURL:local(@"/hello")]);
        load(@"http chunked", [NSURLRequest requestWithURL:local(@"/chunked")]);
        load(@"http redirect", [NSURLRequest requestWithURL:local(@"/redirect")]);
        load(@"http 404", [NSURLRequest requestWithURL:local(@"/missing")]);
        NSMutableURLRequest *post = [NSMutableURLRequest requestWithURL:local(@"/echo")];
        post.HTTPMethod = @"POST";
        post.HTTPBody = [@"payload" dataUsingEncoding:NSUTF8StringEncoding];
        [post setValue:@"echoed" forHTTPHeaderField:@"X-Echo"];
        load(@"http post", post);
        load(@"refused", [NSURLRequest requestWithURL:[NSURL URLWithString:@"http://127.0.0.1:1/"]]);

        /* A download, and a delegate session. */
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        [[[NSURLSession sharedSession]
            downloadTaskWithURL:local(@"/hello")
              completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
                printf("download: file %d exists %d contents %s\n", location.isFileURL,
                       [[NSFileManager defaultManager] fileExistsAtPath:location.path],
                       [[NSString stringWithContentsOfURL:location encoding:NSUTF8StringEncoding error:NULL]
                           stringByReplacingOccurrencesOfString:@"\n"
                                                     withString:@"\\n"]
                           .UTF8String);
                dispatch_semaphore_signal(done);
              }] resume];
        dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);

        Delegate *d = [Delegate new];
        d.data = [NSMutableData data];
        d.done = dispatch_semaphore_create(0);
        NSURLSession *session = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration ephemeralSessionConfiguration]
                                                              delegate:d
                                                         delegateQueue:nil];
        NSURLSessionDataTask *task = [session dataTaskWithURL:local(@"/hello")];
        printf("task id %lu state %ld\n", (unsigned long)task.taskIdentifier, (long)task.state);
        [task resume];
        dispatch_semaphore_wait(d.done, DISPATCH_TIME_FOREVER);
        printf("task state %ld response status %ld\n", (long)task.state, (long)((NSHTTPURLResponse *)task.response).statusCode);
        [session finishTasksAndInvalidate];
    }
    return 0;
}
