/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * NSFileHandle, NSPipe, NSTask, NSPortMessage and NSHost
 * (docs/design/FOUNDATION.md), against the SDK's headers, with Apple's
 * concrete class names (NSConcreteFileHandle, NSConcretePipe,
 * NSConcreteTask).
 *
 * File handles are file descriptors; background reads run on a dispatch
 * queue and post their notification on the run loop of the thread that
 * asked, as Apple's do; readability and writeability handlers are dispatch
 * sources. Tasks are posix_spawn()ed, with pipes and file handles as their
 * standard streams (the parent's copies of a pipe's child ends are closed),
 * and watched by a dispatch process source that records the exit status
 * and runs the termination handler.
 */
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <arpa/inet.h>
#include <errno.h>
#include <pthread.h>
#include <fcntl.h>
#include <ifaddrs.h>
#include <netdb.h>
#include <signal.h>
#include <spawn.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

#include "Foundation_Finch.h"

extern char **environ;
int posix_spawn_file_actions_addchdir_np(posix_spawn_file_actions_t *, const char *);

NSNotificationName const NSFileHandleReadCompletionNotification = @"NSFileHandleReadCompletionNotification";
NSNotificationName const NSFileHandleReadToEndOfFileCompletionNotification = @"NSFileHandleReadToEndOfFileCompletionNotification";
NSNotificationName const NSFileHandleConnectionAcceptedNotification = @"NSFileHandleConnectionAcceptedNotification";
NSNotificationName const NSFileHandleDataAvailableNotification = @"NSFileHandleDataAvailableNotification";
NSString *const NSFileHandleNotificationDataItem = @"NSFileHandleNotificationDataItem";
NSString *const NSFileHandleNotificationFileHandleItem = @"NSFileHandleNotificationFileHandleItem";
NSString *const NSFileHandleNotificationMonitorModes = @"NSFileHandleNotificationMonitorModes";
NSNotificationName const NSTaskDidTerminateNotification = @"NSTaskDidTerminateNotification";
NSNotificationName const NSPortDidBecomeInvalidNotification = @"NSPortDidBecomeInvalidNotification";
NSString *const NSStreamNetworkServiceType = @"kCFStreamNetworkServiceType";
NSString *const NSStreamNetworkServiceTypeVoIP = @"kCFStreamNetworkServiceTypeVoIP";
NSString *const NSStreamNetworkServiceTypeVideo = @"kCFStreamNetworkServiceTypeVideo";
NSString *const NSStreamNetworkServiceTypeBackground = @"kCFStreamNetworkServiceTypeBackground";
NSString *const NSStreamNetworkServiceTypeVoice = @"kCFStreamNetworkServiceTypeVoice";
NSString *const NSStreamNetworkServiceTypeCallSignaling = @"kCFStreamNetworkServiceTypeCallSignaling";
NSErrorDomain const NSStreamSocketSSLErrorDomain = @"NSStreamSocketSSLErrorDomain";
NSErrorDomain const NSStreamSOCKSErrorDomain = @"NSStreamSOCKSErrorDomain";

/* Run `block` on `runLoop` in `modes`, waking it. */
static void
perform_on(CFRunLoopRef runLoop, NSArray *modes, void (^block)(void))
{
    CFRunLoopPerformBlock(runLoop, (CFTypeRef)(modes ? modes : @[ NSDefaultRunLoopMode ]), block);
    CFRunLoopWakeUp(runLoop);
}

static NSError *
posix_error(int code, NSString *path)
{
    NSError *u = [NSError errorWithDomain:NSPOSIXErrorDomain code:code userInfo:nil];
    NSInteger cocoa = code == ENOENT ? NSFileNoSuchFileError : code == EACCES || code == EPERM ? NSFileReadNoPermissionError : NSFileReadUnknownError;
    NSMutableDictionary *info = [NSMutableDictionary dictionaryWithObject:u forKey:NSUnderlyingErrorKey];
    if (path) [info setObject:path forKey:NSFilePathErrorKey];
    return [NSError errorWithDomain:NSCocoaErrorDomain code:cocoa userInfo:info];
}

/* MARK: - NSFileHandle */

@interface NSConcreteFileHandle : NSFileHandle {
@public
    int _fd;
    BOOL _closeOnDealloc, _closed;
    dispatch_source_t _readSource, _writeSource;
    void (^_readabilityHandler)(NSFileHandle *);
    void (^_writeabilityHandler)(NSFileHandle *);
}
@end

@implementation NSFileHandle

@dynamic availableData, offsetInFile;

+ (instancetype)allocWithZone:(NSZone *)zone
{
    if (self == [NSFileHandle class]) return [NSConcreteFileHandle allocWithZone:zone];
    return [super allocWithZone:zone];
}

+ (BOOL)supportsSecureCoding { return NO; }

static NSFileHandle *
shared(int fd)
{
    static NSFileHandle *handles[3];
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        for (int i = 0; i < 3; i++) handles[i] = [[NSFileHandle alloc] initWithFileDescriptor:i closeOnDealloc:NO];
    });
    return handles[fd];
}

+ (NSFileHandle *)fileHandleWithStandardInput { return shared(0); }
+ (NSFileHandle *)fileHandleWithStandardOutput { return shared(1); }
+ (NSFileHandle *)fileHandleWithStandardError { return shared(2); }

+ (NSFileHandle *)fileHandleWithNullDevice
{
    int fd = open("/dev/null", O_RDWR | O_CLOEXEC);
    return [[[self alloc] initWithFileDescriptor:fd closeOnDealloc:YES] autorelease];
}

static NSFileHandle *
open_path(Class cls, NSString *path, int flags, NSError **error)
{
    int fd = path ? open([path fileSystemRepresentation], flags | O_CLOEXEC) : -1;
    if (fd < 0) {
        if (error) *error = posix_error(path ? errno : EINVAL, path);
        return nil;
    }
    return [[[cls alloc] initWithFileDescriptor:fd closeOnDealloc:YES] autorelease];
}

+ (instancetype)fileHandleForReadingAtPath:(NSString *)path { return open_path(self, path, O_RDONLY, NULL); }
+ (instancetype)fileHandleForWritingAtPath:(NSString *)path { return open_path(self, path, O_WRONLY, NULL); }
+ (instancetype)fileHandleForUpdatingAtPath:(NSString *)path { return open_path(self, path, O_RDWR, NULL); }
+ (instancetype)fileHandleForReadingFromURL:(NSURL *)url error:(NSError **)error { return open_path(self, [url path], O_RDONLY, error); }
+ (instancetype)fileHandleForWritingToURL:(NSURL *)url error:(NSError **)error { return open_path(self, [url path], O_WRONLY, error); }
+ (instancetype)fileHandleForUpdatingURL:(NSURL *)url error:(NSError **)error { return open_path(self, [url path], O_RDWR, error); }

- (instancetype)initWithFileDescriptor:(int)fd { return [self initWithFileDescriptor:fd closeOnDealloc:NO]; }
- (instancetype)initWithFileDescriptor:(int)fd closeOnDealloc:(BOOL)closeopt { return [super init]; }
- (instancetype)initWithCoder:(NSCoder *)coder { [self release]; return nil; }
- (void)encodeWithCoder:(NSCoder *)coder { }

@end

@implementation NSConcreteFileHandle

- (instancetype)initWithFileDescriptor:(int)fd closeOnDealloc:(BOOL)closeopt
{
    if ((self = [super initWithFileDescriptor:fd closeOnDealloc:closeopt])) {
        _fd = fd;
        _closeOnDealloc = closeopt;
    }
    return self;
}

- (void)dealloc
{
    [self setReadabilityHandler:nil];
    [self setWriteabilityHandler:nil];
    if (_closeOnDealloc && !_closed && _fd >= 0) close(_fd);
    [super dealloc];
}

- (int)fileDescriptor { return _fd; }

- (void)check:(SEL)cmd
{
    if (_closed || _fd < 0)
        FinchRaise(NSFileHandleOperationException, "*** -[NSConcreteFileHandle %s]: Bad file descriptor", sel_getName(cmd));
}

static NSError *
raise_or_error(NSConcreteFileHandle *self, SEL cmd, int code, NSError **error)
{
    if (!error) FinchRaise(NSFileHandleOperationException, "*** -[NSConcreteFileHandle %s]: %s", sel_getName(cmd), strerror(code));
    *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:code userInfo:nil];
    return *error;
}

/* Read up to `length` bytes (NSUIntegerMax: to the end), or what is
 * available now if `available`. */
- (NSData *)read:(NSUInteger)length available:(BOOL)available cmd:(SEL)cmd error:(NSError **)error
{
    if (_closed || _fd < 0) {
        raise_or_error(self, cmd, EBADF, error);
        return nil;
    }
    NSMutableData *d = [NSMutableData data];
    uint8_t buf[65536];
    while ([d length] < length) {
        size_t want = MIN(sizeof(buf), length - [d length]);
        ssize_t n = read(_fd, buf, want);
        if (n < 0) {
            if (errno == EINTR) continue;
            if (errno == EAGAIN && [d length]) break;
            raise_or_error(self, cmd, errno, error);
            return nil;
        }
        if (n == 0) break;
        [d appendBytes:buf length:(NSUInteger)n];
        if (available) break;
    }
    return d;
}

- (NSData *)availableData { return [self read:NSUIntegerMax available:YES cmd:_cmd error:NULL]; }
- (NSData *)readDataToEndOfFile { return [self read:NSUIntegerMax available:NO cmd:_cmd error:NULL]; }
- (NSData *)readDataOfLength:(NSUInteger)length { return [self read:length available:NO cmd:_cmd error:NULL]; }
- (NSData *)readDataToEndOfFileAndReturnError:(NSError **)error { return [self read:NSUIntegerMax available:NO cmd:_cmd error:error]; }
- (NSData *)readDataUpToLength:(NSUInteger)length error:(NSError **)error { return [self read:length available:NO cmd:_cmd error:error]; }

- (BOOL)write:(NSData *)data cmd:(SEL)cmd error:(NSError **)error
{
    if (_closed || _fd < 0) {
        raise_or_error(self, cmd, EBADF, error);
        return NO;
    }
    const uint8_t *b = [data bytes];
    NSUInteger left = [data length];
    while (left) {
        ssize_t n = write(_fd, b, left);
        if (n < 0) {
            if (errno == EINTR) continue;
            raise_or_error(self, cmd, errno, error);
            return NO;
        }
        b += n;
        left -= (NSUInteger)n;
    }
    return YES;
}

- (void)writeData:(NSData *)data { [self write:data cmd:_cmd error:NULL]; }
- (BOOL)writeData:(NSData *)data error:(NSError **)error { return [self write:data cmd:_cmd error:error]; }

- (unsigned long long)offsetInFile
{
    [self check:_cmd];
    off_t o = lseek(_fd, 0, SEEK_CUR);
    if (o < 0) FinchRaise(NSFileHandleOperationException, "*** -[NSConcreteFileHandle offsetInFile]: %s", strerror(errno));
    return (unsigned long long)o;
}

- (unsigned long long)seekToEndOfFile
{
    [self check:_cmd];
    off_t o = lseek(_fd, 0, SEEK_END);
    if (o < 0) FinchRaise(NSFileHandleOperationException, "*** -[NSConcreteFileHandle seekToEndOfFile]: %s", strerror(errno));
    return (unsigned long long)o;
}

- (void)seekToFileOffset:(unsigned long long)offset
{
    [self check:_cmd];
    if (lseek(_fd, (off_t)offset, SEEK_SET) < 0) FinchRaise(NSFileHandleOperationException, "*** -[NSConcreteFileHandle seekToFileOffset:]: %s", strerror(errno));
}

- (BOOL)getOffset:(unsigned long long *)offsetInFile error:(NSError **)error
{
    off_t o = _closed ? -1 : lseek(_fd, 0, SEEK_CUR);
    if (o < 0) { if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:_closed ? EBADF : errno userInfo:nil]; return NO; }
    if (offsetInFile) *offsetInFile = (unsigned long long)o;
    return YES;
}

- (BOOL)seekToEndReturningOffset:(unsigned long long *)offsetInFile error:(NSError **)error
{
    off_t o = _closed ? -1 : lseek(_fd, 0, SEEK_END);
    if (o < 0) { if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:_closed ? EBADF : errno userInfo:nil]; return NO; }
    if (offsetInFile) *offsetInFile = (unsigned long long)o;
    return YES;
}

- (BOOL)seekToOffset:(unsigned long long)offset error:(NSError **)error
{
    if (_closed || lseek(_fd, (off_t)offset, SEEK_SET) < 0) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:_closed ? EBADF : errno userInfo:nil];
        return NO;
    }
    return YES;
}

- (void)truncateFileAtOffset:(unsigned long long)offset
{
    [self check:_cmd];
    if (ftruncate(_fd, (off_t)offset) < 0 || lseek(_fd, (off_t)offset, SEEK_SET) < 0)
        FinchRaise(NSFileHandleOperationException, "*** -[NSConcreteFileHandle truncateFileAtOffset:]: %s", strerror(errno));
}

- (BOOL)truncateAtOffset:(unsigned long long)offset error:(NSError **)error
{
    if (_closed || ftruncate(_fd, (off_t)offset) < 0 || lseek(_fd, (off_t)offset, SEEK_SET) < 0) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:_closed ? EBADF : errno userInfo:nil];
        return NO;
    }
    return YES;
}

- (void)synchronizeFile { [self check:_cmd]; fsync(_fd); }
- (BOOL)synchronizeAndReturnError:(NSError **)error
{
    if (_closed || fsync(_fd) < 0) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:_closed ? EBADF : errno userInfo:nil];
        return NO;
    }
    return YES;
}

- (void)closeFile
{
    if (_closed) return;
    [self setReadabilityHandler:nil];
    [self setWriteabilityHandler:nil];
    if (_fd >= 0) close(_fd);
    _closed = YES;
}

- (BOOL)closeAndReturnError:(NSError **)error
{
    [self closeFile];
    return YES;
}

/* MARK: Background */

- (void)backgroundRead:(BOOL)toEnd notification:(NSNotificationName)name modes:(NSArray *)modes
{
    CFRunLoopRef rl = CFRunLoopGetCurrent();
    [self retain];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        NSError *err = nil;
        NSData *d = toEnd ? [self read:NSUIntegerMax available:NO cmd:@selector(readToEndOfFileInBackgroundAndNotify) error:&err]
                          : [self read:NSUIntegerMax available:YES cmd:@selector(readInBackgroundAndNotify) error:&err];
        NSMutableDictionary *info = [NSMutableDictionary dictionaryWithObject:d ? d : [NSData data] forKey:NSFileHandleNotificationDataItem];
        if (err) [info setObject:@([err code]) forKey:@"NSFileHandleError"];
        perform_on(rl, modes, ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:name object:self userInfo:info];
            [self release];
        });
    });
}

- (void)readInBackgroundAndNotifyForModes:(NSArray<NSRunLoopMode> *)modes
{
    [self backgroundRead:NO notification:NSFileHandleReadCompletionNotification modes:modes];
}
- (void)readInBackgroundAndNotify { [self readInBackgroundAndNotifyForModes:nil]; }
- (void)readToEndOfFileInBackgroundAndNotifyForModes:(NSArray<NSRunLoopMode> *)modes
{
    [self backgroundRead:YES notification:NSFileHandleReadToEndOfFileCompletionNotification modes:modes];
}
- (void)readToEndOfFileInBackgroundAndNotify { [self readToEndOfFileInBackgroundAndNotifyForModes:nil]; }

- (void)waitForDataInBackgroundAndNotifyForModes:(NSArray<NSRunLoopMode> *)modes
{
    CFRunLoopRef rl = CFRunLoopGetCurrent();
    [self retain];
    dispatch_source_t s = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)_fd, 0, dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0));
    dispatch_source_set_event_handler(s, ^{
        dispatch_source_cancel(s);
        perform_on(rl, modes, ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:NSFileHandleDataAvailableNotification object:self];
            [self release];
        });
    });
    dispatch_resume(s);
}
- (void)waitForDataInBackgroundAndNotify { [self waitForDataInBackgroundAndNotifyForModes:nil]; }

- (void)acceptConnectionInBackgroundAndNotifyForModes:(NSArray<NSRunLoopMode> *)modes
{
    CFRunLoopRef rl = CFRunLoopGetCurrent();
    int listen_fd = _fd;
    [self retain];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        int c = accept(listen_fd, NULL, NULL);
        NSFileHandle *h = c >= 0 ? [[[NSFileHandle alloc] initWithFileDescriptor:c closeOnDealloc:YES] autorelease] : nil;
        NSDictionary *info = h ? @{ NSFileHandleNotificationFileHandleItem: h } : @{ @"NSFileHandleError": @(errno) };
        perform_on(rl, modes, ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:NSFileHandleConnectionAcceptedNotification object:self userInfo:info];
            [self release];
        });
    });
}
- (void)acceptConnectionInBackgroundAndNotify { [self acceptConnectionInBackgroundAndNotifyForModes:nil]; }

- (void (^)(NSFileHandle *))readabilityHandler { return _readabilityHandler; }

- (void)setReadabilityHandler:(void (^)(NSFileHandle *))handler
{
    if (_readSource) {
        dispatch_source_cancel(_readSource);
        dispatch_release(_readSource);
        _readSource = NULL;
    }
    [_readabilityHandler release];
    _readabilityHandler = [handler copy];
    if (!handler || _closed) return;
    _readSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)_fd, 0, dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0));
    NSConcreteFileHandle *weak = self;
    dispatch_source_set_event_handler(_readSource, ^{
        void (^h)(NSFileHandle *) = [[weak->_readabilityHandler retain] autorelease];
        if (h) h(weak);
    });
    dispatch_resume(_readSource);
}

- (void (^)(NSFileHandle *))writeabilityHandler { return _writeabilityHandler; }

- (void)setWriteabilityHandler:(void (^)(NSFileHandle *))handler
{
    if (_writeSource) {
        dispatch_source_cancel(_writeSource);
        dispatch_release(_writeSource);
        _writeSource = NULL;
    }
    [_writeabilityHandler release];
    _writeabilityHandler = [handler copy];
    if (!handler || _closed) return;
    _writeSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_WRITE, (uintptr_t)_fd, 0, dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0));
    NSConcreteFileHandle *weak = self;
    dispatch_source_set_event_handler(_writeSource, ^{
        void (^h)(NSFileHandle *) = [[weak->_writeabilityHandler retain] autorelease];
        if (h) h(weak);
    });
    dispatch_resume(_writeSource);
}

@end

/* MARK: - NSPipe */

@interface NSConcretePipe : NSPipe {
@public
    NSFileHandle *_read, *_write;
}
@end

@implementation NSPipe

@dynamic fileHandleForReading, fileHandleForWriting;

+ (instancetype)allocWithZone:(NSZone *)zone
{
    if (self == [NSPipe class]) return [NSConcretePipe allocWithZone:zone];
    return [super allocWithZone:zone];
}

+ (NSPipe *)pipe { return [[[self alloc] init] autorelease]; }

@end

@implementation NSConcretePipe

- (instancetype)init
{
    if ((self = [super init])) {
        int fds[2];
        if (pipe(fds) < 0) {
            [self release];
            return nil;
        }
        fcntl(fds[0], F_SETFD, FD_CLOEXEC);
        fcntl(fds[1], F_SETFD, FD_CLOEXEC);
        _read = [[NSFileHandle alloc] initWithFileDescriptor:fds[0] closeOnDealloc:YES];
        _write = [[NSFileHandle alloc] initWithFileDescriptor:fds[1] closeOnDealloc:YES];
    }
    return self;
}

- (void)dealloc
{
    [_read release];
    [_write release];
    [super dealloc];
}

- (NSFileHandle *)fileHandleForReading { return _read; }
- (NSFileHandle *)fileHandleForWriting { return _write; }

@end

/* MARK: - NSTask */

@interface NSConcreteTask : NSTask {
@public
    NSURL *_executable;
    NSArray *_arguments;
    NSDictionary *_environment;
    NSURL *_directory;
    id _stdin, _stdout, _stderr;
    pid_t _pid;
    int _status;
    NSTaskTerminationReason _reason;
    BOOL _launched, _exited;
    NSQualityOfService _qos;
    void (^_terminationHandler)(NSTask *);
    dispatch_source_t _procSource;
    CFRunLoopRef _launchRunLoop;
    pthread_mutex_t _lock;
}
@end

@implementation NSTask

/* The concrete class implements the properties. */
@dynamic executableURL, arguments, environment, currentDirectoryURL, standardInput, standardOutput, standardError,
    processIdentifier, running, terminationStatus, terminationReason, terminationHandler, qualityOfService;

+ (instancetype)allocWithZone:(NSZone *)zone
{
    if (self == [NSTask class]) return [NSConcreteTask allocWithZone:zone];
    return [super allocWithZone:zone];
}

+ (NSTask *)launchedTaskWithLaunchPath:(NSString *)path arguments:(NSArray<NSString *> *)arguments
{
    NSTask *t = [[[NSTask alloc] init] autorelease];
    [t setLaunchPath:path];
    [t setArguments:arguments];
    [t launch];
    return t;
}

+ (NSTask *)launchedTaskWithExecutableURL:(NSURL *)url arguments:(NSArray<NSString *> *)arguments error:(NSError **)error
                       terminationHandler:(void (^)(NSTask *))terminationHandler
{
    NSTask *t = [[[NSTask alloc] init] autorelease];
    [t setExecutableURL:url];
    [t setArguments:arguments];
    [t setTerminationHandler:terminationHandler];
    return [t launchAndReturnError:error] ? t : nil;
}

@end

@implementation NSConcreteTask

- (instancetype)init
{
    if ((self = [super init])) {
        pthread_mutex_init(&_lock, NULL);
        _qos = NSQualityOfServiceDefault;
    }
    return self;
}

- (void)dealloc
{
    if (_procSource) {
        dispatch_source_cancel(_procSource);
        dispatch_release(_procSource);
    }
    if (_launchRunLoop) CFRelease(_launchRunLoop);
    [_executable release];
    [_arguments release];
    [_environment release];
    [_directory release];
    [_stdin release];
    [_stdout release];
    [_stderr release];
    [_terminationHandler release];
    pthread_mutex_destroy(&_lock);
    [super dealloc];
}

- (void)checkNotLaunched:(SEL)cmd
{
    if (_launched) FinchRaise(NSInvalidArgumentException, "*** -[NSConcreteTask %s]: task already launched", sel_getName(cmd));
}

#define SETTER(type, getter, setter, ivar, copyOp) \
    - (type)getter { return ivar; } \
    - (void)setter:(type)value { [self checkNotLaunched:_cmd]; id old = ivar; ivar = [value copyOp]; [old release]; }
SETTER(NSURL *, executableURL, setExecutableURL, _executable, copy)
SETTER(NSArray *, arguments, setArguments, _arguments, copy)
SETTER(NSDictionary *, environment, setEnvironment, _environment, copy)
SETTER(NSURL *, currentDirectoryURL, setCurrentDirectoryURL, _directory, copy)
SETTER(id, standardInput, setStandardInput, _stdin, retain)
SETTER(id, standardOutput, setStandardOutput, _stdout, retain)
SETTER(id, standardError, setStandardError, _stderr, retain)
#undef SETTER

- (NSString *)launchPath { return [_executable path]; }
- (void)setLaunchPath:(NSString *)path { [self setExecutableURL:path ? [NSURL fileURLWithPath:path] : nil]; }
- (NSString *)currentDirectoryPath { return _directory ? [_directory path] : [[NSFileManager defaultManager] currentDirectoryPath]; }
- (void)setCurrentDirectoryPath:(NSString *)path { [self setCurrentDirectoryURL:path ? [NSURL fileURLWithPath:path isDirectory:YES] : nil]; }
- (NSQualityOfService)qualityOfService { return _qos; }
- (void)setQualityOfService:(NSQualityOfService)qos { _qos = qos; }
- (void (^)(NSTask *))terminationHandler { return _terminationHandler; }
- (void)setTerminationHandler:(void (^)(NSTask *))handler { [_terminationHandler release]; _terminationHandler = [handler copy]; }
- (int)processIdentifier { return _pid; }

- (BOOL)isRunning
{
    pthread_mutex_lock(&_lock);
    BOOL r = _launched && !_exited;
    pthread_mutex_unlock(&_lock);
    return r;
}

/* The descriptor a standard stream comes from in the child: a pipe's
 * child end, a file handle's descriptor, or -1 to inherit. */
static int
child_fd(id stream, BOOL input)
{
    if ([stream isKindOfClass:[NSPipe class]]) return [(input ? [stream fileHandleForReading] : [stream fileHandleForWriting]) fileDescriptor];
    if ([stream isKindOfClass:[NSFileHandle class]]) return [stream fileDescriptor];
    return -1;
}

/* Record how the child ended (once), then tell the handler and observers. */
- (void)reapWithStatus:(int)status
{
    pthread_mutex_lock(&_lock);
    if (_exited) {
        pthread_mutex_unlock(&_lock);
        return;
    }
    _exited = YES;
    if (WIFSIGNALED(status)) {
        _status = WTERMSIG(status);
        _reason = NSTaskTerminationReasonUncaughtSignal;
    } else {
        _status = WEXITSTATUS(status);
        _reason = NSTaskTerminationReasonExit;
    }
    pthread_mutex_unlock(&_lock);
    void (^handler)(NSTask *) = [[_terminationHandler retain] autorelease];
    if (handler) handler(self);
    [self retain];
    perform_on(_launchRunLoop, nil, ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:NSTaskDidTerminateNotification object:self];
        [self release];
    });
}

- (BOOL)launchAndReturnError:(NSError **)error
{
    [self checkNotLaunched:_cmd];
    NSString *path = [_executable path];
    if (!path || access([path fileSystemRepresentation], X_OK) != 0) {
        if (error) *error = posix_error(path ? errno : ENOENT, path);
        return NO;
    }
    NSUInteger argc = [_arguments count];
    char **argv = calloc(argc + 2, sizeof(char *));
    argv[0] = strdup([path fileSystemRepresentation]);
    for (NSUInteger i = 0; i < argc; i++) argv[i + 1] = strdup([[_arguments objectAtIndex:i] UTF8String]);
    char **envp = environ;
    char **owned = NULL;
    if (_environment) {
        owned = calloc([_environment count] + 1, sizeof(char *));
        NSUInteger i = 0;
        for (NSString *k in _environment) owned[i++] = strdup([[NSString stringWithFormat:@"%@=%@", k, [_environment objectForKey:k]] UTF8String]);
        envp = owned;
    }
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    int fds[3] = { child_fd(_stdin, YES), child_fd(_stdout, NO), child_fd(_stderr, NO) };
    for (int i = 0; i < 3; i++) if (fds[i] >= 0) posix_spawn_file_actions_adddup2(&actions, fds[i], i);
    if (_directory) posix_spawn_file_actions_addchdir_np(&actions, [[_directory path] fileSystemRepresentation]);
    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK);
    for (int i = 0; i < 3; i++)
        if (fds[i] < 0) posix_spawn_file_actions_addinherit_np(&actions, i);
    sigset_t none, all;
    sigemptyset(&none);
    sigfillset(&all);
    posix_spawnattr_setsigmask(&attr, &none);
    posix_spawnattr_setsigdefault(&attr, &all);
    if (!_launchRunLoop) _launchRunLoop = (CFRunLoopRef)CFRetain(CFRunLoopGetCurrent());
    int rc = posix_spawn(&_pid, argv[0], &actions, &attr, argv, envp);
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attr);
    for (NSUInteger i = 0; argv[i]; i++) free(argv[i]);
    free(argv);
    if (owned) {
        for (NSUInteger i = 0; owned[i]; i++) free(owned[i]);
        free(owned);
    }
    if (rc != 0) {
        if (error) *error = posix_error(rc, path);
        return NO;
    }
    _launched = YES;
    /* The parent's copies of the pipes' child ends. */
    if ([_stdin isKindOfClass:[NSPipe class]]) [[_stdin fileHandleForReading] closeFile];
    if ([_stdout isKindOfClass:[NSPipe class]]) [[_stdout fileHandleForWriting] closeFile];
    if ([_stderr isKindOfClass:[NSPipe class]] && _stderr != _stdout) [[_stderr fileHandleForWriting] closeFile];
    _procSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC, (uintptr_t)_pid, DISPATCH_PROC_EXIT, dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0));
    pid_t pid = _pid;
    [self retain];
    dispatch_source_set_event_handler(_procSource, ^{
        int status = 0;
        if (waitpid(pid, &status, WNOHANG) == pid) [self reapWithStatus:status];
        dispatch_source_cancel(self->_procSource);
    });
    dispatch_source_set_cancel_handler(_procSource, ^{ [self release]; });
    dispatch_resume(_procSource);
    return YES;
}

- (void)launch
{
    NSError *e = nil;
    if (![self launchAndReturnError:&e]) FinchRaise(NSInvalidArgumentException, "launch path not accessible");
}

/* Until the child has been reaped, here or by the process source,
 * running the run loop meanwhile as Apple's does. */
- (void)waitUntilExit
{
    if (!_launched) return;
    while ([self isRunning]) {
        int status = 0;
        pid_t r = waitpid(_pid, &status, WNOHANG);
        if (r == _pid) {
            [self reapWithStatus:status];
            break;
        }
        if (r < 0 && errno == ECHILD) break;
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
}

- (int)terminationStatus
{
    if ([self isRunning] || !_launched) FinchRaise(NSInvalidArgumentException, "*** -[NSConcreteTask terminationStatus]: task still running");
    return _status;
}

- (NSTaskTerminationReason)terminationReason
{
    if ([self isRunning] || !_launched) FinchRaise(NSInvalidArgumentException, "*** -[NSConcreteTask terminationReason]: task still running");
    return _reason;
}

- (void)interrupt { if ([self isRunning]) kill(_pid, SIGINT); }
- (void)terminate { if ([self isRunning]) kill(_pid, SIGTERM); }
- (BOOL)suspend { return [self isRunning] && kill(_pid, SIGSTOP) == 0; }
- (BOOL)resume { return [self isRunning] && kill(_pid, SIGCONT) == 0; }

@end

/* MARK: - NSPortMessage */

@implementation NSPortMessage {
    NSPort *_send, *_receive;
    NSArray *_components;
    uint32_t _msgid;
}

- (instancetype)initWithSendPort:(NSPort *)sendPort receivePort:(NSPort *)replyPort components:(NSArray *)parts
{
    if ((self = [super init])) {
        _send = [sendPort retain];
        _receive = [replyPort retain];
        _components = [parts copy];
    }
    return self;
}

- (void)dealloc
{
    [_send release];
    [_receive release];
    [_components release];
    [super dealloc];
}

- (NSArray *)components { return _components; }
- (NSPort *)receivePort { return _receive; }
- (NSPort *)sendPort { return _send; }
- (uint32_t)msgid { return _msgid; }
- (void)setMsgid:(uint32_t)value { _msgid = value; }

- (BOOL)sendBeforeDate:(NSDate *)date
{
    return [_send sendBeforeDate:date msgid:_msgid components:[[_components mutableCopy] autorelease] from:_receive reserved:0];
}

@end

/* MARK: - NSHost */

@implementation NSHost

static NSMutableDictionary *host_cache;
static BOOL host_cache_enabled = YES;

+ (void)setHostCacheEnabled:(BOOL)flag { host_cache_enabled = flag; }
+ (BOOL)isHostCacheEnabled { return host_cache_enabled; }
+ (void)flushHostCache { @synchronized ([NSHost class]) { [host_cache removeAllObjects]; } }

/* The header's ivars: names and addresses. */
- (instancetype)initWithNames:(NSArray *)hostNames addresses:(NSArray *)hostAddresses
{
    if ((self = [super init])) {
        names = [hostNames copy];
        addresses = [hostAddresses copy];
    }
    return self;
}

- (void)dealloc
{
    [names release];
    [addresses release];
    [super dealloc];
}

/* Names and addresses getaddrinfo gives for `node`. */
static NSHost *
resolve(NSString *node, BOOL numeric)
{
    if (!node) return nil;
    NSString *key = [(numeric ? @"addr:" : @"name:") stringByAppendingString:node];
    @synchronized ([NSHost class]) {
        NSHost *cached = host_cache_enabled ? [host_cache objectForKey:key] : nil;
        if (cached) return cached;
    }
    struct addrinfo hints = { 0 }, *res = NULL;
    hints.ai_flags = AI_CANONNAME | (numeric ? AI_NUMERICHOST : 0);
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    if (getaddrinfo([node UTF8String], NULL, &hints, &res) != 0) return nil;
    NSMutableArray *found_names = [NSMutableArray array], *found = [NSMutableArray array];
    if (!numeric) [found_names addObject:node];
    for (struct addrinfo *a = res; a; a = a->ai_next) {
        char buf[INET6_ADDRSTRLEN] = "";
        if (a->ai_family == AF_INET) inet_ntop(AF_INET, &((struct sockaddr_in *)a->ai_addr)->sin_addr, buf, sizeof(buf));
        else if (a->ai_family == AF_INET6) inet_ntop(AF_INET6, &((struct sockaddr_in6 *)a->ai_addr)->sin6_addr, buf, sizeof(buf));
        NSString *s = [NSString stringWithUTF8String:buf];
        if ([s length] && ![found containsObject:s]) [found addObject:s];
        if (a->ai_canonname) {
            NSString *n = [NSString stringWithUTF8String:a->ai_canonname];
            if (![found_names containsObject:n]) [found_names addObject:n];
        }
        char host[NI_MAXHOST];
        if (numeric && getnameinfo(a->ai_addr, a->ai_addrlen, host, sizeof(host), NULL, 0, NI_NAMEREQD) == 0) {
            NSString *n = [NSString stringWithUTF8String:host];
            if (![found_names containsObject:n]) [found_names addObject:n];
        }
    }
    freeaddrinfo(res);
    NSHost *h = [[[NSHost alloc] initWithNames:found_names addresses:found] autorelease];
    @synchronized ([NSHost class]) {
        if (!host_cache) host_cache = [NSMutableDictionary new];
        if (host_cache_enabled) [host_cache setObject:h forKey:key];
    }
    return h;
}

+ (instancetype)hostWithName:(NSString *)name { return resolve(name, NO); }
+ (instancetype)hostWithAddress:(NSString *)address { return resolve(address, YES); }

+ (instancetype)currentHost
{
    char name[256] = "";
    gethostname(name, sizeof(name));
    NSMutableArray *found = [NSMutableArray array];
    struct ifaddrs *ifs = NULL;
    if (getifaddrs(&ifs) == 0) {
        for (struct ifaddrs *i = ifs; i; i = i->ifa_next) {
            if (!i->ifa_addr) continue;
            char buf[INET6_ADDRSTRLEN] = "";
            if (i->ifa_addr->sa_family == AF_INET) inet_ntop(AF_INET, &((struct sockaddr_in *)i->ifa_addr)->sin_addr, buf, sizeof(buf));
            else if (i->ifa_addr->sa_family == AF_INET6) inet_ntop(AF_INET6, &((struct sockaddr_in6 *)i->ifa_addr)->sin6_addr, buf, sizeof(buf));
            else continue;
            NSString *s = [NSString stringWithUTF8String:buf];
            if (![found containsObject:s]) [found addObject:s];
        }
        freeifaddrs(ifs);
    }
    return [[[NSHost alloc] initWithNames:@[ [NSString stringWithUTF8String:name] ] addresses:found] autorelease];
}

- (NSString *)name { return [names firstObject]; }
- (NSArray<NSString *> *)names { return names; }
- (NSString *)address { return [addresses firstObject]; }
- (NSArray<NSString *> *)addresses { return addresses; }
- (NSString *)localizedName { return [self name]; }

- (BOOL)isEqualToHost:(NSHost *)aHost
{
    for (NSString *a in addresses) if ([[aHost addresses] containsObject:a]) return YES;
    return NO;
}

@end
