/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Sharing services and their picker. Finch's services are the ones it can do
 * itself: Copy (the items onto the general pasteboard), Open (URLs, each in
 * the app that opens it) and Email (a mailto: message with the subject,
 * recipients and the items as its body, when an app handles mailto:). The
 * picker shows them as a menu at the given rect, asks its delegate for the
 * list and a service delegate, and tells it the choice. Services Finch has no
 * counterpart for (AirDrop, Messages, the photo apps) aren't offered, and
 * +sharingServiceNamed: answers nil for them.
 */
#import <AppKit/AppKit.h>
#import <objc/runtime.h>

NSSharingServiceName const NSSharingServiceNameComposeEmail = @"com.apple.share.Mail.compose";
NSSharingServiceName const NSSharingServiceNameComposeMessage = @"com.apple.messages.ShareExtension";
NSSharingServiceName const NSSharingServiceNameSendViaAirDrop = @"com.apple.share.AirDrop.send";
NSSharingServiceName const NSSharingServiceNameAddToSafariReadingList = @"com.apple.share.System.add-to-safari-reading-list";
NSSharingServiceName const NSSharingServiceNameAddToIPhoto = @"com.apple.share.System.add-to-iphoto";
NSSharingServiceName const NSSharingServiceNameAddToAperture = @"com.apple.share.System.add-to-aperture";
NSSharingServiceName const NSSharingServiceNameUseAsDesktopPicture = @"com.apple.share.System.set-desktop-image";
NSSharingServiceName const NSSharingServiceNamePostOnFacebook = @"com.apple.share.Facebook.post";
NSSharingServiceName const NSSharingServiceNamePostOnTwitter = @"com.apple.share.Twitter.post";
NSSharingServiceName const NSSharingServiceNamePostOnSinaWeibo = @"com.apple.share.SinaWeibo.post";
NSSharingServiceName const NSSharingServiceNamePostOnTencentWeibo = @"com.apple.share.TencentWeibo.post";
NSSharingServiceName const NSSharingServiceNamePostOnLinkedIn = @"com.apple.share.LinkedIn.post";
NSSharingServiceName const NSSharingServiceNameUseAsTwitterProfileImage = @"com.apple.share.Twitter.set-profile-image";
NSSharingServiceName const NSSharingServiceNameUseAsFacebookProfileImage = @"com.apple.share.Facebook.set-profile-image";
NSSharingServiceName const NSSharingServiceNameUseAsLinkedInProfileImage = @"com.apple.share.LinkedIn.set-profile-image";
NSSharingServiceName const NSSharingServiceNamePostImageOnFlickr = @"com.apple.share.Flickr.post";
NSSharingServiceName const NSSharingServiceNamePostVideoOnVimeo = @"com.apple.share.Video.upload-image-Vimeo";
NSSharingServiceName const NSSharingServiceNamePostVideoOnYouku = @"com.apple.share.Video.upload-Youku";
NSSharingServiceName const NSSharingServiceNamePostVideoOnTudou = @"com.apple.share.Video.upload-Tudou";
NSSharingServiceName const NSSharingServiceNameCloudSharing = @"com.apple.share.CloudSharing";

/* Finch's own services' names. */
static NSString *const FinchSharingServiceNameCopy = @"org.finch.share.copy";
static NSString *const FinchSharingServiceNameOpen = @"org.finch.share.open";

/* An item as text: strings as they are, URLs as their strings, attributed
 * strings' characters; nil for anything else. */
static NSString *text_of(id item)
{
    if ([item isKindOfClass:[NSString class]]) return item;
    if ([item isKindOfClass:[NSURL class]]) return [item absoluteString];
    if ([item isKindOfClass:[NSAttributedString class]]) return [item string];
    return nil;
}

/* Whether -[NSPasteboard writeObjects:] takes the item. */
static BOOL is_writable(id item)
{
    return [item isKindOfClass:[NSString class]] || [item isKindOfClass:[NSURL class]]
        || [item isKindOfClass:[NSPasteboardItem class]] || [item respondsToSelector:@selector(writableTypesForPasteboard:)];
}

@interface NSSharingService ()
- (instancetype)_initWithName:(NSString *)name title:(NSString *)title;
@end

@implementation NSSharingService {
    NSString *_name;
    NSString *_title;
    NSString *_menuItemTitle;
    NSImage *_image;
    NSImage *_alternateImage;
    void (^_handler)(void);
    id<NSSharingServiceDelegate> _delegate;   /* weak */
    NSArray<NSString *> *_recipients;
    NSString *_subject;
    NSString *_messageBody;
    NSURL *_permanentLink;
    NSArray<NSURL *> *_attachmentFileURLs;
}

- (instancetype)initWithTitle:(NSString *)title image:(NSImage *)image alternateImage:(NSImage *)alternateImage
                      handler:(void (^)(void))block
{
    self = [super init];
    if (self) {
        _title = [title copy];
        _menuItemTitle = [title copy];
        _image = [image retain];
        _alternateImage = [alternateImage retain];
        _handler = [block copy];
    }
    return self;
}

- (instancetype)_initWithName:(NSString *)name title:(NSString *)title
{
    self = [super init];
    if (self) {
        _name = [name copy];
        _title = [title copy];
        _menuItemTitle = [title copy];
        _image = [[NSImage alloc] initWithSize:NSMakeSize(16, 16)];
    }
    return self;
}

- (void)dealloc
{
    [_name release];
    [_title release];
    [_menuItemTitle release];
    [_image release];
    [_alternateImage release];
    [_handler release];
    [_recipients release];
    [_subject release];
    [_messageBody release];
    [_permanentLink release];
    [_attachmentFileURLs release];
    [super dealloc];
}

+ (NSSharingService *)sharingServiceNamed:(NSSharingServiceName)serviceName
{
    if ([serviceName isEqual:NSSharingServiceNameComposeEmail])
        return [[[self alloc] _initWithName:serviceName title:@"Email"] autorelease];
    if ([serviceName isEqual:FinchSharingServiceNameCopy])
        return [[[self alloc] _initWithName:serviceName title:@"Copy"] autorelease];
    if ([serviceName isEqual:FinchSharingServiceNameOpen])
        return [[[self alloc] _initWithName:serviceName title:@"Open"] autorelease];
    return nil;
}

+ (NSArray<NSSharingService *> *)sharingServicesForItems:(NSArray *)items
{
    NSMutableArray *services = [NSMutableArray array];
    for (NSString *name in @[ FinchSharingServiceNameCopy, FinchSharingServiceNameOpen, NSSharingServiceNameComposeEmail ]) {
        NSSharingService *service = [self sharingServiceNamed:name];
        if ([service canPerformWithItems:items])
            [services addObject:service];
    }
    return services;
}

- (id<NSSharingServiceDelegate>)delegate { return _delegate; }
- (void)setDelegate:(id<NSSharingServiceDelegate>)delegate { _delegate = delegate; }
- (NSString *)title { return _title; }
- (NSImage *)image { return _image; }
- (NSImage *)alternateImage { return _alternateImage; }
- (NSString *)menuItemTitle { return _menuItemTitle; }
- (void)setMenuItemTitle:(NSString *)title { [_menuItemTitle autorelease]; _menuItemTitle = [title copy]; }
- (NSArray<NSString *> *)recipients { return _recipients; }
- (void)setRecipients:(NSArray<NSString *> *)recipients { [_recipients autorelease]; _recipients = [recipients copy]; }
- (NSString *)subject { return _subject; }
- (void)setSubject:(NSString *)subject { [_subject autorelease]; _subject = [subject copy]; }
- (NSString *)messageBody { return _messageBody; }
- (NSURL *)permanentLink { return _permanentLink; }
- (NSString *)accountName { return nil; }
- (NSArray<NSURL *> *)attachmentFileURLs { return _attachmentFileURLs; }

- (BOOL)canPerformWithItems:(NSArray *)items
{
    if (_handler) return YES;
    if ([_name isEqual:FinchSharingServiceNameCopy]) {
        for (id item in items)
            if (is_writable(item)) return YES;
        return NO;
    }
    if ([_name isEqual:FinchSharingServiceNameOpen]) {
        if (![items count]) return NO;
        for (id item in items)
            if (![item isKindOfClass:[NSURL class]]) return NO;
        return YES;
    }
    if ([_name isEqual:NSSharingServiceNameComposeEmail])
        return [[NSWorkspace sharedWorkspace] URLForApplicationToOpenURL:[NSURL URLWithString:@"mailto:"]] != nil;
    return NO;
}

/* The mailto: URL for the items: the recipients, the subject, and the items'
 * text, a line each, as the body. */
- (NSURL *)_mailtoURLForItems:(NSArray *)items
{
    NSMutableArray *lines = [NSMutableArray array];
    for (id item in items) {
        NSString *text = text_of(item);
        if (text) [lines addObject:text];
    }
    NSURLComponents *components = [[[NSURLComponents alloc] init] autorelease];
    components.scheme = @"mailto";
    components.path = [_recipients componentsJoinedByString:@","] ?: @"";
    NSMutableArray *query = [NSMutableArray array];
    if (_subject) [query addObject:[NSURLQueryItem queryItemWithName:@"subject" value:_subject]];
    if ([lines count]) [query addObject:[NSURLQueryItem queryItemWithName:@"body" value:[lines componentsJoinedByString:@"\n"]]];
    if ([query count]) components.queryItems = query;
    return components.URL;
}

- (void)performWithItems:(NSArray *)items
{
    id<NSSharingServiceDelegate> delegate = _delegate;
    if ([delegate respondsToSelector:@selector(sharingService:willShareItems:)])
        [delegate sharingService:self willShareItems:items];
    BOOL done = NO;
    if (_handler) {
        _handler();
        done = YES;
    } else if ([_name isEqual:FinchSharingServiceNameCopy]) {
        NSMutableArray *writable = [NSMutableArray array];
        for (id item in items)
            if (is_writable(item)) [writable addObject:item];
        NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
        [pasteboard clearContents];
        done = [pasteboard writeObjects:writable];
    } else if ([_name isEqual:FinchSharingServiceNameOpen]) {
        done = YES;
        for (NSURL *url in items)
            done = [[NSWorkspace sharedWorkspace] openURL:url] && done;
    } else if ([_name isEqual:NSSharingServiceNameComposeEmail]) {
        NSMutableArray *lines = [NSMutableArray array];
        for (id item in items) {
            NSString *text = text_of(item);
            if (text) [lines addObject:text];
        }
        [_messageBody release];
        _messageBody = [[lines componentsJoinedByString:@"\n"] copy];
        NSURL *url = [self _mailtoURLForItems:items];
        done = url && [[NSWorkspace sharedWorkspace] openURL:url];
    }
    if (done) {
        if ([delegate respondsToSelector:@selector(sharingService:didShareItems:)])
            [delegate sharingService:self didShareItems:items];
    } else if ([delegate respondsToSelector:@selector(sharingService:didFailToShareItems:error:)]) {
        NSError *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSUserCancelledError userInfo:nil];
        [delegate sharingService:self didFailToShareItems:items error:error];
    }
}

@end

@implementation NSSharingServicePicker {
    NSArray *_items;
    id<NSSharingServicePickerDelegate> _delegate;   /* weak */
    NSArray<NSSharingService *> *_services;          /* shown in the menu */
}

- (instancetype)initWithItems:(NSArray *)items
{
    self = [super init];
    if (self)
        _items = [items copy];
    return self;
}

- (void)dealloc
{
    [_items release];
    [_services release];
    [super dealloc];
}

- (id<NSSharingServicePickerDelegate>)delegate { return _delegate; }
- (void)setDelegate:(id<NSSharingServicePickerDelegate>)delegate { _delegate = delegate; }

/* The services for the items, as the delegate would have them. */
- (NSArray<NSSharingService *> *)_services
{
    NSArray *proposed = [NSSharingService sharingServicesForItems:_items];
    if ([_delegate respondsToSelector:@selector(sharingServicePicker:sharingServicesForItems:proposedSharingServices:)])
        proposed = [_delegate sharingServicePicker:self sharingServicesForItems:_items proposedSharingServices:proposed];
    return proposed;
}

/* A menu of the services, each item performing its service on the items. */
- (NSMenu *)_menu
{
    [_services release];
    _services = [[self _services] copy];
    NSMenu *menu = [[[NSMenu alloc] initWithTitle:@"Share"] autorelease];
    for (NSSharingService *service in _services) {
        NSMenuItem *item = [[[NSMenuItem alloc] initWithTitle:[service menuItemTitle]
                                                       action:@selector(_choose:) keyEquivalent:@""] autorelease];
        item.target = self;
        item.representedObject = service;
        [menu addItem:item];
    }
    return menu;
}

- (void)_choose:(NSMenuItem *)sender
{
    NSSharingService *service = sender.representedObject;
    if ([_delegate respondsToSelector:@selector(sharingServicePicker:delegateForSharingService:)])
        service.delegate = [_delegate sharingServicePicker:self delegateForSharingService:service];
    if ([_delegate respondsToSelector:@selector(sharingServicePicker:didChooseSharingService:)])
        [_delegate sharingServicePicker:self didChooseSharingService:service];
    [service performWithItems:_items];
}

- (void)showRelativeToRect:(NSRect)rect ofView:(NSView *)view preferredEdge:(NSRectEdge)preferredEdge
{
    NSMenu *menu = [self _menu];
    [self retain];   /* the menu's target, until it closes */
    NSPoint at = [view isFlipped] ? NSMakePoint(NSMinX(rect), NSMaxY(rect)) : NSMakePoint(NSMinX(rect), NSMinY(rect));
    BOOL chosen = [menu popUpMenuPositioningItem:nil atLocation:at inView:view];
    if (!chosen && [_delegate respondsToSelector:@selector(sharingServicePicker:didChooseSharingService:)])
        [_delegate sharingServicePicker:self didChooseSharingService:nil];
    [self autorelease];
}

/* Nothing stays open: -showRelativeToRect:... returns when its menu closes. */
- (void)close
{
}

- (NSMenuItem *)standardShareMenuItem
{
    NSMenuItem *item = [[[NSMenuItem alloc] initWithTitle:@"Share" action:NULL keyEquivalent:@""] autorelease];
    item.submenu = [self _menu];
    objc_setAssociatedObject(item, @selector(standardShareMenuItem), self, OBJC_ASSOCIATION_RETAIN);
    return item;
}

@end
