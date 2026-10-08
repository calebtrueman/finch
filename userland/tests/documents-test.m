/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-documents-test: NSProgress, NSByteCountFormatter,
 * NSISO8601DateFormatter, NSDateComponentsFormatter, ordered-collection
 * differences, NSDistributedNotificationCenter and NSFileWrapper, one result
 * per line so runs against Apple's Foundation and Finch's can be diffed.
 */
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static void
progress_and_formatters(void)
{
 NSProgress *p=[NSProgress progressWithTotalUnitCount:10]; p.completedUnitCount=3;
 printf("progress %g %s | %s | %d %d %d\n", p.fractionCompleted, p.localizedDescription.UTF8String, p.localizedAdditionalDescription.UTF8String, p.isIndeterminate, p.isFinished, p.isCancellable);
 NSProgress *c=[NSProgress progressWithTotalUnitCount:4 parent:p pendingUnitCount:5]; c.completedUnitCount=2; printf("child %g parent %g\n", c.fractionCompleted, p.fractionCompleted);
 c.completedUnitCount=4; printf("child done parent %g completed %lld\n", p.fractionCompleted, p.completedUnitCount);
 [p becomeCurrentWithPendingUnitCount:2]; NSProgress *imp=[NSProgress progressWithTotalUnitCount:1]; [p resignCurrent]; imp.completedUnitCount=1; printf("implicit parent %g\n", p.fractionCompleted);
 [p cancel]; printf("cancelled %d %d\n", p.isCancelled, c.isCancelled);
 NSProgress *d=[NSProgress discreteProgressWithTotalUnitCount:0]; printf("indeterminate %d %g\n", d.isIndeterminate, d.fractionCompleted);
 NSByteCountFormatter *bf=[NSByteCountFormatter new]; for (NSNumber *n in @[@0,@1,@999,@1000,@1500,@1048576,@123456789,@(1LL<<40)]) printf("bytes %s | %s | %s\n", [bf stringFromByteCount:n.longLongValue].UTF8String, [NSByteCountFormatter stringFromByteCount:n.longLongValue countStyle:NSByteCountFormatterCountStyleBinary].UTF8String, [NSByteCountFormatter stringFromByteCount:n.longLongValue countStyle:NSByteCountFormatterCountStyleMemory].UTF8String);
 bf.allowedUnits=NSByteCountFormatterUseKB; bf.includesUnit=NO; printf("kb only %s\n", [bf stringFromByteCount:123456].UTF8String);
 NSISO8601DateFormatter *iso=[NSISO8601DateFormatter new]; NSDate *t=[NSDate dateWithTimeIntervalSince1970:1700000000.25];
 printf("iso %s | %s\n", [iso stringFromDate:t].UTF8String, [[iso dateFromString:@"2023-11-14T22:13:20Z"] description].UTF8String);
 iso.formatOptions=NSISO8601DateFormatWithInternetDateTime|NSISO8601DateFormatWithFractionalSeconds; printf("iso frac %s\n", [iso stringFromDate:t].UTF8String);
 iso.formatOptions=NSISO8601DateFormatWithFullDate; iso.timeZone=[NSTimeZone timeZoneWithName:@"Asia/Tokyo"]; printf("iso date %s\n", [iso stringFromDate:t].UTF8String);
 printf("iso class %s\n", [NSISO8601DateFormatter stringFromDate:t timeZone:[NSTimeZone timeZoneWithName:@"America/Toronto"] formatOptions:NSISO8601DateFormatWithInternetDateTime].UTF8String);
 NSDateComponentsFormatter *dcf=[NSDateComponentsFormatter new]; dcf.calendar=[NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian]; dcf.calendar.locale=[NSLocale localeWithLocaleIdentifier:@"en_US"];
 for (NSNumber *u in @[@(NSDateComponentsFormatterUnitsStylePositional), @(NSDateComponentsFormatterUnitsStyleAbbreviated), @(NSDateComponentsFormatterUnitsStyleShort), @(NSDateComponentsFormatterUnitsStyleFull), @(NSDateComponentsFormatterUnitsStyleSpellOut), @(NSDateComponentsFormatterUnitsStyleBrief)]) { dcf.unitsStyle=u.integerValue; printf("dcf %s | %s\n", [dcf stringFromTimeInterval:3725].UTF8String, [dcf stringFromTimeInterval:90061].UTF8String); }
 dcf.unitsStyle=NSDateComponentsFormatterUnitsStylePositional; dcf.allowedUnits=NSCalendarUnitMinute|NSCalendarUnitSecond; dcf.zeroFormattingBehavior=NSDateComponentsFormatterZeroFormattingBehaviorPad; printf("mm:ss %s\n", [dcf stringFromTimeInterval:65].UTF8String);
 NSArray *a=@[@"a",@"b",@"c",@"d"], *b=@[@"a",@"c",@"x",@"d",@"e"]; NSOrderedCollectionDifference *diff=[b differenceFromArray:a];
 for (NSOrderedCollectionChange *ch in diff) printf("change %ld %s %lu %lu\n", (long)ch.changeType, [ch.object description].UTF8String, (unsigned long)ch.index, (unsigned long)ch.associatedIndex);
 printf("applied %s hasChanges %d\n", [[a arrayByApplyingDifference:diff] componentsJoinedByString:@","].UTF8String, diff.hasChanges);
 NSDistributedNotificationCenter *dnc=[NSDistributedNotificationCenter defaultCenter]; printf("dnc %s\n", class_getName([dnc class]));
}

static void
file_wrappers(void)
{
 NSString *base=[NSTemporaryDirectory() stringByAppendingPathComponent:@"fwtest"]; [[NSFileManager defaultManager] removeItemAtPath:base error:NULL];
 NSFileWrapper *f=[[NSFileWrapper alloc] initRegularFileWithContents:[@"hello" dataUsingEncoding:4]]; f.preferredFilename=@"a.txt";
 NSFileWrapper *d=[[NSFileWrapper alloc] initDirectoryWithFileWrappers:@{@"a.txt":f}];
 NSString *k2=[d addRegularFileWithContents:[@"two" dataUsingEncoding:4] preferredFilename:@"a.txt"]; printf("k2 %s\n", k2.UTF8String);
 NSFileWrapper *l=[[NSFileWrapper alloc] initSymbolicLinkWithDestinationURL:[NSURL fileURLWithPath:@"a.txt"]]; l.preferredFilename=@"link"; [d addFileWrapper:l];
 printf("keys %s dir %d reg %d link %d\n", [[d.fileWrappers.allKeys sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@","].UTF8String, d.isDirectory, f.isRegularFile, l.isSymbolicLink);
 printf("keyFor %s\n", [d keyForFileWrapper:f].UTF8String);
 NSError *e; BOOL ok=[d writeToURL:[NSURL fileURLWithPath:base] options:0 originalContentsURL:nil error:&e]; printf("write %d %s\n", ok, e.description.UTF8String);
 printf("disk %s\n", [[[[NSFileManager defaultManager] contentsOfDirectoryAtPath:base error:NULL] sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@","].UTF8String);
 NSFileWrapper *r=[[NSFileWrapper alloc] initWithURL:[NSURL fileURLWithPath:base] options:0 error:&e];
 printf("read %s filename %s pref %s\n", [[r.fileWrappers.allKeys sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@","].UTF8String, r.filename.UTF8String, r.preferredFilename.UTF8String);
 NSFileWrapper *ra=r.fileWrappers[@"a.txt"]; printf("contents %s filename %s link %s\n", [[NSString alloc] initWithData:ra.regularFileContents encoding:4].UTF8String, ra.filename.UTF8String, r.fileWrappers[@"link"].symbolicLinkDestinationURL.relativeString.UTF8String);
 printf("matches %d\n", [r matchesContentsOfURL:[NSURL fileURLWithPath:base]]);
 [d removeFileWrapper:f]; printf("after remove %s\n", [[d.fileWrappers.allKeys sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@","].UTF8String);
 printf("attrs %d %s\n", ra.fileAttributes.count > 0, [ra.fileAttributes[NSFileType] description].UTF8String);
 NSFileWrapper *missing=[[NSFileWrapper alloc] initWithURL:[NSURL fileURLWithPath:@"/nonexistent"] options:0 error:&e]; printf("missing %s %s %ld\n", missing ? "obj" : "nil", e.domain.UTF8String, (long)e.code);
 @try { [f fileWrappers]; printf("reg fileWrappers ok\n"); } @catch (NSException *x) { printf("reg fileWrappers %s\n", x.name.UTF8String); }
}

int
main(int argc, char **argv)
{
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0);
        progress_and_formatters();
        file_wrappers();
    }
    return 0;
}
