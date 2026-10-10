/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-scripting-test: Cocoa scripting's object specifiers evaluated over key-value
 * coding, script class and command descriptions, script commands, and NSNetService's
 * TXT records, one result per line so runs against Apple's Foundation and Finch's can
 * be diffed. (Specifiers into to-many relationships need the element classes in the
 * suite registry, which is loaded from an app's sdef; they aren't compared here.)
 */
#import <Foundation/Foundation.h>
#include <dlfcn.h>

@interface Item : NSObject
@property (copy) NSString *name;
@property (copy) NSNumber *uniqueID;
@end
@implementation Item
- (NSString *)description { return self.name; }
@end

@interface Box : NSObject
@property (copy) NSArray *items;
@property (copy) NSString *title;
@end
@implementation Box
@end

@interface EchoCommand : NSScriptCommand
@end
@implementation EchoCommand
- (id)performDefaultImplementation { return [NSString stringWithFormat:@"echo %@", [self directParameter]]; }
@end

static NSScriptClassDescription *nocd; /* no class description: the tests evaluate by key alone */

static void
show(NSString *label, id value)
{
    printf("%s: %s\n", label.UTF8String, [[value description] stringByReplacingOccurrencesOfString:@"\n" withString:@" "].UTF8String);
}

int
main(void)
{
    @autoreleasepool {
        Dl_info info;
        dladdr((__bridge void *)[NSScriptCommand class], &info);
        printf("Foundation: %s\n", info.dli_fname);

        Box *box = [Box new];
        NSMutableArray *items = [NSMutableArray array];
        NSArray *names = @[@"alpha", @"beta", @"gamma", @"delta"];
        for (NSUInteger i = 0; i < names.count; i++) {
            Item *it = [Item new];
            it.name = names[i];
            it.uniqueID = @(100 + i);
            [items addObject:it];
        }
        box.items = items;
        box.title = @"the box";

        /* evaluation goes by the containers' class descriptions */
        NSScriptObjectSpecifier *s = [[NSIndexSpecifier alloc] initWithContainerClassDescription:nocd containerSpecifier:nil key:@"items" index:1];
        show(@"no description", [s objectsByEvaluatingWithContainers:box]);
        printf("no description error %ld\n", (long)s.evaluationErrorNumber);
        NSScriptClassDescription *itemd = [[NSScriptClassDescription alloc] initWithSuiteName:@"Test" className:@"item" dictionary:@{
            @"AppleEventCode" : @"item", @"Attributes" : @{@"name" : @{@"Type" : @"NSString", @"AppleEventCode" : @"pnam"},
                                                           @"uniqueID" : @{@"Type" : @"NSNumber", @"AppleEventCode" : @"ID  "}}}];
        NSScriptClassDescription *boxd = [[NSScriptClassDescription alloc] initWithSuiteName:@"Test" className:@"box" dictionary:@{
            @"AppleEventCode" : @"boxx", @"Attributes" : @{@"title" : @{@"Type" : @"NSString", @"AppleEventCode" : @"titl"}},
            @"ToManyRelationships" : @{@"items" : @{@"Type" : @"item", @"AppleEventCode" : @"item"}}}];
        [NSClassDescription registerClassDescription:itemd forClass:[Item class]];
        [NSClassDescription registerClassDescription:boxd forClass:[Box class]];
        nocd = boxd;
        s = [[NSPropertySpecifier alloc] initWithContainerClassDescription:nocd containerSpecifier:nil key:@"title"];
        show(@"property title", [s objectsByEvaluatingWithContainers:box]);
        s = [[NSIndexSpecifier alloc] initWithContainerClassDescription:nocd containerSpecifier:nil key:@"items" index:0];
        printf("key %s index %ld\n", s.key.UTF8String, (long)((NSIndexSpecifier *)s).index);
        NSPropertySpecifier *p = [[NSPropertySpecifier alloc] initWithContainerClassDescription:nocd containerSpecifier:s key:@"name"];
        printf("child set %d container %d\n", s.childSpecifier == p, p.containerSpecifier == s);

        NSDictionary *cls = @{@"AppleEventCode" : @"wind", @"Superclass" : @"NSCoreSuite.AbstractObject",
                              @"Attributes" : @{@"name" : @{@"Type" : @"NSString", @"AppleEventCode" : @"pnam"}},
                              @"ToManyRelationships" : @{@"items" : @{@"Type" : @"Item", @"AppleEventCode" : @"item"}}};
        NSScriptClassDescription *cd = [[NSScriptClassDescription alloc] initWithSuiteName:@"Test" className:@"box" dictionary:cls];
        printf("class %s suite %s code %08x\n", cd.className.UTF8String, cd.suiteName.UTF8String, (unsigned)cd.appleEventCode);
        printf("key for pnam %s, items to-many %d, name property %d\n", [cd keyWithAppleEventCode:'pnam'].UTF8String, [cd hasOrderedToManyRelationshipForKey:@"items"],
               [cd hasPropertyForKey:@"name"]);
        printf("code for items %08x\n", (unsigned)[cd appleEventCodeForKey:@"items"]);

        NSDictionary *cmd = @{@"CommandClass" : @"EchoCommand", @"AppleEventCode" : @"echo", @"AppleEventClassCode" : @"Test",
                              @"Arguments" : @{@"Loud" : @{@"Type" : @"NSNumber", @"AppleEventCode" : @"loud", @"Optional" : @"YES"}}};
        NSScriptCommandDescription *cmdd = [[NSScriptCommandDescription alloc] initWithSuiteName:@"Test" commandName:@"echo" dictionary:cmd];
        printf("command %s class %s code %08x/%08x args %s optional %d\n", cmdd.commandName.UTF8String, cmdd.commandClassName.UTF8String,
               (unsigned)cmdd.appleEventClassCode, (unsigned)cmdd.appleEventCode, [cmdd.argumentNames componentsJoinedByString:@","].UTF8String,
               [cmdd isOptionalArgumentWithName:@"Loud"]);
        NSScriptCommand *c = [cmdd createCommandInstance];
        c.directParameter = @"hi";
        printf("instance %s well formed %d\n", NSStringFromClass([c class]).UTF8String, c.isWellFormed);
        show(@"execute", [c executeCommand]);

        NSData *txt = [NSNetService dataFromTXTRecordDictionary:@{@"path" : [@"/x" dataUsingEncoding:NSUTF8StringEncoding]}];
        show(@"txt", txt);
        show(@"txt back", [NSNetService dictionaryFromTXTRecordData:txt]);
        unsigned char raw[] = {5, 'a', '=', 'b', 'c', 'd', 4, 'f', 'l', 'a', 'g', 3, 'e', '=', '1', 3, 'a', '=', 'z'};
        show(@"txt parse", [NSNetService dictionaryFromTXTRecordData:[NSData dataWithBytes:raw length:sizeof raw]]);
        NSNetService *svc = [[NSNetService alloc] initWithDomain:@"local." type:@"_ssh._tcp." name:@"host" port:22];
        printf("service %s %s %s port %ld host %s\n", svc.name.UTF8String, svc.type.UTF8String, svc.domain.UTF8String, (long)svc.port,
               svc.hostName ? svc.hostName.UTF8String : "(none)");
        printf("isEqualTo %d %d, lessThan %d %d, greater %d, contain %d %d\n", [@"a" isEqualTo:@"a"], [@1 isEqualTo:@2],
               [@1 isLessThan:@2], [@"b" isLessThan:@"a"], [@3 isGreaterThanOrEqualTo:@3], [@[@1, @2] doesContain:@2],
               [@"abc" doesContain:@"b"]);
        printf("like %d %d %d %d %d, case %d\n", [@"hello.txt" isLike:@"*.txt"], [@"hello" isLike:@"h?llo"],
               [@"hello" isLike:@"h*z"], [@"" isLike:@"*"], [@"abc" isLike:@"a**c"], [@"HeLLo" isCaseInsensitiveLike:@"hello"]);
        printf("scripting begins %d ends %d contains %d\n", [@"hello" scriptingBeginsWith:@"he"], [@"hello" scriptingEndsWith:@"lo"],
               [@"hello" scriptingContains:@"ell"]);
        show(@"error key", NSNetServicesErrorCode);
        show(@"error domain", NSNetServicesErrorDomain);
    }
    return 0;
}
