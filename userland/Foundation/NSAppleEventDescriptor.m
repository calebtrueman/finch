/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSAppleEventDescriptor: an Objective-C face on an AEDesc from
 * CoreServices' AE (userland/CoreServices/AE). Apple's Foundation links
 * CoreServices; Finch's finds AE (and CarbonCore, for handles) when a
 * descriptor is first made, so programs that never use Apple events don't
 * load CoreServices, and Foundation stays below it in the build.
 *
 * Values follow Apple's: typed getters coerce and give 0/nil when the
 * coercion fails, except enumCodeValue and typeCodeValue, which then read
 * the descriptor's first four bytes; strings are typeUnicodeText; dates
 * are typeLongDateTime (local time, seconds since 1904); the description is
 * AEPrintDescToHandle's text, read as Mac Roman as Apple's is.
 */
#import <Foundation/Foundation.h>
#include <dlfcn.h>

#define AE_PATH "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/AE.framework/Versions/A/AE"
#define CARBONCORE_PATH \
    "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/CarbonCore.framework/Versions/A/CarbonCore"

__attribute__((visibility("hidden"))) void *
_NSFinchCoreServicesSymbol(const char *name)
{
    static void *ae, *cc;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        ae = dlopen(AE_PATH, RTLD_LAZY);
        cc = dlopen(CARBONCORE_PATH, RTLD_LAZY);
    });
    void *p = ae ? dlsym(ae, name) : NULL;
    if (!p && cc)
        p = dlsym(cc, name);
    if (!p) {
        fprintf(stderr, "Foundation: CoreServices has no %s\n", name);
        abort();
    }
    return p;
}

/* A CoreServices function, typed as the SDK declares it. */
#define CS(fn) ((__typeof__(&fn))_NSFinchCoreServicesSymbol(#fn))

@implementation NSAppleEventDescriptor

+ (BOOL)supportsSecureCoding { return YES; }

- (instancetype)initWithAEDescNoCopy:(const AEDesc *)aeDesc
{
    if ((self = [super init])) {
        if (aeDesc)
            _desc = *aeDesc;
        else
            _desc = (AEDesc){typeNull, NULL};
        _hasValidDesc = YES;
    }
    return self;
}

- (instancetype)init
{
    AEDesc descriptor = {typeNull, NULL};
    return [self initWithAEDescNoCopy:&descriptor];
}

- (instancetype)initWithDescriptorType:(DescType)descriptorType bytes:(const void *)bytes length:(NSUInteger)byteCount
{
    AEDesc d;
    if (CS(AECreateDesc)(descriptorType, bytes, (Size)byteCount, &d)) {
        [self release];
        return nil;
    }
    return [self initWithAEDescNoCopy:&d];
}

- (instancetype)initWithDescriptorType:(DescType)descriptorType data:(NSData *)data
{
    return [self initWithDescriptorType:descriptorType bytes:data.bytes length:data.length];
}

- (instancetype)initWithEventClass:(AEEventClass)eventClass eventID:(AEEventID)eventID
                  targetDescriptor:(NSAppleEventDescriptor *)targetDescriptor returnID:(AEReturnID)returnID
                     transactionID:(AETransactionID)transactionID
{
    AppleEvent e;
    if (CS(AECreateAppleEvent)(eventClass, eventID, targetDescriptor ? targetDescriptor.aeDesc : NULL, returnID,
                               transactionID, &e)) {
        [self release];
        return nil;
    }
    return [self initWithAEDescNoCopy:&e];
}

- (instancetype)initListDescriptor
{
    AEDescList l;
    CS(AECreateList)(NULL, 0, false, &l);
    return [self initWithAEDescNoCopy:&l];
}

- (instancetype)initRecordDescriptor
{
    AERecord r;
    CS(AECreateList)(NULL, 0, true, &r);
    return [self initWithAEDescNoCopy:&r];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    DescType type = (DescType)[coder decodeInt32ForKey:@"NSAEDescriptorType"];
    NSData *data = [coder decodeObjectOfClass:[NSData class] forKey:@"NSAEDescriptorData"];
    return [self initWithDescriptorType:type data:data];
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeInt32:(int32_t)_desc.descriptorType forKey:@"NSAEDescriptorType"];
    [coder encodeObject:self.data forKey:@"NSAEDescriptorData"];
}

- (void)dealloc
{
    if (_hasValidDesc && _desc.dataHandle)
        CS(AEDisposeDesc)(&_desc);
    [super dealloc];
}

/* For NSAppleEventManager: the descriptor borrowed its AEDesc and mustn't dispose of it. */
- (void)_finchRelinquishDesc
{
    _hasValidDesc = NO;
}

- (id)copyWithZone:(NSZone *)zone
{
    AEDesc d;
    CS(AEDuplicateDesc)(&_desc, &d);
    return [[NSAppleEventDescriptor allocWithZone:zone] initWithAEDescNoCopy:&d];
}

#pragma mark - Making

+ (NSAppleEventDescriptor *)nullDescriptor
{
    return [[[self alloc] init] autorelease];
}

+ (NSAppleEventDescriptor *)descriptorWithDescriptorType:(DescType)descriptorType bytes:(const void *)bytes length:(NSUInteger)byteCount
{
    return [[[self alloc] initWithDescriptorType:descriptorType bytes:bytes length:byteCount] autorelease];
}

+ (NSAppleEventDescriptor *)descriptorWithDescriptorType:(DescType)descriptorType data:(NSData *)data
{
    return [[[self alloc] initWithDescriptorType:descriptorType data:data] autorelease];
}

+ (NSAppleEventDescriptor *)descriptorWithBoolean:(Boolean)boolean
{
    Boolean b = boolean ? 1 : 0;
    return [self descriptorWithDescriptorType:typeBoolean bytes:&b length:1];
}

+ (NSAppleEventDescriptor *)descriptorWithEnumCode:(OSType)enumerator
{
    return [self descriptorWithDescriptorType:typeEnumerated bytes:&enumerator length:4];
}

+ (NSAppleEventDescriptor *)descriptorWithInt32:(SInt32)signedInt
{
    return [self descriptorWithDescriptorType:typeSInt32 bytes:&signedInt length:4];
}

+ (NSAppleEventDescriptor *)descriptorWithDouble:(double)doubleValue
{
    return [self descriptorWithDescriptorType:typeIEEE64BitFloatingPoint bytes:&doubleValue length:8];
}

+ (NSAppleEventDescriptor *)descriptorWithTypeCode:(OSType)typeCode
{
    return [self descriptorWithDescriptorType:typeType bytes:&typeCode length:4];
}

+ (NSAppleEventDescriptor *)descriptorWithString:(NSString *)string
{
    NSUInteger n = string.length;
    unichar *u = malloc((n ? n : 1) * sizeof *u);
    [string getCharacters:u range:NSMakeRange(0, n)];
    NSAppleEventDescriptor *d = [self descriptorWithDescriptorType:typeUnicodeText bytes:u length:n * sizeof *u];
    free(u);
    return d;
}

static SInt64
local_offset(NSDate *date)
{
    return [[NSTimeZone localTimeZone] secondsFromGMTForDate:date];
}

+ (NSAppleEventDescriptor *)descriptorWithDate:(NSDate *)date
{
    SInt64 ldt = (SInt64)floor(date.timeIntervalSince1970) + 2082844800LL + local_offset(date);
    return [self descriptorWithDescriptorType:typeLongDateTime bytes:&ldt length:8];
}

+ (NSAppleEventDescriptor *)descriptorWithFileURL:(NSURL *)fileURL
{
    NSData *s = [fileURL.absoluteString dataUsingEncoding:NSUTF8StringEncoding];
    return [self descriptorWithDescriptorType:typeFileURL data:s];
}

+ (NSAppleEventDescriptor *)appleEventWithEventClass:(AEEventClass)eventClass eventID:(AEEventID)eventID
                                    targetDescriptor:(NSAppleEventDescriptor *)targetDescriptor returnID:(AEReturnID)returnID
                                       transactionID:(AETransactionID)transactionID
{
    return [[[self alloc] initWithEventClass:eventClass eventID:eventID targetDescriptor:targetDescriptor returnID:returnID
                               transactionID:transactionID] autorelease];
}

+ (NSAppleEventDescriptor *)listDescriptor
{
    return [[[self alloc] initListDescriptor] autorelease];
}

+ (NSAppleEventDescriptor *)recordDescriptor
{
    return [[[self alloc] initRecordDescriptor] autorelease];
}

+ (NSAppleEventDescriptor *)currentProcessDescriptor
{
    ProcessSerialNumber psn = {0, 2 /* kCurrentProcess */};
    return [self descriptorWithDescriptorType:typeProcessSerialNumber bytes:&psn length:sizeof psn];
}

+ (NSAppleEventDescriptor *)descriptorWithProcessIdentifier:(pid_t)processIdentifier
{
    return [self descriptorWithDescriptorType:typeKernelProcessID bytes:&processIdentifier length:sizeof processIdentifier];
}

+ (NSAppleEventDescriptor *)descriptorWithBundleIdentifier:(NSString *)bundleIdentifier
{
    return [self descriptorWithDescriptorType:typeApplicationBundleID data:[bundleIdentifier dataUsingEncoding:NSUTF8StringEncoding]];
}

+ (NSAppleEventDescriptor *)descriptorWithApplicationURL:(NSURL *)applicationURL
{
    return [self descriptorWithDescriptorType:typeApplicationURL
                                         data:[applicationURL.absoluteString dataUsingEncoding:NSUTF8StringEncoding]];
}

#pragma mark - Reading

- (const AEDesc *)aeDesc { return &_desc; }
- (DescType)descriptorType { return _desc.descriptorType; }

- (NSData *)data
{
    Size n = CS(AEGetDescDataSize)(&_desc);
    NSMutableData *d = [NSMutableData dataWithLength:n];
    if (n)
        CS(AEGetDescData)(&_desc, d.mutableBytes, n);
    return d;
}

/* The descriptor's value as a type, or NO. */
- (BOOL)_finchGet:(DescType)type into:(void *)buf size:(Size)size
{
    AEDesc c;
    if (CS(AECoerceDesc)(&_desc, type, &c))
        return NO;
    memset(buf, 0, size);
    CS(AEGetDescData)(&c, buf, size);
    CS(AEDisposeDesc)(&c);
    return YES;
}

- (Boolean)booleanValue
{
    Boolean b = 0;
    if ([self _finchGet:typeBoolean into:&b size:1])
        return b;
    /* Foundation accepts text booleans even when AE has no direct
     * Unicode-to-boolean coercion. Leading spaces are significant. */
    NSString *text = self.stringValue;
    NSCharacterSet *spaces = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    NSUInteger length = text.length;
    while (length && [spaces characterIsMember:[text characterAtIndex:length - 1]])
        length--;
    text = [text substringToIndex:length];
    return text && ([text caseInsensitiveCompare:@"true"] == NSOrderedSame ||
                    [text caseInsensitiveCompare:@"yes"] == NSOrderedSame);
}

- (OSType)_finchCode:(DescType)type
{
    OSType t = 0;
    if ([self _finchGet:type into:&t size:4])
        return t;
    t = 0;
    CS(AEGetDescData)(&_desc, &t, 4);
    return t;
}

- (OSType)enumCodeValue { return [self _finchCode:typeEnumerated]; }
- (OSType)typeCodeValue { return [self _finchCode:typeType]; }

- (SInt32)int32Value
{
    SInt32 v = 0;
    return [self _finchGet:typeSInt32 into:&v size:4] ? v : 0;
}

- (double)doubleValue
{
    double v = 0;
    return [self _finchGet:typeIEEE64BitFloatingPoint into:&v size:8] ? v : 0;
}

- (NSString *)stringValue
{
    AEDesc c;
    if (CS(AECoerceDesc)(&_desc, typeUnicodeText, &c))
        return nil;
    Size n = CS(AEGetDescDataSize)(&c);
    unichar *u = malloc(n ? n : 1);
    CS(AEGetDescData)(&c, u, n);
    CS(AEDisposeDesc)(&c);
    NSString *s = [NSString stringWithCharacters:u length:n / sizeof(unichar)];
    free(u);
    return s;
}

- (NSDate *)dateValue
{
    SInt64 ldt = 0;
    if (![self _finchGet:typeLongDateTime into:&ldt size:8])
        return nil;
    NSDate *guess = [NSDate dateWithTimeIntervalSince1970:(double)(ldt - 2082844800LL)];
    return [NSDate dateWithTimeIntervalSince1970:(double)(ldt - 2082844800LL - local_offset(guess))];
}

- (NSURL *)fileURLValue
{
    AEDesc c;
    if (CS(AECoerceDesc)(&_desc, typeFileURL, &c))
        return nil;
    Size n = CS(AEGetDescDataSize)(&c);
    NSMutableData *d = [NSMutableData dataWithLength:n];
    CS(AEGetDescData)(&c, d.mutableBytes, n);
    CS(AEDisposeDesc)(&c);
    NSString *s = [[[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] autorelease];
    return s ? [NSURL URLWithString:s] : nil;
}

- (OSType)_finchAttribute:(AEKeyword)key type:(DescType)type
{
    AEDesc a;
    if (CS(AEGetAttributeDesc)(&_desc, key, type, &a))
        return 0;
    OSType v = 0;
    CS(AEGetDescData)(&a, &v, type == typeSInt16 ? 2 : 4);
    CS(AEDisposeDesc)(&a);
    return v;
}

- (AEEventClass)eventClass { return [self _finchAttribute:keyEventClassAttr type:typeType]; }
- (AEEventID)eventID { return [self _finchAttribute:keyEventIDAttr type:typeType]; }
- (AEReturnID)returnID { return (AEReturnID)(SInt16)[self _finchAttribute:keyReturnIDAttr type:typeSInt16]; }
- (AETransactionID)transactionID { return (AETransactionID)[self _finchAttribute:keyTransactionIDAttr type:typeSInt32]; }

#pragma mark - Parameters, attributes, items

- (NSAppleEventDescriptor *)_finchWrap:(OSErr)e desc:(AEDesc *)d
{
    return e ? nil : [[[NSAppleEventDescriptor alloc] initWithAEDescNoCopy:d] autorelease];
}

- (void)setParamDescriptor:(NSAppleEventDescriptor *)descriptor forKeyword:(AEKeyword)keyword
{
    CS(AEPutParamDesc)(&_desc, keyword, descriptor.aeDesc);
}

- (NSAppleEventDescriptor *)paramDescriptorForKeyword:(AEKeyword)keyword
{
    AEDesc d;
    OSErr e = CS(AEGetParamDesc)(&_desc, keyword, typeWildCard, &d);
    return [self _finchWrap:e desc:&d];
}

- (void)removeParamDescriptorWithKeyword:(AEKeyword)keyword
{
    CS(AEDeleteParam)(&_desc, keyword);
}

- (void)setAttributeDescriptor:(NSAppleEventDescriptor *)descriptor forKeyword:(AEKeyword)keyword
{
    CS(AEPutAttributeDesc)(&_desc, keyword, descriptor.aeDesc);
}

- (NSAppleEventDescriptor *)attributeDescriptorForKeyword:(AEKeyword)keyword
{
    AEDesc d;
    OSErr e = CS(AEGetAttributeDesc)(&_desc, keyword, typeWildCard, &d);
    return [self _finchWrap:e desc:&d];
}

- (BOOL)isRecordDescriptor
{
    return CS(AECheckIsRecord)(&_desc);
}

- (NSInteger)numberOfItems
{
    long n = 0;
    return CS(AECountItems)(&_desc, &n) ? 0 : n;
}

- (void)insertDescriptor:(NSAppleEventDescriptor *)descriptor atIndex:(NSInteger)index
{
    CS(AEPutDesc)(&_desc, index, descriptor.aeDesc);
}

- (NSAppleEventDescriptor *)descriptorAtIndex:(NSInteger)index
{
    AEDesc d;
    AEKeyword k;
    OSErr e = CS(AEGetNthDesc)(&_desc, index, typeWildCard, &k, &d);
    return [self _finchWrap:e desc:&d];
}

- (void)removeDescriptorAtIndex:(NSInteger)index
{
    CS(AEDeleteItem)(&_desc, index);
}

- (void)setDescriptor:(NSAppleEventDescriptor *)descriptor forKeyword:(AEKeyword)keyword
{
    CS(AEPutParamDesc)(&_desc, keyword, descriptor.aeDesc);
}

- (NSAppleEventDescriptor *)descriptorForKeyword:(AEKeyword)keyword
{
    return [self paramDescriptorForKeyword:keyword];
}

- (void)removeDescriptorWithKeyword:(AEKeyword)keyword
{
    CS(AEDeleteParam)(&_desc, keyword);
}

- (AEKeyword)keywordForDescriptorAtIndex:(NSInteger)index
{
    AEDesc d;
    AEKeyword k = 0;
    if (CS(AEGetNthDesc)(&_desc, index, typeWildCard, &k, &d))
        return 0;
    CS(AEDisposeDesc)(&d);
    return k;
}

- (NSAppleEventDescriptor *)coerceToDescriptorType:(DescType)descriptorType
{
    AEDesc d;
    OSErr e = CS(AECoerceDesc)(&_desc, descriptorType, &d);
    return [self _finchWrap:e desc:&d];
}

#pragma mark - Sending

- (NSAppleEventDescriptor *)sendEventWithOptions:(NSAppleEventSendOptions)sendOptions timeout:(NSTimeInterval)timeoutInSeconds
                                           error:(NSError **)error
{
    AppleEvent reply;
    long ticks = timeoutInSeconds == NSAppleEventTimeOutDefault ? kAEDefaultTimeout
                 : timeoutInSeconds == NSAppleEventTimeOutNone   ? kNoTimeOut
                                                                 : (long)(timeoutInSeconds * 60);
    OSStatus e = CS(AESendMessage)(&_desc, &reply, (AESendMode)sendOptions, ticks);
    if (!e && reply.descriptorType != typeNull) {
        SInt32 errn = 0;
        DescType t;
        Size n;
        if (!CS(AEGetParamPtr)(&reply, keyErrorNumber, typeSInt32, &t, &errn, 4, &n) && errn)
            e = errn;
    }
    if (e) {
        if (reply.dataHandle)
            CS(AEDisposeDesc)(&reply);
        if (error)
            *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:e userInfo:nil];
        return nil;
    }
    return [[[NSAppleEventDescriptor alloc] initWithAEDescNoCopy:&reply] autorelease];
}

#pragma mark - Comparing, describing

- (NSString *)_finchPrinted
{
    Handle h = NULL;
    if (CS(AEPrintDescToHandle)(&_desc, &h) || !h)
        return @"";
    NSString *s = [NSString stringWithCString:*h encoding:NSMacOSRomanStringEncoding] ?: @"";
    CS(DisposeHandle)(h);
    return s;
}

- (BOOL)isEqual:(id)other
{
    if (self == other)
        return YES;
    if (![other isKindOfClass:[NSAppleEventDescriptor class]])
        return NO;
    NSAppleEventDescriptor *o = other;
    return o.descriptorType == self.descriptorType && [o.data isEqual:self.data] && [o._finchPrinted isEqual:self._finchPrinted];
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<NSAppleEventDescriptor: %@>", [self _finchPrinted]];
}

@end
