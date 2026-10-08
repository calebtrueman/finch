# Foundation, and CoreFoundation's Objective-C half

Unmodified Mac apps link Foundation (15,510 exports, 397 classes on macOS
26.4). Apple's is closed, so Finch writes its own. It's the first piece of
Phase 2 (`docs/ROADMAP.md`), and the last closed library Finch's binaries
link (`tools/check-closed.py`: gcore's GCoreFramework).

## How Apple's is split

Measured on the host (ObjC runtime: `class_getImageName`, superclasses;
`dyld_info -exports`, `-linked_dylibs`):

- **CoreFoundation hosts 41 exported classes** and 414 `NS*` symbols. These
  include the collections (`NSArray`, `NSDictionary`, `NSSet`, `NSOrderedSet`
  and their mutable forms), `NSData`, `NSDate`, `NSURL`, `NSLocale`, `NSTimeZone`,
  `NSCalendar`, `NSRunLoop`, `NSTimer`, `NSException`, `NSNull`,
  `NSEnumerator`, `NSStream`, the clang literal classes (`NSConstantArray`,
  `NSConstantDictionary`, …), and the exception names (`NSRangeException`,
  …). The private `__NSCF*` classes give CF objects their ObjC identity:
  `__NSCFArray`, `__NSCFDictionary`, `__NSCFString`, `__NSCFNumber`, and so on.
- **Foundation hosts the rest:** `NSString`/`NSMutableString`, `NSNumber`/`NSValue`,
  `NSError`, `NSAutoreleasePool`, `NSThread`, `NSBundle`, `NSProcessInfo`,
  `NSFileManager`, `NSNotificationCenter`, `NSCharacterSet`,
  `NSAttributedString`, archiving, formatters, and more.
- **CoreFoundation links Foundation upward.** CF's `__NSCFString` subclasses
  Foundation's `NSMutableString`, and `__NSCFNumber` subclasses `NSNumber`.
  CF imports those class symbols (plus `NSError`, `NSValue`, `NSThread`, …)
  from Foundation, which in turn links CF normally.
- clang's literals use `NSConstantIntegerNumber` and friends (Foundation)
  and `NSConstantArray`/`NSConstantDictionary` (CF).

Finch keeps the same split, class for class, so that a class symbol is
exported from the image an app's binary expects it in.

## Toll-free bridging, both ways

**CF to ObjC** (done, `userland/CoreFoundation/CFObjC.m`): every CF object's
isa is the class CF's class table holds for its type.

**ObjC to CF**: a CF function given an ObjC object (an `NSArray` subclass passed
to `CFArrayGetCount`) sends it a message instead. Apple's CF does this at
about 200 `CF_OBJC_FUNCDISPATCHV` sites, which swift-corelibs compiles to
nothing. Finch compiles CF as Objective-C (MRC) and gives the macros real
definitions (`CFObjCDispatch_Finch.h`, patch 0003). The messages CF sends are
declared with Foundation's signatures in `CFObjCMessages_Finch.h`, so
arguments and results (`NSRange`, `double`, `va_list`) travel correctly. The
generic calls (`CFRetain`, `CFRelease`, `CFGetTypeID`, `CFEqual`, `CFHash`,
`CFCopyDescription`, `CFGetAllocator`) dispatch too.

An object is CF's when its class is the one the table holds for the type ID
its `CFRuntimeBase` records (or, for strings, CFSTR's constant-string class).
Anything else, tagged pointers included, is Objective-C.

## Class clusters

As in Apple's: `[NSArray alloc]` returns a placeholder whose `-init…` methods
return a concrete object. In Finch that's a CF object (`__NSCFArray`), so
everything Foundation makes is also a valid CF object, and the reverse
holds. Subclasses that apps write get ordinary allocation and implement the
primitive methods (`-count`, `-objectAtIndex:`); everything else in the
abstract class is written in terms of the primitives.

The core of each CF-hosted class lives in CF. Foundation adds its categories
on top (KVC, property-list I/O, sorting with descriptors, and so on), as
Apple's does. Where a method is implemented is invisible to apps. Only
which image exports each class is part of the ABI.

## References and licensing

Behaviour is checked against Apple's Foundation on the host: test programs
built against the SDK run on both systems, and the output has to match (the
`finch-cf-test` method). swift-corelibs-foundation (Apache 2.0) is the
reference implementation for semantics and is ported where it helps.
GNUstep is LGPL and isn't copied (`docs/LICENSING.md`).

## Order

1. CF: ObjC-to-CF dispatch; `NSException` and the exception names; the
   collection classes and `__NSCFArray`, `__NSCFDictionary`, `__NSCFSet`,
   `__NSCFData`, `__NSDate`; fast enumeration; literals.
2. Foundation core: `NSString` (with `__NSCFString` re-parented),
   `NSNumber`/`NSValue`, `NSAutoreleasePool`, `NSError`, `NSObject`'s Foundation
   categories. CF links it upward. GCoreFramework then runs on Finch alone.
3. Outward, by test programs and by what apps import: `NSThread`,
   `NSRunLoop`, `NSFileManager`, `NSBundle`, `NSProcessInfo`, notifications,
   archiving, formatters, KVC/KVO.

## Status

- 2026-10-08: CF compiles as Objective-C with Apple's dispatch (patch 0003,
  `CFObjCDispatch_Finch.h`, `CFObjCMessages_Finch.h`). It hosts `NSException`
  (with the standard names and Apple's uncaught-exception report), `NSArray`,
  `NSMutableArray`, `__NSPlaceholderArray`, `__NSCFArray`, `NSEnumerator` and
  `__NSFastEnumerationEnumerator`, the `isNS…__` type tests, and `__NSCFString`'s
  NSString primitives. `finch-bridge-test`, which covers CF calls on an ObjC
  `NSArray` subclass, NSArray messages on CFArrays, the class cluster, fast
  enumeration and exceptions, prints the same 45 lines against Apple's
  CoreFoundation and Finch's, on the host and in the VM. `finch-cf-test` is
  unchanged (identical to Apple's).
  Two fixes to swift-corelibs came with it: the ObjC path in
  `CFArrayGetValueAtIndex`, and isa updates when an instance is retyped
  (CFDictionary and CFSet are made as CFBasicHash), which an ObjC-aware
  `CFHash` relies on.
- 2026-10-08: CF also hosts `NSDictionary`/`NSMutableDictionary` (keys copied,
  as NSDictionary promises), `NSSet`/`NSMutableSet`, `NSData`/`NSMutableData` and
  `NSDate`, with `__NSCFDictionary`, `__NSCFSet`, `__NSCFData` and `__NSDate` as
  the classes of CF's own objects, plus `NSNull`'s `<null>`. Each concrete
  class's `+alloc` goes through its placeholder, so `[[obj class] alloc]`
  makes a CF object. `finch-bridge-test` now covers all of them (90 lines):
  CF calls on ObjC subclasses, NS messages on CF objects, mutation, copying,
  fast enumeration, descriptions, exceptions. Its output is identical to
  Apple's CoreFoundation on the host and in the VM.
- 2026-10-08: message forwarding, as Apple's CF provides it. That means libobjc's forward
  handler (`NSForwarding_arm64.s`: the message's registers saved in a frame
  in Apple's measured layout, with unwind info so exceptions pass through),
  `-forwardingTargetForSelector:`, `-forwardInvocation:` with an
  `NSInvocation`, and `-doesNotRecognizeSelector:` raising Apple's
  "unrecognized selector sent to instance" exception. `NSMethodSignature`
  places arguments by Darwin's arm64 ABI, with the same frame offsets as
  Apple's (checked against its debug description): sub-word integers
  extended, HFAs a member per v register, composites over 16 bytes by
  reference, stack arguments at natural alignment. `NSInvocation` builds,
  invokes, retains arguments and swaps return values. Also `NSGetSizeAndAlignment` and NSObject's
  `-methodSignatureForSelector:`, `-description` and `+description`.
  `finch-forward-test` (unrecognized selectors, forwarding targets, a
  proxy, hand-built invocations across every ABI case) is identical to
  Apple's on the host and in the VM.
  Next in CF: `NSOrderedSet`, `NSURL`, `NSLocale`/`NSTimeZone`/`NSCalendar`,
  `NSRunLoop`/`NSTimer`, streams, literal classes, tagged-pointer strings.
- 2026-10-08: **Finch's Foundation.framework** (`userland/Foundation`), compiled
  against the SDK's Foundation headers so every method has Apple's
  signature, linked as Apple's (Versions/C, 4424.1.255, re-exporting libobjc
  and CoreFoundation). CF links it upward through a stub naming the classes CF
  subclasses (`cf-imports.txt`). `__NSCFString` is now an `NSMutableString`,
  `__NSCFNumber` and `__NSCFBoolean` are `NSNumber`s, and `__NSCFCharacterSet` is an
  `NSMutableCharacterSet`. First classes: NSString and NSMutableString (class
  cluster over CFString, paths, encodings), NSNumber and NSValue (with clang's
  constant number literals), NSCharacterSet, NSError, NSAutoreleasePool, plus
  NSLog, the NSStringFrom…/…FromString functions, NSHomeDirectory and
  friends, and Foundation's categories on CF's collections (joining, sorting,
  file I/O). CF gains the constant literal classes (`NSConstantArray`,
  `NSConstantDictionary`), the empty singletons `@[]`/`@{}` refer to, and the
  `@catch (NSException *)` type. `finch-foundation-test` (ARC and literals,
  as apps are built; 92 lines) is identical to Apple's Foundation on the host
  and in the VM, and gcore dumps a process in the VM through GCoreFramework
  on Finch's Foundation. **`tools/check-closed.py`: nothing Finch builds links
  a closed library.**
- 2026-10-08: collection descriptions in Apple's property-list text
  (`NSDescription_Finch.m` in CF): quoting (only ASCII letters and digits
  go bare), escapes, nesting indentation, sorted string keys, sets as
  `{( )}`. `CFCopyDescription` and `%@` give that text for arrays,
  dictionaries and sets, as Apple's do (patch 0003), and `%@` of any
  Objective-C object is its `-description`. Checked line for line against
  Apple's in `finch-foundation-test`. `tools/cf-patch.sh` folds edits in
  the swift-corelibs tree into the last CF patch.

