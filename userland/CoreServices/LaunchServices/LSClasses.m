/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * LaunchServices' Objective-C classes that apps use (private on macOS):
 * LSApplicationWorkspace, LSBundleRecord and LSApplicationRecord with
 * LSApplicationState and the lazy property list behind infoDictionary, the
 * older LSBundleProxy/LSApplicationProxy, LSApplicationExtensionRecord,
 * _LSOpenConfiguration and LSOpenWithMenuConstructor, over Finch's
 * application database. Behaviour follows macOS for what apps read: a
 * missing app is an NSOSStatusErrorDomain kLSApplicationNotFoundErr error
 * for records and a proxy that isn't installed; localizedName is
 * CFBundleName; bundleVersion is the CFBundleVersion as a version number
 * ("34" reads "34.0").
 */
#import "LaunchServices_Finch.h"

@interface LSBundleRecord : NSObject {
@protected
    LSFinchApp *_app;
}
- (instancetype)_finchInitWithApp:(LSFinchApp *)app;
@end

@interface LSApplicationRecord : LSBundleRecord
@end

@interface LSBundleProxy : NSObject {
@protected
    LSFinchApp *_app;
    NSString *_identifier;
}
- (instancetype)_finchInitWithApp:(LSFinchApp *)app identifier:(NSString *)identifier;
@end

@interface LSApplicationProxy : LSBundleProxy
+ (instancetype)applicationProxyForIdentifier:(NSString *)identifier;
@end

static id
of_class(id v, Class cls)
{
    return [v isKindOfClass:cls] ? v : nil;
}

#pragma mark - Property lists

@interface _LSLazyPropertyList : NSObject {
    NSDictionary *_plist;
}
+ (instancetype)lazyPropertyListWithPropertyList:(NSDictionary *)plist;
@end

@implementation _LSLazyPropertyList

+ (instancetype)lazyPropertyListWithPropertyList:(NSDictionary *)plist
{
    _LSLazyPropertyList *l = [[[self alloc] init] autorelease];
    l->_plist = [plist copy] ?: [NSDictionary new];
    return l;
}

- (void)dealloc
{
    [_plist release];
    [super dealloc];
}

- (NSDictionary *)propertyList { return _plist; }
- (id)objectForKey:(NSString *)key { return _plist[key]; }
- (id)objectForKey:(NSString *)key ofClass:(Class)cls { return of_class(_plist[key], cls); }

- (id)objectForKey:(NSString *)key ofClass:(Class)cls valuesOfClass:(Class)valueClass
{
    id v = of_class(_plist[key], cls);
    if ([v isKindOfClass:[NSArray class]])
        for (id x in v)
            if (![x isKindOfClass:valueClass])
                return nil;
    if ([v isKindOfClass:[NSDictionary class]])
        for (id k in v)
            if (![v[k] isKindOfClass:valueClass])
                return nil;
    return v;
}

- (NSDictionary *)objectsForKeys:(NSArray *)keys
{
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    for (id k in keys)
        if (_plist[k])
            d[k] = _plist[k];
    return d;
}

@end

static NSString *
version_number(NSString *v)
{
    if (![v isKindOfClass:[NSString class]] || !v.length)
        return nil;
    return [v rangeOfString:@"."].location == NSNotFound ? [v stringByAppendingString:@".0"] : v;
}

#pragma mark - Records

@interface LSApplicationState : NSObject {
    BOOL _installed;
}
@end

@implementation LSApplicationState
- (instancetype)_finchInitInstalled:(BOOL)installed
{
    if ((self = [super init]))
        _installed = installed;
    return self;
}
- (BOOL)isInstalled { return _installed; }
- (BOOL)isValid { return _installed; }
- (BOOL)isPlaceholder { return NO; }
- (BOOL)isDowngraded { return NO; }
- (BOOL)isBlocked { return NO; }
- (BOOL)isRestricted { return NO; }
- (BOOL)isAlwaysAvailable { return NO; }
- (BOOL)isRemovedSystemApp { return NO; }
@end

@implementation LSBundleRecord

- (instancetype)_finchInitWithApp:(LSFinchApp *)app
{
    if (!app) {
        [self release];
        return nil;
    }
    if ((self = [super init]))
        _app = [app retain];
    return self;
}

- (void)dealloc
{
    [_app release];
    [super dealloc];
}

static LSFinchApp *
app_for_identifier(NSString *identifier, NSError **error)
{
    LSFinchApp *a = [_LSApplicationsWithIdentifier(identifier) firstObject];
    if (!a && [[[NSBundle mainBundle] bundleIdentifier] caseInsensitiveCompare:identifier ?: @""] == NSOrderedSame)
        a = _LSApplicationAtPath([[NSBundle mainBundle] bundlePath]);
    if (!a && error)
        *error = _LSError(kLSApplicationNotFoundErr);
    return a;
}

+ (instancetype)bundleRecordWithBundleIdentifier:(NSString *)identifier allowPlaceholder:(BOOL)allow error:(NSError **)error
{
    LSFinchApp *a = app_for_identifier(identifier, error);
    return a ? [[[LSApplicationRecord alloc] _finchInitWithApp:a] autorelease] : nil;
}

+ (instancetype)bundleRecordWithApplicationIdentifier:(NSString *)identifier error:(NSError **)error
{
    return [self bundleRecordWithBundleIdentifier:identifier allowPlaceholder:NO error:error];
}

+ (instancetype)bundleRecordForCurrentProcess
{
    NSString *path = [[NSBundle mainBundle] bundlePath];
    LSFinchApp *a = _LSApplicationAtPath(path);
    return a ? [[[LSApplicationRecord alloc] _finchInitWithApp:a] autorelease] : nil;
}

+ (instancetype)bundleRecordWithURL:(NSURL *)url allowPlaceholder:(BOOL)allow error:(NSError **)error
{
    LSFinchApp *a = _LSApplicationAtPath(url.path);
    if (!a && error)
        *error = _LSError(kLSApplicationNotFoundErr);
    return a ? [[[LSApplicationRecord alloc] _finchInitWithApp:a] autorelease] : nil;
}

- (NSString *)bundleIdentifier { return _app.bundleIdentifier; }
- (NSURL *)URL { return _app.URL; }
- (NSURL *)bundleURL { return _app.URL; }
- (NSURL *)executableURL { return [NSURL fileURLWithPath:_app.executablePath]; }
- (NSString *)localizedName { return _app.name; }
- (NSString *)localizedShortName { return _app.name; }
- (NSString *)localizedNameForContext:(NSString *)context { return _app.name; }
- (NSString *)shortVersionString { return of_class(_app.info[@"CFBundleShortVersionString"], [NSString class]); }
- (NSString *)bundleVersion { return version_number(_app.info[@"CFBundleVersion"]); }
- (NSString *)exactBundleVersion { return of_class(_app.info[@"CFBundleVersion"], [NSString class]); }
- (_LSLazyPropertyList *)infoDictionary { return [_LSLazyPropertyList lazyPropertyListWithPropertyList:_app.info]; }
- (_LSLazyPropertyList *)entitlements { return [_LSLazyPropertyList lazyPropertyListWithPropertyList:@{}]; }
- (NSString *)SDKVersion { return of_class(_app.info[@"DTSDKName"], [NSString class]); }
- (NSURL *)dataContainerURL { return nil; }
- (id)containingBundleRecord { return nil; }
- (NSData *)persistentIdentifier { return [_app.path dataUsingEncoding:NSUTF8StringEncoding]; }
- (NSString *)teamIdentifier { return nil; }
- (BOOL)isPlaceholder { return NO; }
- (BOOL)isEqual:(id)other { return [other isKindOfClass:[LSBundleRecord class]] && [[other URL] isEqual:self.URL]; }
- (NSUInteger)hash { return _app.path.hash; }
- (NSString *)description
{
    return [NSString stringWithFormat:@"<%@ %p> { bundleID = %@, URL = %@ }", [self class], self, self.bundleIdentifier, self.URL];
}

@end

@implementation LSApplicationRecord

- (instancetype)initWithBundleIdentifier:(NSString *)identifier allowPlaceholder:(BOOL)allow error:(NSError **)error
{
    return [self _finchInitWithApp:app_for_identifier(identifier, error)];
}

- (instancetype)initWithBundleIdentifier:(NSString *)identifier error:(NSError **)error
{
    return [self initWithBundleIdentifier:identifier allowPlaceholder:NO error:error];
}

- (instancetype)initWithURL:(NSURL *)url allowPlaceholder:(BOOL)allow error:(NSError **)error
{
    LSFinchApp *a = _LSApplicationAtPath(url.path);
    if (!a && error)
        *error = _LSError(kLSApplicationNotFoundErr);
    return [self _finchInitWithApp:a];
}

- (instancetype)initForCurrentProcess
{
    return [self _finchInitWithApp:_LSApplicationAtPath([[NSBundle mainBundle] bundlePath])];
}

- (LSApplicationState *)applicationState { return [[[LSApplicationState alloc] _finchInitInstalled:YES] autorelease]; }
- (BOOL)isDeletable { return NO; }
- (BOOL)isBlocked { return NO; }
- (BOOL)isLaunchProhibited { return NO; }
- (BOOL)isBeta { return NO; }
- (NSDictionary *)iTunesMetadata { return nil; }
- (NSString *)versionIdentifier { return of_class(_app.info[@"CFBundleVersion"], [NSString class]); }
- (NSArray *)applicationExtensionRecords { return @[]; }
- (NSArray *)claimRecords { return @[]; }

@end

@interface LSApplicationExtensionRecord : LSBundleRecord
@end

@implementation LSApplicationExtensionRecord
- (instancetype)initWithBundleIdentifier:(NSString *)identifier error:(NSError **)error
{
    if (error)
        *error = _LSError(kLSApplicationNotFoundErr);  /* Finch registers no app extensions yet */
    [self release];
    return nil;
}
- (instancetype)initWithURL:(NSURL *)url error:(NSError **)error
{
    return [self initWithBundleIdentifier:nil error:error];
}
- (id)extensionPointRecord { return nil; }
- (NSString *)effectiveBundleIdentifier { return self.bundleIdentifier; }
@end

#pragma mark - Proxies

@implementation LSBundleProxy

- (instancetype)_finchInitWithApp:(LSFinchApp *)app identifier:(NSString *)identifier
{
    if ((self = [super init])) {
        _app = [app retain];
        _identifier = [(app.bundleIdentifier ?: identifier) copy];
    }
    return self;
}

- (void)dealloc
{
    [_app release];
    [_identifier release];
    [super dealloc];
}

+ (instancetype)bundleProxyForIdentifier:(NSString *)identifier
{
    return [LSApplicationProxy applicationProxyForIdentifier:identifier];
}

+ (instancetype)bundleProxyForURL:(NSURL *)url
{
    LSFinchApp *a = _LSApplicationAtPath(url.path);
    return a ? [[[LSApplicationProxy alloc] _finchInitWithApp:a identifier:nil] autorelease] : nil;
}

+ (instancetype)bundleProxyForCurrentProcess
{
    LSFinchApp *a = _LSApplicationAtPath([[NSBundle mainBundle] bundlePath]);
    return [[[LSApplicationProxy alloc] _finchInitWithApp:a identifier:[[NSBundle mainBundle] bundleIdentifier]] autorelease];
}

- (NSString *)bundleIdentifier { return _identifier; }
- (NSURL *)bundleURL { return _app.URL; }
- (NSURL *)bundleExecutableURL { return _app ? [NSURL fileURLWithPath:_app.executablePath] : nil; }
- (NSString *)bundleExecutable { return of_class(_app.info[@"CFBundleExecutable"], [NSString class]); }
- (NSString *)localizedName { return _app.name; }
- (NSString *)localizedShortName { return _app.name; }
- (NSString *)bundleVersion { return of_class(_app.info[@"CFBundleVersion"], [NSString class]); }
- (NSString *)shortVersionString { return of_class(_app.info[@"CFBundleShortVersionString"], [NSString class]); }
- (NSDictionary *)infoDictionary { return _app.info; }
- (id)objectForInfoDictionaryKey:(NSString *)key ofClass:(Class)cls { return of_class(_app.info[key], cls); }
- (NSURL *)dataContainerURL { return nil; }
- (NSDictionary *)entitlements { return @{}; }

@end

@implementation LSApplicationProxy

+ (instancetype)applicationProxyForIdentifier:(NSString *)identifier
{
    return [[[self alloc] _finchInitWithApp:app_for_identifier(identifier, NULL) identifier:identifier] autorelease];
}

+ (instancetype)applicationProxyForBundleURL:(NSURL *)url
{
    LSFinchApp *a = _LSApplicationAtPath(url.path);
    return a ? [[[self alloc] _finchInitWithApp:a identifier:nil] autorelease] : nil;
}

- (LSApplicationState *)appState { return [[[LSApplicationState alloc] _finchInitInstalled:_app != nil] autorelease]; }
- (BOOL)isInstalled { return _app != nil; }
- (NSString *)applicationType { return [_app.path hasPrefix:@"/System/"] ? @"System" : @"User"; }
- (NSString *)applicationIdentifier { return _identifier; }
- (BOOL)isPlaceholder { return NO; }

@end

#pragma mark - Opening

@interface _LSOpenConfiguration : NSObject <NSCopying, NSSecureCoding>
@property (getter=isSensitive) BOOL sensitive;
@property BOOL allowURLOverrides;
@property BOOL ignoreAppLinkEnabledProperty;
@property (copy) NSDictionary *frontBoardOptions;
@property (copy) NSURL *referrerURL;
@end

@implementation _LSOpenConfiguration

+ (BOOL)supportsSecureCoding { return YES; }

- (instancetype)init
{
    if ((self = [super init]))
        _allowURLOverrides = YES;
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    if ((self = [self init])) {
        _sensitive = [coder decodeBoolForKey:@"sensitive"];
        _allowURLOverrides = [coder decodeBoolForKey:@"allowURLOverrides"];
    }
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeBool:_sensitive forKey:@"sensitive"];
    [coder encodeBool:_allowURLOverrides forKey:@"allowURLOverrides"];
}

- (id)copyWithZone:(NSZone *)zone
{
    _LSOpenConfiguration *c = [[[self class] allocWithZone:zone] init];
    c.sensitive = _sensitive;
    c.allowURLOverrides = _allowURLOverrides;
    c.ignoreAppLinkEnabledProperty = _ignoreAppLinkEnabledProperty;
    c.frontBoardOptions = _frontBoardOptions;
    c.referrerURL = _referrerURL;
    return c;
}

- (void)dealloc
{
    [_frontBoardOptions release];
    [_referrerURL release];
    [super dealloc];
}

@end

@interface LSApplicationWorkspace : NSObject
@end

@implementation LSApplicationWorkspace

+ (instancetype)defaultWorkspace
{
    static LSApplicationWorkspace *w;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        w = [[LSApplicationWorkspace alloc] init];
    });
    return w;
}

- (BOOL)applicationIsInstalled:(NSString *)identifier
{
    return app_for_identifier(identifier, NULL) != nil;
}

- (NSArray *)allApplications
{
    NSMutableArray *a = [NSMutableArray array];
    for (LSFinchApp *app in _LSApplications())
        [a addObject:[[[LSApplicationProxy alloc] _finchInitWithApp:app identifier:nil] autorelease]];
    return a;
}

- (NSArray *)allInstalledApplications { return [self allApplications]; }

- (NSArray *)applicationsAvailableForOpeningURL:(NSURL *)url
{
    NSMutableArray *a = [NSMutableArray array];
    NSArray *urls = CFBridgingRelease(LSCopyApplicationURLsForURL((CFURLRef)url, kLSRolesAll));
    for (NSURL *u in urls) {
        LSFinchApp *app = _LSApplicationAtPath(u.path);
        if (app)
            [a addObject:[[[LSApplicationProxy alloc] _finchInitWithApp:app identifier:nil] autorelease]];
    }
    return a;
}

- (NSArray *)applicationsForUserActivityType:(NSString *)type
{
    NSMutableArray *a = [NSMutableArray array];
    for (LSFinchApp *app in _LSApplications()) {
        NSArray *types = of_class(app.info[@"NSUserActivityTypes"], [NSArray class]);
        if ([types containsObject:type])
            [a addObject:[[[LSApplicationProxy alloc] _finchInitWithApp:app identifier:nil] autorelease]];
    }
    return a;
}

- (NSURL *)URLOverrideForURL:(NSURL *)url
{
    return url;
}

- (BOOL)openApplicationWithBundleID:(NSString *)identifier
{
    LSFinchApp *a = app_for_identifier(identifier, NULL);
    return a && _LSLaunch(a, @[], kLSLaunchDefaults, nil, nil, NULL) == noErr;
}

- (BOOL)openURL:(NSURL *)url withOptions:(NSDictionary *)options error:(NSError **)error
{
    OSStatus e = LSOpenCFURLRef((CFURLRef)url, NULL);
    if (e && error)
        *error = _LSError(e);
    return e == noErr;
}

- (BOOL)openURL:(NSURL *)url withOptions:(NSDictionary *)options
{
    return [self openURL:url withOptions:options error:NULL];
}

- (BOOL)openURL:(NSURL *)url
{
    return [self openURL:url withOptions:nil error:NULL];
}

- (BOOL)openSensitiveURL:(NSURL *)url withOptions:(NSDictionary *)options error:(NSError **)error
{
    return [self openURL:url withOptions:options error:error];
}

- (BOOL)openSensitiveURL:(NSURL *)url withOptions:(NSDictionary *)options
{
    return [self openURL:url withOptions:options error:NULL];
}

- (void)openURL:(NSURL *)url configuration:(_LSOpenConfiguration *)configuration
    completionHandler:(void (^)(NSDictionary *result, NSError *error))handler
{
    NSError *error = nil;
    [self openURL:url withOptions:nil error:&error];
    if (handler)
        handler(error ? nil : @{}, error);
}

- (void)openUserActivity:(id)activity usingApplicationRecord:(LSApplicationRecord *)record
           configuration:(_LSOpenConfiguration *)configuration
       completionHandler:(void (^)(BOOL success, NSError *error))handler
{
    LSFinchApp *a = record ? _LSApplicationAtPath([(id)record URL].path) : nil;
    OSStatus e = a ? _LSLaunch(a, @[], kLSLaunchDefaults, nil, nil, NULL) : kLSApplicationNotFoundErr;
    if (handler)
        handler(e == noErr, e ? _LSError(e) : nil);
}

@end

/* Builds Open With menus in AppKit apps; Finch's AppKit has none to fill yet. */
@interface LSOpenWithMenuConstructor : NSObject
@end

@implementation LSOpenWithMenuConstructor
- (instancetype)initWithURLs:(NSArray *)urls { return [super init]; }
- (NSArray *)applicationURLs { return @[]; }
@end
