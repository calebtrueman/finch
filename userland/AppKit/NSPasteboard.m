/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSPasteboard: for now an in-process one. Each named pasteboard is a list
 * of items, each a map from type to data; strings and property lists are
 * stored as data, as Apple's are. There is no pasteboard server yet, so
 * copying between processes doesn't work. Plain text written as
 * NSPasteboardTypeString also reads back under the old NSStringPboardType,
 * as on macOS.
 */
#import "AppKit_Finch.h"

NSPasteboardName NSPasteboardNameGeneral = @"Apple CFPasteboard general";
NSPasteboardName NSPasteboardNameFont = @"Apple CFPasteboard font";
NSPasteboardName NSPasteboardNameRuler = @"Apple CFPasteboard ruler";
NSPasteboardName NSPasteboardNameFind = @"Apple CFPasteboard find";
NSPasteboardName NSPasteboardNameDrag = @"Apple CFPasteboard drag";

NSPasteboardType const NSPasteboardTypeString = @"public.utf8-plain-text";
NSPasteboardType const NSPasteboardTypePDF = @"com.adobe.pdf";
NSPasteboardType const NSPasteboardTypeTIFF = @"public.tiff";
NSPasteboardType const NSPasteboardTypePNG = @"public.png";
NSPasteboardType const NSPasteboardTypeRTF = @"public.rtf";
NSPasteboardType const NSPasteboardTypeRTFD = @"com.apple.flat-rtfd";
NSPasteboardType const NSPasteboardTypeHTML = @"public.html";
NSPasteboardType const NSPasteboardTypeTabularText = @"public.utf8-tab-separated-values-text";
NSPasteboardType const NSPasteboardTypeFont = @"com.apple.cocoa.pasteboard.character-formatting";
NSPasteboardType const NSPasteboardTypeRuler = @"com.apple.cocoa.pasteboard.paragraph-formatting";
NSPasteboardType const NSPasteboardTypeColor = @"com.apple.cocoa.pasteboard.color";
NSPasteboardType const NSPasteboardTypeSound = @"com.apple.cocoa.pasteboard.sound";
NSPasteboardType const NSPasteboardTypeMultipleTextSelection = @"com.apple.cocoa.pasteboard.multiple-text-selection";
NSPasteboardType const NSPasteboardTypeTextFinderOptions = @"com.apple.cocoa.pasteboard.find-panel-search-options";
NSPasteboardType const NSPasteboardTypeFindPanelSearchOptions = @"com.apple.cocoa.pasteboard.find-panel-search-options";
NSPasteboardType const NSPasteboardTypeURL = @"public.url";
NSPasteboardType const NSPasteboardTypeFileURL = @"public.file-url";

NSPasteboardType NSStringPboardType = @"NSStringPboardType";
NSPasteboardType NSFilenamesPboardType = @"NSFilenamesPboardType";
NSPasteboardType NSTIFFPboardType = @"NeXT TIFF v4.0 pasteboard type";
NSPasteboardType NSRTFPboardType = @"NeXT Rich Text Format v1.0 pasteboard type";
NSPasteboardType NSTabularTextPboardType = @"NeXT tabular text pasteboard type";
NSPasteboardType NSFontPboardType = @"NeXT font pasteboard type";
NSPasteboardType NSRulerPboardType = @"NeXT ruler pasteboard type";
NSPasteboardType NSColorPboardType = @"NSColor pasteboard type";
NSPasteboardType NSRTFDPboardType = @"NeXT RTFD pasteboard type";
NSPasteboardType NSHTMLPboardType = @"Apple HTML pasteboard type";
NSPasteboardType NSURLPboardType = @"Apple URL pasteboard type";
NSPasteboardType NSPDFPboardType = @"Apple PDF pasteboard type";
NSPasteboardType NSVCardPboardType = @"Apple VCard pasteboard type";
NSPasteboardType NSFilesPromisePboardType = @"Apple files promise pasteboard type";
NSPasteboardType NSMultipleTextSelectionPboardType = @"Apple multiple text selection pasteboard type";
NSPasteboardType NSPostScriptPboardType = @"NeXT Encapsulated PostScript v1.2 pasteboard type";
NSPasteboardType NSPICTPboardType = @"Apple PICT pasteboard type";
NSPasteboardType NSInkTextPboardType = @"Apple InkText pasteboard type";
NSPasteboardType NSFileContentsPboardType = @"NXFileContentsPboardType";
NSPasteboardType const NSSoundPboardType = @"NSSoundPboardType";
NSPasteboardType NSFindPanelSearchOptionsPboardType = @"NSFindPanel search options pasteboard type";

NSPasteboardReadingOptionKey const NSPasteboardURLReadingFileURLsOnlyKey = @"NSPasteboardURLReadingFileURLsOnlyKey";
NSPasteboardReadingOptionKey const NSPasteboardURLReadingContentsConformToTypesKey =
    @"NSPasteboardURLReadingContentsConformToTypesKey";

/* The old name a modern type also answers to. */
static NSString *
legacy_type(NSString *type)
{
    if ([type isEqualToString:NSPasteboardTypeString])
        return NSStringPboardType;
    return nil;
}

static NSString *
modern_type(NSString *type)
{
    if ([type isEqualToString:NSStringPboardType])
        return NSPasteboardTypeString;
    return type;
}

@implementation NSPasteboardItem {
    NSMutableDictionary<NSString *, id> *_values;  /* type -> NSData or NSString or a property list */
    NSMutableArray<NSString *> *_order;
}

- (instancetype)init
{
    if ((self = [super init])) {
        _values = [[NSMutableDictionary alloc] init];
        _order = [[NSMutableArray alloc] init];
    }
    return self;
}

- (void)dealloc
{
    [_values release];
    [_order release];
    [super dealloc];
}

- (NSArray<NSPasteboardType> *)types
{
    NSMutableArray *a = [NSMutableArray array];
    for (NSString *t in _order) {
        [a addObject:t];
        NSString *old = legacy_type(t);
        if (old && ![_order containsObject:old])
            [a addObject:old];
    }
    return a;
}

- (NSPasteboardType)availableTypeFromArray:(NSArray<NSPasteboardType> *)types
{
    NSArray *mine = [self types];
    for (NSString *t in types)
        if ([mine containsObject:t])
            return t;
    return nil;
}

static BOOL
set_value(NSPasteboardItem *self, id value, NSString *type)
{
    if (!type)
        return NO;
    type = modern_type(type);
    if (!value) {
        [self->_values removeObjectForKey:type];
        [self->_order removeObject:type];
        return YES;
    }
    if (!self->_values[type])
        [self->_order addObject:type];
    self->_values[type] = value;
    return YES;
}

- (BOOL)setData:(NSData *)data forType:(NSPasteboardType)type { return set_value(self, [[data copy] autorelease], type); }
- (BOOL)setString:(NSString *)string forType:(NSPasteboardType)type { return set_value(self, [[string copy] autorelease], type); }
- (BOOL)setPropertyList:(id)propertyList forType:(NSPasteboardType)type { return set_value(self, propertyList, type); }
- (BOOL)setDataProvider:(id<NSPasteboardItemDataProvider>)dataProvider forTypes:(NSArray<NSPasteboardType> *)types
{
    return NO;
}

- (NSData *)dataForType:(NSPasteboardType)type
{
    id v = _values[modern_type(type)];
    if ([v isKindOfClass:[NSData class]])
        return v;
    if ([v isKindOfClass:[NSString class]])
        return [v dataUsingEncoding:NSUTF8StringEncoding];
    if (v)
        return [NSPropertyListSerialization dataWithPropertyList:v format:NSPropertyListXMLFormat_v1_0 options:0 error:NULL];
    return nil;
}

- (NSString *)stringForType:(NSPasteboardType)type
{
    id v = _values[modern_type(type)];
    if ([v isKindOfClass:[NSString class]])
        return v;
    if ([v isKindOfClass:[NSData class]])
        return [[[NSString alloc] initWithData:v encoding:NSUTF8StringEncoding] autorelease];
    return nil;
}

- (id)propertyListForType:(NSPasteboardType)type
{
    id v = _values[modern_type(type)];
    if ([v isKindOfClass:[NSData class]]) {
        id plist = [NSPropertyListSerialization propertyListWithData:v options:0 format:NULL error:NULL];
        return plist ?: [[[NSString alloc] initWithData:v encoding:NSUTF8StringEncoding] autorelease];
    }
    return v;
}

- (NSArray<NSPasteboardType> *)writableTypesForPasteboard:(NSPasteboard *)pasteboard { return [self types]; }
- (id)pasteboardPropertyListForType:(NSPasteboardType)type { return [self propertyListForType:type]; }
+ (NSArray<NSPasteboardType> *)readableTypesForPasteboard:(NSPasteboard *)pasteboard { return @[]; }

@end

@implementation NSPasteboard {
    NSString *_name;
    NSMutableArray<NSPasteboardItem *> *_items;
    NSInteger _changeCount;
}

static NSMutableDictionary *
pasteboards(void)
{
    static NSMutableDictionary *all;
    if (!all)
        all = [[NSMutableDictionary alloc] init];
    return all;
}

+ (NSPasteboard *)generalPasteboard
{
    return [self pasteboardWithName:NSPasteboardNameGeneral];
}

+ (NSPasteboard *)pasteboardWithName:(NSPasteboardName)name
{
    @synchronized(self) {
        NSPasteboard *pb = pasteboards()[name];
        if (!pb) {
            pb = [[[NSPasteboard alloc] init] autorelease];
            pb->_name = [name copy];
            pb->_items = [[NSMutableArray alloc] init];
            pasteboards()[name] = pb;
        }
        return pb;
    }
}

+ (NSPasteboard *)pasteboardWithUniqueName
{
    return [self pasteboardWithName:[[NSUUID UUID] UUIDString]];
}

- (void)dealloc
{
    [_name release];
    [_items release];
    [super dealloc];
}

- (NSPasteboardName)name { return _name; }
- (NSInteger)changeCount { return _changeCount; }
- (void)releaseGlobally { [pasteboards() removeObjectForKey:_name]; }
- (NSInteger)prepareForNewContentsWithOptions:(NSPasteboardContentsOptions)options { return [self clearContents]; }

- (NSInteger)clearContents
{
    [_items removeAllObjects];
    return ++_changeCount;
}

- (NSInteger)declareTypes:(NSArray<NSPasteboardType> *)newTypes owner:(id)newOwner
{
    [self clearContents];
    [_items addObject:[[[NSPasteboardItem alloc] init] autorelease]];
    return _changeCount;
}

- (NSInteger)addTypes:(NSArray<NSPasteboardType> *)newTypes owner:(id)newOwner
{
    if (![_items count])
        [_items addObject:[[[NSPasteboardItem alloc] init] autorelease]];
    return _changeCount;
}

static NSPasteboardItem *
first_item(NSPasteboard *self)
{
    if (![self->_items count])
        [self->_items addObject:[[[NSPasteboardItem alloc] init] autorelease]];
    return self->_items[0];
}

- (BOOL)writeObjects:(NSArray<id<NSPasteboardWriting>> *)objects
{
    for (id o in objects) {
        if ([o isKindOfClass:[NSPasteboardItem class]]) {
            [_items addObject:o];
        } else if ([o isKindOfClass:[NSString class]]) {
            NSPasteboardItem *item = [[[NSPasteboardItem alloc] init] autorelease];
            [item setString:o forType:NSPasteboardTypeString];
            [_items addObject:item];
        } else if ([o isKindOfClass:[NSURL class]]) {
            NSPasteboardItem *item = [[[NSPasteboardItem alloc] init] autorelease];
            [item setString:[o absoluteString] forType:[o isFileURL] ? NSPasteboardTypeFileURL : NSPasteboardTypeURL];
            [_items addObject:item];
        } else if ([o respondsToSelector:@selector(writableTypesForPasteboard:)]) {
            NSPasteboardItem *item = [[[NSPasteboardItem alloc] init] autorelease];
            for (NSString *t in [o writableTypesForPasteboard:self]) {
                id v = [o pasteboardPropertyListForType:t];
                if (v)
                    [item setPropertyList:v forType:t];
            }
            [_items addObject:item];
        } else {
            return NO;
        }
    }
    _changeCount++;
    return YES;
}

- (NSArray<NSPasteboardItem *> *)pasteboardItems { return [[_items copy] autorelease]; }

- (NSArray<NSPasteboardType> *)types
{
    NSMutableArray *a = [NSMutableArray array];
    for (NSPasteboardItem *item in _items)
        for (NSString *t in [item types])
            if (![a containsObject:t])
                [a addObject:t];
    return a;
}

- (NSPasteboardType)availableTypeFromArray:(NSArray<NSPasteboardType> *)types
{
    NSArray *mine = [self types];
    for (NSString *t in types)
        if ([mine containsObject:t])
            return t;
    return nil;
}

- (BOOL)canReadItemWithDataConformingToTypes:(NSArray<NSString *> *)types
{
    return [self availableTypeFromArray:types] != nil;
}

- (BOOL)setData:(NSData *)data forType:(NSPasteboardType)dataType
{
    BOOL ok = [first_item(self) setData:data forType:dataType];
    _changeCount++;
    return ok;
}

- (BOOL)setString:(NSString *)string forType:(NSPasteboardType)dataType
{
    BOOL ok = [first_item(self) setString:string forType:dataType];
    _changeCount++;
    return ok;
}

- (BOOL)setPropertyList:(id)plist forType:(NSPasteboardType)dataType
{
    BOOL ok = [first_item(self) setPropertyList:plist forType:dataType];
    _changeCount++;
    return ok;
}

- (NSData *)dataForType:(NSPasteboardType)dataType
{
    for (NSPasteboardItem *item in _items) {
        NSData *d = [item dataForType:dataType];
        if (d)
            return d;
    }
    return nil;
}

- (NSString *)stringForType:(NSPasteboardType)dataType
{
    for (NSPasteboardItem *item in _items) {
        NSString *s = [item stringForType:dataType];
        if (s)
            return s;
    }
    return nil;
}

- (id)propertyListForType:(NSPasteboardType)dataType
{
    for (NSPasteboardItem *item in _items) {
        id p = [item propertyListForType:dataType];
        if (p)
            return p;
    }
    return nil;
}

- (NSArray *)readObjectsForClasses:(NSArray<Class> *)classArray options:(NSDictionary *)options
{
    NSMutableArray *found = [NSMutableArray array];
    for (NSPasteboardItem *item in _items)
        for (Class c in classArray) {
            if (c == [NSString class] || [c isSubclassOfClass:[NSString class]]) {
                NSString *s = [item stringForType:NSPasteboardTypeString];
                if (s) {
                    [found addObject:s];
                    break;
                }
            } else if (c == [NSURL class]) {
                NSString *s = [item stringForType:NSPasteboardTypeFileURL] ?: [item stringForType:NSPasteboardTypeURL];
                if (s) {
                    [found addObject:[NSURL URLWithString:s]];
                    break;
                }
            }
        }
    return found;
}

- (BOOL)canReadObjectForClasses:(NSArray<Class> *)classArray options:(NSDictionary *)options
{
    return [[self readObjectsForClasses:classArray options:options] count] > 0;
}

- (BOOL)writeFileContents:(NSString *)filename
{
    NSData *d = [NSData dataWithContentsOfFile:filename];
    return d && [self setData:d forType:NSFileContentsPboardType];
}

- (NSString *)readFileContentsType:(NSPasteboardType)type toFile:(NSString *)filename
{
    NSData *d = [self dataForType:type ?: NSFileContentsPboardType];
    return d && [d writeToFile:filename atomically:YES] ? filename : nil;
}

+ (NSArray<NSPasteboardType> *)typesFilterableTo:(NSPasteboardType)type { return type ? @[ type ] : @[]; }

- (NSPasteboardAccessBehavior)accessBehavior { return NSPasteboardAccessBehaviorAlwaysAllow; }

@end

NSPasteboardType
NSCreateFilenamePboardType(NSString *fileType)
{
    return [NSString stringWithFormat:@"NSTypedFilenamesPboardType:%@", fileType];
}

NSPasteboardType
NSCreateFileContentsPboardType(NSString *fileType)
{
    return [NSString stringWithFormat:@"NSTypedFileContentsPboardType:%@", fileType];
}

NSString *
NSGetFileType(NSPasteboardType pboardType)
{
    NSRange r = [pboardType rangeOfString:@":"];
    return r.location == NSNotFound ? nil : [pboardType substringFromIndex:NSMaxRange(r)];
}

NSArray<NSString *> *
NSGetFileTypes(NSArray<NSPasteboardType> *pboardTypes)
{
    NSMutableArray *a = [NSMutableArray array];
    for (NSString *t in pboardTypes) {
        NSString *f = NSGetFileType(t);
        if (f)
            [a addObject:f];
    }
    return [a count] ? a : nil;
}
