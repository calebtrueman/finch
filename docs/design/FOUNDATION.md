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
- 2026-10-08: the run-loop and threading layer. In CF: `NSRunLoop` (one per
  CFRunLoop), `NSTimer` with `__NSCFTimer` as CFRunLoopTimer's class
  (target/selector, block and invocation timers; `-fire`; user info), the
  run-loop mode names, and `NSBlock`, which CF makes the superclass of
  libclosure's block classes at startup, as Apple's does. In Foundation: `NSThread`, the
  `NSLock` family, `NSNotification`/`NSNotificationCenter` (weak observers,
  block observers on operation queues), `NSOperation`/`NSBlockOperation`/
  `NSInvocationOperation`/`NSOperationQueue` on libdispatch (asynchronous
  operations wait for KVO), `NSProcessInfo`, and NSObject's `-performSelector:`
  variants (onto a thread's run loop, after a delay, cancellable).
  `-[NSInvocation invoke]` now leaves the arguments intact: it used to
  write the result over argument 0. `finch-runtime-test` (45 lines) is
  identical to Apple's on the host and in the VM, as are the other four.
- 2026-10-08: files, URLs and bundles. In CF: `NSURL` with `__NSCFURL` as
  CFURL's class (components, file URLs, path editing, standardizing, and
  descriptions that show the base), plus `__apply:context:` and
  `__applyValues:context:` for CF's apply functions. In Foundation:
  `NSURLComponents` and `NSURLQueryItem` over CF's URL components, NSString's
  percent encoding and NSCharacterSet's URL sets, `NSFileManager` (create,
  copy, move, link, remove, attributes, directory enumeration with
  `-skipDescendants`, standard directories), `NSSearchPathForDirectoriesInDomains`
  through Libc's sysdir (in Apple's order, cryptexes included), `NSBundle`
  over CFBundle (one object per bundle, resources, localized strings,
  `+bundleForClass:`), `NSPropertyListSerialization`, and property-list and
  string file I/O. Finch's frameworks now carry Info.plists with Apple's
  identifiers (`tools/mkframeworkplist.sh`). `finch-files-test` is identical
  to Apple's (the CFURL class name aside, which it doesn't print).
- 2026-10-08: international. In CF: `NSLocale`, `NSTimeZone`, `NSCalendar` and
  `NSDateComponents`, with `__NSCFLocale`, `__NSCFTimeZone` and `__NSCFCalendar` as
  the classes of CF's objects (Apple's are Swift now; the behaviour is ICU's
  either way); `NSUserDefaults` over CFPreferences (argument, app, global and
  registration domains, Apple's typed conversions); the 274 `NS*` string
  constants Apple's CF exports (`NSConstants_Finch.c`, 52 of them linker
  aliases of CF's own kCF constants, as on macOS); `_CFAutoreleasePoolPush`,
  with an autorelease pool around each run-loop callout as Apple's run loop
  has. CF now asks ObjC numbers for their type (`DEPLOYMENT_RUNTIME_OBJC`
  paths in CFNumber), which literal numbers need. In Foundation: `NSFormatter`,
  `NSDateFormatter` and `NSNumberFormatter` over CF's formatters. The image gets
  the time-zone database, built from IANA's tzdata 2026c (`userland/tzdata`).
  `finch-intl-test` is identical to Apple's on the host and in the VM.
- 2026-10-08: key-value coding and observing. In Foundation: KVC (Apple's
  accessor and instance-variable search, boxing of scalars and structs, key
  paths, the collection operators, `-mutableArrayValueForKey:`, dictionaries'
  KVC), KVO by isa-swizzling into `NSKVONotifying_<Class>` (setters for every
  argument type, the new/old/initial/prior options, dependent keys,
  key-path observers that follow intermediate objects, and to-many changes
  through the mutable proxy), `NSIndexSet`/`NSMutableIndexSet` with
  NSArray's index-set methods, and the geometry functions and NSValue boxes
  (`NSStringFromRect` and so on). NSValue strips field names from type
  encodings and describes NSRange and the geometry types as Apple's does.
  `%@` in Foundation's (and NSException's) formats now uses `-description`,
  as Apple's does (a CFBoolean is `1`, not CF's `true`), and
  `NSProcessInfo.arguments[0]` is the full executable path. `finch-kvc-test`
  is identical to Apple's on the host and in the VM; `@sum` and `@avg`
  return NSNumbers until NSDecimalNumber exists.
- 2026-10-08: data formats. `NSDecimalNumber`, `NSDecimalNumberHandler` and
  the `NSDecimal` functions (128-bit mantissas, worked on 1024-bit integers
  so any two exponents line up; division to 39 digits, truncated, as
  Apple's; every rounding mode); `NSScanner` (Apple's skipping, overflow and
  hex rules, `-scanDecimal:`); `NSJSONSerialization` (Apple's number types,
  error messages and positions, JSON5, pretty printing and sorted keys in
  Finder's order); `NSUUID` (`__NSConcreteUUID`); `NSSortDescriptor` and the
  descriptor, function and binary-search sorting methods; NSObject.h's
  `NSAllocateObject` family. `@sum` and `@avg` now answer NSDecimalNumbers.
  Numbers Foundation makes keep their type ([NSNumber numberWithLongLong:5]
  is a `q`; CF's small-integer cache made it an `i`), and unsigned values
  above `LLONG_MAX` are `Q`. `finch-data-test` is identical to Apple's on
  the host and in the VM.
- 2026-10-08: archiving. `NSCoder` (the unkeyed API from its primitives,
  secure decoding, geometry keys), `NSKeyedArchiver` and `NSKeyedUnarchiver`
  writing and reading Apple's archive format: objects numbered as Apple's
  archiver numbers them (contents before their class entry, strings shared
  by value, conditional objects numbered when first referred to), plist
  values in place, the unkeyed API under `$0`, `$1`..., C arrays as
  `_NSKeyedCoderOldStyleArray`, structs refused. Every Foundation and CF
  class Finch has codes itself under Apple's keys (`NSCodingClasses.m`), and
  CF's concrete classes name their mutable or immutable class for coding.
  NSObject gets the coding hooks, `NSAllocateObject`'s family is in, and
  NSData gets base64. `finch-archive-test` is identical to Apple's on the
  host and in the VM, including decoding an archive Apple's Foundation made.
  Modern compiled nibs are `NIBArchive` files, not keyed archives; AppKit
  will bring that decoder.
- 2026-10-08: text and collections. `NSAttributedString` and
  `NSMutableAttributedString` (abstract classes on two primitives each, the
  mutable-string proxy, enumeration, Apple's archive format with LEB128 run
  info), with CF's `__NSCFAttributedString` as CFAttributedString's class;
  `NSRegularExpression`, `NSTextCheckingResult` (Apple's result class names)
  and NSString's regular-expression search, over CF's ICU regexes;
  `NSDataDetector` for links and phone numbers with Finch's own patterns
  (Apple's is the closed DataDetectorsCore; dates and addresses aren't
  detected yet); `NSHashTable`, `NSMapTable`, `NSPointerArray`,
  `NSPointerFunctions` and the C map/hash table API, with zeroing weak
  entries; `NSCountedSet`; Apple's Cocoa error descriptions. `NSOrderedSet`
  and `NSCache` live in CoreFoundation, as Apple's do: binaries linked
  against the SDK bind them there. Sets and ordered sets nested in a
  collection's description are quoted, as Apple's are.
  `finch-collections-test` is identical to Apple's on the host and in the VM.
- 2026-10-08: coverage and odds and ends. `tools/check-framework-api.py`
  compares Finch's exports with the SDK's (classes and C symbols, in the
  image Apple puts them in; Foundation re-exports CF, so Foundation's API
  may come from CF but not the reverse). New: `NSProxy` (a root class on
  libobjc's reference counting), `NSAssertionHandler` (what NSAssert calls;
  failures go to os_log as Apple's do), `NSIndexPath`, `NSDateInterval`,
  `NSAffineTransform`, `NSValueTransformer` and its named transformers,
  `NSUndoManager` (groups, event grouping on the run loop, redo, invocation
  proxies, block handlers, levels, notifications), `NSNotificationQueue`,
  `NSSetUncaughtExceptionHandler`, zones and pages, NSDebug.h's switches,
  HFS type codes, and the error domains, keys, exception names and old
  defaults keys Apple exports. `finch-misc-test` is identical to Apple's on
  the host and in the VM.
- 2026-10-08: streams, ports and processes. In CF, as Apple's are:
  `NSStream`, `NSInputStream` and `NSOutputStream` with `__NSCFInputStream`
  and `__NSCFOutputStream` as CFReadStream's and CFWriteStream's classes
  (delegate events through CF's client callback), `CFStreamCreateBoundPair`
  (swift-corelibs lacks it), `NSPort` and `NSMachPort` over CFMachPort
  (components as out-of-line memory and port descriptors), and
  `__NSCFError`, which bridges CFError to NSError. In Foundation:
  `NSFileHandle` (background reads that notify on the asking thread's run
  loop, readability handlers), `NSPipe`, `NSTask` (posix_spawn, a dispatch
  process source for termination), `NSPortMessage` and `NSHost`. CF's
  lookups of Apple's closed CarbonCore, CoreServicesInternal and CFNetwork
  (dlopen at run time, which `tools/check-closed.py` can't see) are patched
  out. `finch-streams-test` is identical to Apple's on the host and in the
  VM; resolving host names in the VM waits for mDNSResponder.
- 2026-10-08: predicates. `NSPredicate` (true, false, block, comparison and
  compound predicates) and `NSExpression` (constants, key paths, variables,
  functions, aggregates, subqueries, set operations, conditionals, blocks),
  with Apple's class names. Format strings parse by recursive descent with
  Apple's precedence, options ([cdn]), modifiers (ANY, ALL, NONE, SOME),
  subscripts (FIRST, LAST, SIZE), CAST, TERNARY, SUBQUERY and the
  arithmetic and statistics functions; descriptions and evaluation follow
  Apple's (integer division, constant casts folded when parsed, 0o and 0b
  literals as 0). Arrays, sets and ordered sets filter with predicates. A
  bare collection operator (@sum without a key) now fails as Apple's KVC
  does. UTI comparisons parse but evaluate false until Finch has a type
  database. `finch-predicate-test` is identical to Apple's on the host and
  in the VM.
- 2026-10-08: documents. `NSProgress` (parent and child trees, implicit
  children while current, cancel/pause/resume with handlers, KVO-observable
  fraction), `NSByteCountFormatter`, `NSISO8601DateFormatter`,
  `NSDateComponentsFormatter` (English for now: Apple's localizes through
  ICU's measure formats, which have no C API),
  `NSOrderedCollectionDifference` and the array and ordered-set diffing
  methods, `NSDistributedNotificationCenter` (the in-process center Apple
  gives processes without a window server; system-wide delivery needs a
  distnoted), and `NSFileWrapper` (files, directories and links, Apple's
  numbered keys for clashing names). NSData reads URLs.
  `finch-documents-test` is identical to Apple's on the host and in the VM.
- 2026-10-08: units, measurements and XML. `NSUnit`, `NSDimension` and all 22
  of Apple's dimensions with every unit Apple's has (symbols and conversion
  factors read from Apple's, Fahrenheit's odd constant included), each class
  property one immortal instance of a runtime `_NSStatic_` subclass as Apple's
  (miles per gallon, on the private `NSUnitConverterReciprocal`, an ordinary
  one); `NSUnitConverterLinear`; `NSMeasurement` (conversion, arithmetic in the
  base unit, Apple's equality, hashes and exception messages, secure coding
  under Apple's keys). `NSMeasurementFormatter` works as Apple's, through the
  private `NSUnitFormatter` and ICU's measure formats (Apple's `uameasfmt` C API
  in libicucore, which Foundation now links): each unit carries its ICU unit,
  the locale's preferred units come from ICU's usage data ("road", "person",
  "food", "weather"...), and natural scale picks units with Apple's
  thresholds, per measurement system. **libxml2** is new in Finch's image:
  Apple's libxml2-39.10 (the 26.4 release), built from the project's own
  sources and settings (`userland/oss/libxml2.build.sh`; Xcode's build of the
  project stalls) with Apple's version and exactly Apple's 1,683 exports.
  `NSXMLParser` runs on it as Apple's does: data and streams go through the push
  parser in Apple's chunk sizes, entities are substituted, the delegate may
  resolve undeclared ones, namespaces are reported or processed, and errors
  carry libxml2's codes, messages, lines and columns, with Apple's stopping
  rules (the first fatal error reaches the delegate, the parse ends with
  libxml2's code 111; aborting gives `NSXMLParserDelegateAbortedParseError`).
  Its quirks are kept: attribute types and element models are empty strings,
  and text right after a reference to a declared entity is dropped.
  `finch-measurement-test` (522 lines: every unit, five locales, every style
  and option) and `finch-xmlparser-test` (811 lines) are identical to Apple's
  on the host. `NSXMLDocument` and the rest of the tree API aren't done.
- 2026-10-09: NSURL's resource values (names, kinds, sizes, dates, permissions, type
  identifiers) from lstat(2), with what each key answers for files, directories,
  packages, symbolic links and missing files as macOS 26.4's. Type identifiers come from
  Finch's UniformTypeIdentifiers (`userland/UniformTypeIdentifiers`): UTType over a table
  of the system's declared types plus the app's own, and dynamic types whose `dyn.`
  identifiers encode their tags as Apple's do. `finch-uti-test` matches Apple's on the
  host.
