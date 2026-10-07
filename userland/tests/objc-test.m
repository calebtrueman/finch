/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * finch-objc-test: exercises the Objective-C runtime (libobjc) without
 * Foundation: messaging and method caches, categories, properties, weak
 * references, associated objects, autorelease pools, @synchronized,
 * exceptions, runtime class creation and method swizzling, from several
 * threads. Prints "objc: N/N passed"; exits nonzero on any failure.
 */

#import <objc/NSObject.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <dispatch/dispatch.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>

static int passed, failed;

static void check(bool ok, const char *what)
{
	if (ok)
		passed++;
	else {
		failed++;
		fprintf(stderr, "FAIL: %s\n", what);
	}
}

static atomic_int deallocs;

@interface Bird : NSObject
@property (nonatomic) int wings;
@property (nonatomic, strong) id friend;
- (int)sing:(int)times;
+ (instancetype)birdWithWings:(int)wings;
@end

@implementation Bird
+ (instancetype)birdWithWings:(int)wings
{
	Bird *b = [[self alloc] init];
	b.wings = wings;
	return b;
}
- (int)sing:(int)times { return times * self.wings; }
- (void)dealloc { atomic_fetch_add(&deallocs, 1); }
@end

@interface Finch : Bird
@end
@implementation Finch
- (int)sing:(int)times { return [super sing:times] + 1; }
@end

@interface Bird (Migration)
- (const char *)direction;
@end
@implementation Bird (Migration)
- (const char *)direction { return "south"; }
@end

@interface Oops : NSObject
@end
@implementation Oops
@end

static int swizzled_sing(id self, SEL _cmd, int times) { (void)self; (void)_cmd; return -times; }

static void test_messaging(void)
{
	Finch *f = [Finch birdWithWings:2];
	check([f sing:3] == 7, "message send + super");
	check(strcmp([f direction], "south") == 0, "category method");
	check([f isKindOfClass:[Bird class]] && ![f isMemberOfClass:[Bird class]], "isKindOfClass/isMemberOfClass");
	check([f respondsToSelector:@selector(direction)] && ![f respondsToSelector:@selector(fly)], "respondsToSelector");
	check(class_getSuperclass([Finch class]) == [Bird class], "class_getSuperclass");
	check(strcmp(class_getName(object_getClass(f)), "Finch") == 0, "class_getName");
	int sum = 0;
	for (int i = 0; i < 100000; i++)
		sum += [f sing:1];  /* method cache */
	check(sum == 300000, "cached message sends");
	check(((int (*)(id, SEL, int))objc_msgSend)(f, @selector(sing:), 5) == 11, "objc_msgSend direct");
}

static void test_memory(void)
{
	atomic_store(&deallocs, 0);
	__weak Bird *weak = nil;
	@autoreleasepool {
		Bird *b = [Bird birdWithWings:1];
		weak = b;
		check(weak != nil, "weak reference while alive");
	}
	check(weak == nil && atomic_load(&deallocs) == 1, "weak reference zeroed on dealloc");

	static char key;
	Bird *holder = [Bird new];
	@autoreleasepool {
		objc_setAssociatedObject(holder, &key, [Bird new], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	}
	check(objc_getAssociatedObject(holder, &key) != nil, "associated object");
	holder = nil;
	check(atomic_load(&deallocs) == 3, "associated object released with owner");

	Bird *a = [Bird new], *b = [Bird new];
	a.friend = b;
	b = nil;
	check(a.friend != nil, "strong property");
}

static void test_exceptions(void)
{
	bool caught = false, finally = false;
	@try {
		@throw [Oops new];
	} @catch (Bird *b) {
		(void)b;
	} @catch (Oops *o) {
		caught = (o != nil);
	} @finally {
		finally = true;
	}
	check(caught && finally, "@throw/@catch/@finally");
}

static void test_runtime(void)
{
	Class c = objc_allocateClassPair([Bird class], "Sparrow", 0);
	check(c != Nil, "objc_allocateClassPair");
	class_addMethod(c, @selector(direction), imp_implementationWithBlock(^(id self) {
		(void)self;
		return "north";
	}), "*@:");
	objc_registerClassPair(c);
	id s = [[c alloc] init];
	check(strcmp([s direction], "north") == 0, "block IMP on runtime class");
	check(objc_getClass("Sparrow") == c, "objc_getClass");

	Method m = class_getInstanceMethod([Finch class], @selector(sing:));
	IMP old = method_setImplementation(m, (IMP)swizzled_sing);
	check([[Finch birdWithWings:2] sing:4] == -4, "method swizzling");
	method_setImplementation(m, old);
	check([[Finch birdWithWings:2] sing:4] == 9, "method restored");

	unsigned count = 0;
	Ivar *ivars = class_copyIvarList([Bird class], &count);
	check(count == 2, "class_copyIvarList");
	free(ivars);
	objc_property_t p = class_getProperty([Bird class], "wings");
	check(p != NULL && strcmp(property_getName(p), "wings") == 0, "class_getProperty");
}

static void test_threads(void)
{
	Bird *shared = [Bird birdWithWings:1];
	__block int counter = 0;
	__block atomic_int sends = 0;
	dispatch_apply(64, dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^(size_t i) {
		@autoreleasepool {
			for (int k = 0; k < 1000; k++) {
				Finch *f = [Finch birdWithWings:(int)(i % 4)];
				atomic_fetch_add(&sends, [f sing:1] == (int)(i % 4) + 1);
			}
			@synchronized (shared) {
				counter++;
			}
		}
	});
	check(counter == 64, "@synchronized across threads");
	check(atomic_load(&sends) == 64000, "messaging + autorelease across threads");
}

int main(void)
{
	@autoreleasepool {
		test_messaging();
		test_memory();
		test_exceptions();
		test_runtime();
		test_threads();
	}
	printf("objc: %d/%d passed\n", passed, passed + failed);
	return failed != 0;
}
