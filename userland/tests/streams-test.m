/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-streams-test: NSStream (data, file, memory, buffer and bound
 * streams, delegate events), NSPort, NSFileHandle, NSPipe, NSTask and
 * NSHost, one result per line so runs against Apple's Foundation and
 * Finch's can be diffed. Files go in NSTemporaryDirectory().
 */
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

@interface D : NSObject <NSStreamDelegate> @property NSMutableArray *events; @end
@implementation D - (void)stream:(NSStream *)s handleEvent:(NSStreamEvent)e { [self.events addObject:@(e)]; if (e == NSStreamEventHasBytesAvailable) { uint8_t b[64]; [(NSInputStream *)s read:b maxLength:sizeof b]; } if (e == NSStreamEventEndEncountered) { [s close]; } } @end

static void
streams(void)
{
 printf("%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n", NSStreamDataWrittenToMemoryStreamKey.UTF8String, NSStreamFileCurrentOffsetKey.UTF8String, NSStreamSocketSecurityLevelKey.UTF8String, NSStreamSocketSecurityLevelNone.UTF8String, NSStreamSocketSecurityLevelSSLv2.UTF8String, NSStreamSocketSecurityLevelSSLv3.UTF8String, NSStreamSocketSecurityLevelTLSv1.UTF8String, NSStreamSocketSecurityLevelNegotiatedSSL.UTF8String, NSStreamSOCKSProxyConfigurationKey.UTF8String, NSStreamSOCKSProxyHostKey.UTF8String, NSStreamSOCKSProxyPortKey.UTF8String, NSStreamSOCKSProxyVersionKey.UTF8String, NSStreamSOCKSProxyUserKey.UTF8String, NSStreamSOCKSProxyPasswordKey.UTF8String, NSStreamSOCKSProxyVersion4.UTF8String, NSStreamSOCKSProxyVersion5.UTF8String, NSStreamNetworkServiceType.UTF8String, NSStreamSocketSSLErrorDomain.UTF8String, NSStreamSOCKSErrorDomain.UTF8String);
 printf("%s %s %s %s\n", NSStreamNetworkServiceTypeVoIP.UTF8String, NSStreamNetworkServiceTypeVideo.UTF8String, NSStreamNetworkServiceTypeBackground.UTF8String, NSPortDidBecomeInvalidNotification.UTF8String);
 NSInputStream *in=[NSInputStream inputStreamWithData:[@"hello world" dataUsingEncoding:4]];
 printf("class %s status %lu\n", class_getName([in class]), (unsigned long)in.streamStatus);
 [in open]; uint8_t buf[5]; NSInteger n=[in read:buf maxLength:5]; printf("read %ld %.5s status %lu avail %d delegate-self %d\n", (long)n, buf, (unsigned long)in.streamStatus, in.hasBytesAvailable, in.delegate == in);
 uint8_t *bp; NSUInteger bl; printf("getBuffer %d\n", [in getBuffer:&bp length:&bl]);
 n=[in read:buf maxLength:5]; n=[in read:buf maxLength:5]; printf("rest %ld status %lu offset %s\n", (long)n, (unsigned long)in.streamStatus, [[in propertyForKey:NSStreamFileCurrentOffsetKey] description].UTF8String);
 [in close]; printf("closed %lu\n", (unsigned long)in.streamStatus);
 NSOutputStream *out=[NSOutputStream outputStreamToMemory]; [out open]; [out write:(const uint8_t*)"abc" maxLength:3]; [out write:(const uint8_t*)"de" maxLength:2];
 printf("out %s %s space %d\n", class_getName([out class]), [[[NSString alloc] initWithData:[out propertyForKey:NSStreamDataWrittenToMemoryStreamKey] encoding:4] UTF8String], out.hasSpaceAvailable);
 uint8_t small[4]; NSOutputStream *bo=[NSOutputStream outputStreamToBuffer:small capacity:4]; [bo open]; printf("buffer %ld %ld status %lu\n", (long)[bo write:(const uint8_t*)"xyz" maxLength:3], (long)[bo write:(const uint8_t*)"zz" maxLength:2], (unsigned long)bo.streamStatus);
 NSString *path=[NSTemporaryDirectory() stringByAppendingPathComponent:@"finch-stream-test.txt"]; NSOutputStream *fo=[NSOutputStream outputStreamToFileAtPath:path append:NO]; [fo open]; [fo write:(const uint8_t*)"file1" maxLength:5]; [fo close];
 fo=[NSOutputStream outputStreamToFileAtPath:path append:YES]; [fo open]; [fo write:(const uint8_t*)"+2" maxLength:2]; [fo close];
 NSInputStream *fi=[NSInputStream inputStreamWithFileAtPath:path]; [fi open]; uint8_t fb[32]={0}; n=[fi read:fb maxLength:32]; printf("file %ld %s\n", (long)n, fb);
 NSInputStream *missing=[NSInputStream inputStreamWithFileAtPath:@"/nonexistent/x"]; [missing open]; printf("missing status %lu error %s %ld\n", (unsigned long)missing.streamStatus, missing.streamError.domain.UTF8String, (long)missing.streamError.code);
 NSInputStream *bi; NSOutputStream *bo2; [NSStream getBoundStreamsWithBufferSize:16 inputStream:&bi outputStream:&bo2]; [bi open]; [bo2 open]; [bo2 write:(const uint8_t*)"pair" maxLength:4]; uint8_t pb[8]={0}; printf("bound %ld %s\n", (long)[bi read:pb maxLength:8], pb);
 D *d=[D new]; d.events=[NSMutableArray array]; NSInputStream *ev=[NSInputStream inputStreamWithData:[@"evented" dataUsingEncoding:4]]; ev.delegate=d; [ev scheduleInRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode]; [ev open];
 for (int i=0;i<5;i++) [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
 printf("events %s\n", [d.events componentsJoinedByString:@","].UTF8String);
 NSPort *p=[NSPort port]; printf("port %s valid %d %s\n", class_getName([p class]), p.isValid, class_getName(class_getSuperclass([NSMachPort class])));
 [p invalidate]; printf("invalid %d\n", p.isValid);
}

static void
files(void)
{
 NSString *path=[NSTemporaryDirectory() stringByAppendingPathComponent:@"finch-fh-test.txt"]; [@"0123456789" writeToFile:path atomically:NO encoding:4 error:NULL];
 NSFileHandle *h=[NSFileHandle fileHandleForReadingAtPath:path]; printf("%s fd>2 %d\n", class_getName([h class]), h.fileDescriptor > 2);
 NSData *d=[h readDataOfLength:4]; printf("read %s offset %llu\n", [[NSString alloc] initWithData:d encoding:4].UTF8String, h.offsetInFile);
 [h seekToFileOffset:8]; printf("rest %s\n", [[NSString alloc] initWithData:[h readDataToEndOfFile] encoding:4].UTF8String);
 NSError *e; unsigned long long off; printf("seekToEnd %llu %d\n", [h seekToEndOfFile], [h getOffset:&off error:&e] ? (int)off : -1);
 [h closeFile];
 NSFileHandle *w=[NSFileHandle fileHandleForUpdatingAtPath:path]; [w seekToEndOfFile]; [w writeData:[@"AB" dataUsingEncoding:4]]; [w truncateFileAtOffset:5]; [w synchronizeFile]; [w closeFile];
 printf("file %s\n", [NSString stringWithContentsOfFile:path encoding:4 error:NULL].UTF8String);
 printf("missing %s\n", [NSFileHandle fileHandleForReadingAtPath:@"/nonexistent"] ? "obj" : "nil");
 NSError *err; NSFileHandle *u=[NSFileHandle fileHandleForReadingFromURL:[NSURL fileURLWithPath:@"/nonexistent"] error:&err]; printf("url err %s %s %ld\n", u ? "obj" : "nil", err.domain.UTF8String, (long)err.code);
 NSPipe *p=[NSPipe pipe]; [p.fileHandleForWriting writeData:[@"through pipe" dataUsingEncoding:4]]; [p.fileHandleForWriting closeFile];
 printf("pipe %s %s\n", class_getName([p class]), [[NSString alloc] initWithData:[p.fileHandleForReading readDataToEndOfFile] encoding:4].UTF8String);
 NSTask *t=[NSTask new]; t.executableURL=[NSURL fileURLWithPath:@"/bin/sh"]; t.arguments=@[@"-c", @"echo out; echo err >&2; exit 3"]; NSPipe *o=[NSPipe pipe], *er=[NSPipe pipe]; t.standardOutput=o; t.standardError=er;
 [t launchAndReturnError:&err]; [t waitUntilExit];
 printf("task %s status %d reason %ld out %s err %s running %d\n", class_getName([t class]), t.terminationStatus, (long)t.terminationReason, [[NSString alloc] initWithData:[o.fileHandleForReading readDataToEndOfFile] encoding:4].UTF8String, [[NSString alloc] initWithData:[er.fileHandleForReading readDataToEndOfFile] encoding:4].UTF8String, t.isRunning);
 NSTask *k=[NSTask launchedTaskWithLaunchPath:@"/bin/sleep" arguments:@[@"5"]]; [k terminate]; [k waitUntilExit]; printf("killed status %d reason %ld\n", k.terminationStatus, (long)k.terminationReason);
 __block int handled=0; NSTask *hk=[NSTask new]; hk.launchPath=@"/usr/bin/true"; hk.terminationHandler=^(NSTask *x){ handled=1; }; [hk launch]; [hk waitUntilExit]; [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]]; printf("handler %d\n", handled);
 NSTask *bad=[NSTask new]; bad.executableURL=[NSURL fileURLWithPath:@"/nonexistent/bin"]; printf("bad launch %d %s %ld\n", [bad launchAndReturnError:&err], err.domain.UTF8String, (long)err.code);
 NSTask *env=[NSTask new]; env.launchPath=@"/usr/bin/env"; env.environment=@{@"FOO":@"bar"}; env.currentDirectoryPath=NSTemporaryDirectory(); NSPipe *eo=[NSPipe pipe]; env.standardOutput=eo; [env launch]; [env waitUntilExit]; printf("env %s", [[NSString alloc] initWithData:[eo.fileHandleForReading readDataToEndOfFile] encoding:4].UTF8String);
 NSFileHandle *nul=[NSFileHandle fileHandleWithNullDevice]; [nul writeData:[@"x" dataUsingEncoding:4]]; printf("null %lu\n", (unsigned long)[nul readDataToEndOfFile].length);
 printf("std %d %d %d\n", [NSFileHandle fileHandleWithStandardInput].fileDescriptor, [NSFileHandle fileHandleWithStandardOutput].fileDescriptor, [NSFileHandle fileHandleWithStandardError].fileDescriptor);
 NSPipe *ap=[NSPipe pipe]; __block NSMutableString *got=[NSMutableString string]; ap.fileHandleForReading.readabilityHandler=^(NSFileHandle *fh){ NSData *x=fh.availableData; if (x.length) [got appendString:[[NSString alloc] initWithData:x encoding:4]]; else fh.readabilityHandler=nil; };
 [ap.fileHandleForWriting writeData:[@"async" dataUsingEncoding:4]]; [ap.fileHandleForWriting closeFile]; [NSThread sleepForTimeInterval:0.2]; printf("readability %s\n", got.UTF8String);
 NSPipe *np=[NSPipe pipe]; [[NSNotificationCenter defaultCenter] addObserverForName:NSFileHandleReadToEndOfFileCompletionNotification object:np.fileHandleForReading queue:nil usingBlock:^(NSNotification *n){ printf("notified %s\n", [[NSString alloc] initWithData:n.userInfo[NSFileHandleNotificationDataItem] encoding:4].UTF8String); }];
 [np.fileHandleForReading readToEndOfFileInBackgroundAndNotify]; [np.fileHandleForWriting writeData:[@"bg" dataUsingEncoding:4]]; [np.fileHandleForWriting closeFile]; [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
 @try { [h readDataToEndOfFile]; } @catch (NSException *x) { printf("closed read: %s\n", x.name.UTF8String); }
}

int
main(int argc, char **argv)
{
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0);
        streams();
        files();
    }
    return 0;
}
