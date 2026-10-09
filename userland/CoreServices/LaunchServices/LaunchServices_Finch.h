/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* LaunchServices.framework's internals (userland/CoreServices/LaunchServices). */
#import <Foundation/Foundation.h>
#include "../CarbonCore/CarbonCore_Finch.h"

/* An application bundle the database knows. */
@interface LSFinchApp : NSObject
@property (copy) NSString *path;
@property (copy) NSDictionary *info;
@property (readonly) NSURL *URL;
@property (readonly) NSString *bundleIdentifier;
@property (readonly) NSString *name;            /* CFBundleName, else the file name less .app */
@property (readonly) NSString *executablePath;
@end

/* LSDatabase.m */
NSArray<LSFinchApp *> *_LSApplications(void) FINCH_HIDDEN;
LSFinchApp *_LSApplicationAtPath(NSString *path) FINCH_HIDDEN;  /* in the database or not */
NSArray<LSFinchApp *> *_LSApplicationsWithIdentifier(NSString *bundleID) FINCH_HIDDEN;
/* Apps that open a file of a type (or extension), best first; generic claims ("*", public.data...) only if allowed. */
NSArray<LSFinchApp *> *_LSApplicationsForType(NSString *uti, NSString *ext, LSRolesMask roles, BOOL generic) FINCH_HIDDEN;
NSArray<LSFinchApp *> *_LSApplicationsForScheme(NSString *scheme, LSRolesMask roles) FINCH_HIDDEN;
LSFinchApp *_LSDefaultApplicationForType(NSString *uti, NSString *ext, LSRolesMask roles) FINCH_HIDDEN;
LSFinchApp *_LSDefaultApplicationForScheme(NSString *scheme, LSRolesMask roles) FINCH_HIDDEN;
/* The kind of document an app calls a type (CFBundleTypeName), or nil. */
NSString *_LSDocumentKindForType(NSString *uti, NSString *ext) FINCH_HIDDEN;
/* Type declarations from apps (exported before imported): lowercased identifier -> declaration. */
NSDictionary<NSString *, NSDictionary *> *_LSApplicationTypeDeclarations(void) FINCH_HIDDEN;
NSString *_LSDeclaringApplicationPath(NSString *uti) FINCH_HIDDEN;
OSStatus _LSRegister(NSString *path) FINCH_HIDDEN;
void _LSSetHandler(NSString *key, NSString *value, NSString *bundleID) FINCH_HIDDEN;  /* key: LSHandlerContentType or LSHandlerURLScheme */
NSString *_LSHandler(NSString *key, NSString *value) FINCH_HIDDEN;
BOOL _LSIsApplicationBundle(NSString *path) FINCH_HIDDEN;

/* LSTypes.m */
NSString *_LSTypeOfItem(NSString *path, BOOL *isDirectory, BOOL *isPackage) FINCH_HIDDEN;
BOOL _LSConforms(NSString *type, NSString *to) FINCH_HIDDEN;
NSString *_LSTypeDescription(NSString *type) FINCH_HIDDEN;

/* LSOpen.m */
OSStatus _LSLaunch(LSFinchApp *app, NSArray<NSURL *> *items, LSLaunchFlags flags, NSDictionary *environment, NSArray *arguments, pid_t *pid) FINCH_HIDDEN;
NSError *_LSError(OSStatus status) FINCH_HIDDEN;

/* LSRunning.m */
NSString *_LSBundlePathForExecutable(NSString *path) FINCH_HIDDEN;
NSString *_LSBundlePathForPID(pid_t pid) FINCH_HIDDEN;
NSArray<NSNumber *> *_LSRunningApplicationPIDs(void) FINCH_HIDDEN;
pid_t _LSRunningPIDForApplication(NSString *path) FINCH_HIDDEN;
