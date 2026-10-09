/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Host tool (macOS only, not part of Finch): writes UTTypeTable.inc from the system's
 * declared types, the core-type constants listed in names.txt (UTCoreTypes.h's
 * UTType constants) and the types common filename extensions map to.
 *
 *   xcrun clang -fobjc-arc gen-types.m -framework Foundation -framework UniformTypeIdentifiers -o gen
 *   grep -oE "UTType \*const (UTType[A-Za-z0-9]+)" .../UTCoreTypes.h | awk '{print $3}' | sort -u > names.txt
 *   ./gen > table
 */
#import <Foundation/Foundation.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <dlfcn.h>
static NSString *q(NSString *s){ return [NSString stringWithFormat:@"\"%@\"", [[s stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"] stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""]]; }
int main(int argc,char**argv){@autoreleasepool{
 NSMutableOrderedSet *types=[NSMutableOrderedSet orderedSet]; NSMutableDictionary *constName=[NSMutableDictionary dictionary];
 NSString *names=[NSString stringWithContentsOfFile:@"names.txt" encoding:NSUTF8StringEncoding error:nil];
 for (NSString *n in [names componentsSeparatedByString:@"\n"]) { if(!n.length) continue; UTType *__strong *p=(UTType *__strong *)dlsym(RTLD_DEFAULT, n.UTF8String); if(!p||!*p){fprintf(stderr,"missing %s\n",n.UTF8String);continue;} [types addObject:*p]; constName[(*p).identifier]=n; }
 NSArray *exts=[@"txt text rtf rtfd html htm xhtml xml json yaml yml csv tsv md markdown pdf png jpg jpeg gif bmp tif tiff heic heif webp ico icns svg psd raw dng mp3 m4a aac wav aiff aif flac ogg mid midi mp4 m4v mov avi mkv mpg mpeg 3gp zip gz tgz tar bz2 xz 7z rar dmg iso pkg app framework bundle plugin kext c h cc cpp cxx hpp m mm swift py rb pl sh zsh bash js mjs ts java kt go rs php sql css scss less doc docx xls xlsx ppt pptx odt ods odp pages numbers key epub ttf otf ttc woff woff2 dfont plist strings stringsdict entitlements nib xib storyboard car log patch diff ics vcf eml webarchive webloc url ps eps exr ktx usd usdz obj stl dae scn reality ipa a dylib o so exe dll jar class wasm" componentsSeparatedByString:@" "];
 for (NSString *e in exts){ UTType *t=[UTType typeWithFilenameExtension:e]; if(t && !t.isDynamic) [types addObject:t]; }
 /* close over supertypes */
 for (NSUInteger i=0;i<types.count;i++) for (UTType *s in [types[i] supertypes]) if(!s.isDynamic) [types addObject:s];
 printf("/* generated: identifier, constant, description, direct parents, extensions, MIME types */\n");
 for (UTType *t in types){
  NSMutableArray *direct=[NSMutableArray array];
  for (UTType *s in t.supertypes){ BOOL ind=NO; for (UTType *o in t.supertypes) if(o!=s && ![o isEqual:s] && [o conformsToType:s]) { ind=YES; break; } if(!ind) [direct addObject:s.identifier]; }
  [direct sortUsingSelector:@selector(compare:)];
  NSArray *ex=t.tags[UTTagClassFilenameExtension]?:@[]; NSArray *mi=t.tags[UTTagClassMIMEType]?:@[];
  printf("    {%s, %s, %s, %s, %s, %s},\n", q(t.identifier).UTF8String, constName[t.identifier]?q(constName[t.identifier]).UTF8String:"NULL", t.localizedDescription?q(t.localizedDescription).UTF8String:"NULL", q([direct componentsJoinedByString:@" "]).UTF8String, q([ex componentsJoinedByString:@" "]).UTF8String, q([mi componentsJoinedByString:@" "]).UTF8String);
 }
}}
