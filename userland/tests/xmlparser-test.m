/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-xmlparser-test: NSXMLParser over libxml2: every delegate callback,
 * namespaces (processed, reported, neither), DTD declarations, entities,
 * CDATA, comments and processing instructions, encodings, streams, files,
 * errors with their codes, messages and positions, and aborting. One event
 * per line, so runs against Apple's Foundation and Finch's can be diffed.
 */
#import <Foundation/Foundation.h>
#include <dlfcn.h>

static NSString *
q(NSString *s)
{
    if (!s) return @"nil";
    /* Temporary files' URLs differ from machine to machine. */
    NSString *tmp = [NSURL fileURLWithPath:NSTemporaryDirectory()].absoluteString;
    if (![tmp isEqual:@"file:///tmp/"])  /* where it is /tmp, the fixed /tmp paths below must show as they are */
        s = [s stringByReplacingOccurrencesOfString:tmp withString:@"file://$TMPDIR/"];
    NSMutableString *m = [NSMutableString stringWithString:@"\""];
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        if (c == '\n') [m appendString:@"\\n"];
        else if (c == '\t') [m appendString:@"\\t"];
        else if (c == '"') [m appendString:@"\\\""];
        else if (c < 0x20 || c > 0x7e) [m appendFormat:@"\\u%04x", c];
        else [m appendFormat:@"%C", c];
    }
    [m appendString:@"\""];
    return m;
}

static NSString *
dict(NSDictionary *d)
{
    NSMutableArray *parts = [NSMutableArray array];
    for (NSString *k in [d.allKeys sortedArrayUsingSelector:@selector(compare:)]) [parts addObject:[NSString stringWithFormat:@"%@=%@", q(k), q(d[k])]];
    return [NSString stringWithFormat:@"{%@}", [parts componentsJoinedByString:@" "]];
}

static NSString *
error_text(NSError *e)
{
    if (!e) return @"nil";
    NSMutableArray *parts = [NSMutableArray array];
    for (NSString *k in [e.userInfo.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        id v = e.userInfo[k];
        [parts addObject:[NSString stringWithFormat:@"%@=%@", k, [v isKindOfClass:[NSString class]] ? q(v) : v]];
    }
    return [NSString stringWithFormat:@"%@ %ld {%@}", e.domain, (long)e.code, [parts componentsJoinedByString:@", "]];
}

/* A delegate that only wants text: CDATA comes as characters. */
@interface TextOnly : NSObject <NSXMLParserDelegate>
@property NSMutableString *text;
@end
@implementation TextOnly
- (void)parser:(NSXMLParser *)p foundCharacters:(NSString *)s { [self.text appendFormat:@"[%@]", s]; }
@end

/* nil, out of the compiler's sight (nonnull arguments). */
static id nothing(void) { return [NSNull null] == nil ? @1 : nil; }

@interface Logger : NSObject <NSXMLParserDelegate>
@property BOOL positions;          /* log line:column with each event */
@property NSString *abortAt;       /* abort when this element starts */
@property NSDictionary *entities;  /* external entities to resolve */
@property BOOL quiet;              /* only errors and the end */
@end

@implementation Logger
- (void)log:(NSXMLParser *)p format:(NSString *)format, ... NS_FORMAT_FUNCTION(2, 3)
{
    va_list ap;
    va_start(ap, format);
    NSString *s = [[NSString alloc] initWithFormat:format arguments:ap];
    va_end(ap);
    if (self.quiet) return;
    if (self.positions) printf("  [%ld:%ld] %s\n", (long)p.lineNumber, (long)p.columnNumber, s.UTF8String);
    else printf("  %s\n", s.UTF8String);
}
- (void)parserDidStartDocument:(NSXMLParser *)p { [self log:p format:@"startDocument"]; }
- (void)parserDidEndDocument:(NSXMLParser *)p { [self log:p format:@"endDocument"]; }
- (void)parser:(NSXMLParser *)p foundNotationDeclarationWithName:(NSString *)name publicID:(NSString *)publicID systemID:(NSString *)systemID
{
    [self log:p format:@"notation %@ %@ %@", q(name), q(publicID), q(systemID)];
}
- (void)parser:(NSXMLParser *)p foundUnparsedEntityDeclarationWithName:(NSString *)name publicID:(NSString *)publicID systemID:(NSString *)systemID notationName:(NSString *)notation
{
    [self log:p format:@"unparsedEntity %@ %@ %@ %@", q(name), q(publicID), q(systemID), q(notation)];
}
- (void)parser:(NSXMLParser *)p foundAttributeDeclarationWithName:(NSString *)name forElement:(NSString *)element type:(NSString *)type defaultValue:(NSString *)value
{
    [self log:p format:@"attributeDecl %@ %@ %@ %@", q(name), q(element), q(type), q(value)];
}
- (void)parser:(NSXMLParser *)p foundElementDeclarationWithName:(NSString *)name model:(NSString *)model
{
    [self log:p format:@"elementDecl %@ %@", q(name), q(model)];
}
- (void)parser:(NSXMLParser *)p foundInternalEntityDeclarationWithName:(NSString *)name value:(NSString *)value
{
    [self log:p format:@"internalEntity %@ %@", q(name), q(value)];
}
- (void)parser:(NSXMLParser *)p foundExternalEntityDeclarationWithName:(NSString *)name publicID:(NSString *)publicID systemID:(NSString *)systemID
{
    [self log:p format:@"externalEntity %@ %@ %@", q(name), q(publicID), q(systemID)];
}
- (void)parser:(NSXMLParser *)p didStartElement:(NSString *)name namespaceURI:(NSString *)uri qualifiedName:(NSString *)qname attributes:(NSDictionary *)attrs
{
    [self log:p format:@"start %@ %@ %@ %@", q(name), q(uri), q(qname), dict(attrs)];
    if ([name isEqualToString:self.abortAt]) {
        [p abortParsing];
        [self log:p format:@"aborted: %@", error_text(p.parserError)];
    }
}
- (void)parser:(NSXMLParser *)p didEndElement:(NSString *)name namespaceURI:(NSString *)uri qualifiedName:(NSString *)qname
{
    [self log:p format:@"end %@ %@ %@", q(name), q(uri), q(qname)];
}
- (void)parser:(NSXMLParser *)p didStartMappingPrefix:(NSString *)prefix toURI:(NSString *)uri { [self log:p format:@"startPrefix %@ %@", q(prefix), q(uri)]; }
- (void)parser:(NSXMLParser *)p didEndMappingPrefix:(NSString *)prefix { [self log:p format:@"endPrefix %@", q(prefix)]; }
- (void)parser:(NSXMLParser *)p foundCharacters:(NSString *)s { [self log:p format:@"characters %@", q(s)]; }
- (void)parser:(NSXMLParser *)p foundIgnorableWhitespace:(NSString *)s { [self log:p format:@"whitespace %@", q(s)]; }
- (void)parser:(NSXMLParser *)p foundProcessingInstructionWithTarget:(NSString *)target data:(NSString *)data
{
    [self log:p format:@"pi %@ %@", q(target), q(data)];
}
- (void)parser:(NSXMLParser *)p foundComment:(NSString *)s { [self log:p format:@"comment %@", q(s)]; }
- (void)parser:(NSXMLParser *)p foundCDATA:(NSData *)d
{
    [self log:p format:@"cdata %@", q([[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding])];
}
- (NSData *)parser:(NSXMLParser *)p resolveExternalEntityName:(NSString *)name systemID:(NSString *)systemID
{
    [self log:p format:@"resolve %@ %@", q(name), q(systemID)];
    return [self.entities[name] dataUsingEncoding:NSUTF8StringEncoding];
}
- (void)parser:(NSXMLParser *)p parseErrorOccurred:(NSError *)e
{
    printf("  error [%ld:%ld] %s current %s\n", (long)p.lineNumber, (long)p.columnNumber, error_text(e).UTF8String,
        p.parserError == e ? "same" : error_text(p.parserError).UTF8String);
}
- (void)parser:(NSXMLParser *)p validationErrorOccurred:(NSError *)e { printf("  validationError %s\n", error_text(e).UTF8String); }
@end

static void
run(NSString *label, NSXMLParser *p, Logger *l)
{
    printf("%s\n", label.UTF8String);
    p.delegate = l;
    BOOL ok = [p parse];
    printf("  => %d %s line %ld column %ld public %s system %s\n", ok, error_text(p.parserError).UTF8String, (long)p.lineNumber,
        (long)p.columnNumber, q(p.publicID).UTF8String, q(p.systemID).UTF8String);
}

static void
parse(NSString *label, NSString *xml, void (^setup)(NSXMLParser *, Logger *))
{
    NSXMLParser *p = [[NSXMLParser alloc] initWithData:[xml dataUsingEncoding:NSUTF8StringEncoding]];
    Logger *l = [Logger new];
    if (setup) setup(p, l);
    run(label, p, l);
}

static NSString *const cvslog =
    @"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
    @"<?xml-stylesheet type='text/css' href='cvslog.css'?>\n"
    @"<cvslog xmlns=\"http://xml.apple.com/cvslog\" version=\"2\">\n"
    @"  <radar:radar xmlns:radar=\"http://xml.apple.com/radar\" radar:id=\"7\" plain=\"p\">\n"
    @"    <radar:bugID>2920186</radar:bugID>\n"
    @"    <radar:title>API/NSXMLParser: there ought to be an NSXMLParser</radar:title>\n"
    @"  </radar:radar>\n"
    @"  <empty/>\n"
    @"</cvslog>\n";

static NSString *const dtd =
    @"<?xml version=\"1.0\"?>\n"
    @"<!DOCTYPE doc [\n"
    @"  <!ELEMENT doc (item*, note?)>\n"
    @"  <!ELEMENT item (#PCDATA|b)*>\n"
    @"  <!ELEMENT note EMPTY>\n"
    @"  <!ELEMENT any ANY>\n"
    @"  <!ELEMENT seq (a, (b | c)+, d?)>\n"
    @"  <!ATTLIST item id ID #REQUIRED kind (big|small) \"small\" ref IDREF #IMPLIED>\n"
    @"  <!ATTLIST note text CDATA #FIXED \"fixed\" names NMTOKENS #IMPLIED ent ENTITY #IMPLIED>\n"
    @"  <!NOTATION gif PUBLIC \"-//GIF//EN\" \"gif.exe\">\n"
    @"  <!NOTATION png SYSTEM \"png.exe\">\n"
    @"  <!ENTITY company \"Finch &amp; Co\">\n"
    @"  <!ENTITY nested \"[&company;]\">\n"
    @"  <!ENTITY logo SYSTEM \"logo.gif\" NDATA gif>\n"
    @"  <!ENTITY chapter SYSTEM \"chapter.xml\">\n"
    @"  <!ENTITY pub PUBLIC \"-//Finch//Pub\" \"pub.xml\">\n"
    @"  <!ENTITY % param \"x\">\n"
    @"]>\n"
    @"<doc>\n"
    @"  <item id=\"a1\">&company; &nested; &lt;&#65;&#x42;&gt; &amp;</item>\n"
    @"  <item id=\"a2\" kind=\"big\">café ☃ &#x1F600;</item>\n"
    @"  <note ent=\"logo\"/>\n"
    @"</doc>\n";

static NSString *const misc =
    @"<?xml version=\"1.0\"?>\n"
    @"<!-- top comment -->\n"
    @"<root a=\"1\" b='two &amp; three' c=\"&#9;tab\">\n"
    @"  text before <![CDATA[ <raw> & stuff ]]> text after\n"
    @"  <?target some data here?>\n"
    @"  <?bare?>\n"
    @"  <!-- inner - comment -->\n"
    @"  <child>a<b>bold</b>c</child>\r\n"
    @"  <x:y xmlns:x=\"urn:x\" x:attr=\"v\" xmlns=\"urn:default\" xmlns:a=\"urn:a\" xmlns:b=\"urn:b\" a:k=\"1\"><z a:q=\"2\"/></x:y>\n"
    @"  <![CDATA[]]>\n"
    @"</root>\n"
    @"<!-- trailing -->\n";

static void
documents(void)
{
    for (int ns = 0; ns < 2; ns++)
        for (int pre = 0; pre < 2; pre++)
            parse([NSString stringWithFormat:@"cvslog namespaces %d prefixes %d", ns, pre], cvslog, ^(NSXMLParser *p, Logger *l) {
                p.shouldProcessNamespaces = ns;
                p.shouldReportNamespacePrefixes = pre;
            });
    parse(@"cvslog positions", cvslog, ^(NSXMLParser *p, Logger *l) { l.positions = YES; });
    parse(@"dtd", dtd, nil);
    parse(@"dtd resolving", dtd, ^(NSXMLParser *p, Logger *l) { p.shouldResolveExternalEntities = YES; });
    parse(@"misc", misc, nil);
    parse(@"misc namespaces", misc, ^(NSXMLParser *p, Logger *l) { p.shouldProcessNamespaces = YES; p.shouldReportNamespacePrefixes = YES; });
    parse(@"misc positions", misc, ^(NSXMLParser *p, Logger *l) { l.positions = YES; });
    parse(@"undefined entity", @"<a>x &undefined; y &other;</a>", ^(NSXMLParser *p, Logger *l) { l.entities = @{ @"other": @"OTHER" }; });
    parse(@"undefined entity in attribute", @"<a v=\"&undef;\">x</a>", nil);
    parse(@"standalone entity", @"<?xml version=\"1.0\" standalone=\"yes\"?><a>&e;</a>", nil);
    parse(@"whitespace", @"<a>\n  <b> </b>\n\t<c/>  </a>", nil);
    parse(@"abort", cvslog, ^(NSXMLParser *p, Logger *l) { l.abortAt = @"radar:bugID"; });
    parse(@"abort first", cvslog, ^(NSXMLParser *p, Logger *l) { l.abortAt = @"cvslog"; });
    parse(@"no delegate", cvslog, ^(NSXMLParser *p, Logger *l) { });
    NSXMLParser *p = [[NSXMLParser alloc] initWithData:[cvslog dataUsingEncoding:NSUTF8StringEncoding]];
    printf("no delegate at all: %d %s\n", [p parse], error_text(p.parserError).UTF8String);
    printf("parse again: %d %s\n", [p parse], error_text(p.parserError).UTF8String);
    printf("defaults ns %d prefixes %d resolve %d policy %lu allowed %s line %ld column %ld\n", p.shouldProcessNamespaces,
        p.shouldReportNamespacePrefixes, p.shouldResolveExternalEntities, (unsigned long)p.externalEntityResolvingPolicy,
        p.allowedExternalEntityURLs.description.UTF8String, (long)p.lineNumber, (long)p.columnNumber);
}

static void
more(void)
{
    TextOnly *t = [TextOnly new];
    t.text = [NSMutableString string];
    NSXMLParser *p = [[NSXMLParser alloc] initWithData:[misc dataUsingEncoding:NSUTF8StringEncoding]];
    p.delegate = t;
    printf("text only: %d %s\n", [p parse], q(t.text).UTF8String);
    p = [[NSXMLParser alloc] initWithData:[@"<a></b>" dataUsingEncoding:NSUTF8StringEncoding]];
    printf("no delegate, error: line %ld %d %s\n", (long)p.lineNumber, [p parse], error_text(p.parserError).UTF8String);
    [p abortParsing];
    p = [[NSXMLParser alloc] initWithData:[@"<a/>" dataUsingEncoding:NSUTF8StringEncoding]];
    [p abortParsing];
    printf("abort before parse: %d %s\n", [p parse], error_text(p.parserError).UTF8String);
    p = [[NSXMLParser alloc] initWithStream:nothing()];
    printf("nil stream: %d %s\n", [p parse], error_text(p.parserError).UTF8String);
    parse(@"empty entity", @"<!DOCTYPE a [<!ENTITY e \"\">]><a>x&e;y</a>", nil);
    NSString *ext = @"/tmp/finch-xmlparser-ext.xml";  /* a fixed path: its length shows in reported columns */
    [@"<inner>from file</inner>" writeToFile:ext atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    NSString *withExt = [NSString stringWithFormat:@"<!DOCTYPE a [<!ENTITY ext SYSTEM \"%@\">]><a>&ext;</a>", [NSURL fileURLWithPath:ext].absoluteString];
    parse(@"external entity, not resolving", withExt, nil);
    parse(@"external entity, resolving", withExt, ^(NSXMLParser *p, Logger *l) { p.shouldResolveExternalEntities = YES; });
    parse(@"external entity, always", withExt, ^(NSXMLParser *p, Logger *l) {
        p.shouldResolveExternalEntities = YES;
        p.externalEntityResolvingPolicy = NSXMLParserResolveExternalEntitiesAlways;
    });
    parse(@"external entity, allowed", withExt, ^(NSXMLParser *p, Logger *l) {
        p.shouldResolveExternalEntities = YES;
        p.allowedExternalEntityURLs = [NSSet setWithObject:[NSURL fileURLWithPath:ext]];
    });
    NSMutableString *late = [NSMutableString stringWithString:@"<list>"];
    for (int i = 0; i < 30000; i++) [late appendFormat:@"<item>%d</item>", i];
    [late appendString:@"<oops></list>"];
    NSXMLParser *lp = [[NSXMLParser alloc] initWithStream:[NSInputStream inputStreamWithData:[late dataUsingEncoding:NSUTF8StringEncoding]]];
    Logger *ll = [Logger new];
    ll.quiet = YES;
    run(@"late error in a stream", lp, ll);
    lp = [[NSXMLParser alloc] initWithData:[late dataUsingEncoding:NSUTF8StringEncoding]];
    ll = [Logger new];
    ll.quiet = YES;
    run(@"late error in data", lp, ll);
}

static void
errors(void)
{
    NSArray *bad = @[@"", @" ", @"<a>", @"<a></b>", @"<a><b></a>", @"<a>&#xZZ;</a>", @"<a>&#99999999;</a>", @"<a>&#0;</a>",
        @"<a b=\"1\" b=\"2\"/>", @"<a b=1/>", @"<a>\n\n  <b>\n</a>", @"text", @"<a/><b/>", @"<a>]]></a>", @"<?xml version=\"2.0\"?><a/>",
        @"<a><!-- -- --></a>", @"<a x:y=\"1\"/>", @"<x:a/>", @"<a>\x01</a>", @"<!DOCTYPE a [<!ELEMENT a (b>]><a/>", @"<a><![CDATA[x</a>",
        @"<a", @"</a>", @"<1a/>", @"<a>&amp</a>", @"<?xml encoding=\"bogus\"?><a/>"];
    for (NSString *xml in bad) {
        for (int ns = 0; ns < 2; ns++)
            parse([NSString stringWithFormat:@"error %@ namespaces %d", q(xml), ns], xml, ^(NSXMLParser *p, Logger *l) {
                p.shouldProcessNamespaces = ns;
                l.positions = YES;
            });
    }
}

static void
encodings_and_sources(void)
{
    NSString *doc = @"<?xml version=\"1.0\" encoding=\"%@\"?><r a=\"é\">café ü</r>";
    NSDictionary *encs = @{ @"ISO-8859-1": @(NSISOLatin1StringEncoding), @"UTF-16": @(NSUTF16StringEncoding),
        @"UTF-16LE": @(NSUTF16LittleEndianStringEncoding), @"windows-1252": @(NSWindowsCP1252StringEncoding), @"UTF-8": @(NSUTF8StringEncoding) };
    for (NSString *name in [encs.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        NSData *d = [[NSString stringWithFormat:doc, name] dataUsingEncoding:[encs[name] unsignedIntegerValue]];
        run([NSString stringWithFormat:@"encoding %@ (%lu bytes)", name, (unsigned long)d.length], [[NSXMLParser alloc] initWithData:d], [Logger new]);
    }
    NSMutableData *bom = [NSMutableData dataWithBytes:"\xef\xbb\xbf" length:3];
    [bom appendData:[@"<r>bom</r>" dataUsingEncoding:NSUTF8StringEncoding]];
    run(@"utf-8 bom", [[NSXMLParser alloc] initWithData:bom], [Logger new]);
    run(@"short", [[NSXMLParser alloc] initWithData:[@"<a/>" dataUsingEncoding:NSUTF8StringEncoding]], [Logger new]);
    run(@"three bytes", [[NSXMLParser alloc] initWithData:[@"<a>" dataUsingEncoding:NSUTF8StringEncoding]], [Logger new]);

    NSMutableString *big = [NSMutableString stringWithString:@"<list>"];
    for (int i = 0; i < 20000; i++) [big appendFormat:@"<item n=\"%d\">value %d &amp; more</item>", i, i];
    [big appendString:@"</list>"];
    NSData *bigData = [big dataUsingEncoding:NSUTF8StringEncoding];
    for (int stream = 0; stream < 2; stream++) {
        NSXMLParser *p = stream ? [[NSXMLParser alloc] initWithStream:[NSInputStream inputStreamWithData:bigData]] : [[NSXMLParser alloc] initWithData:bigData];
        __block NSUInteger starts = 0, chars = 0;
        NSMutableString *text = [NSMutableString string];
        @autoreleasepool {
            Logger *l = [Logger new];
            l.quiet = YES;
            p.delegate = l;
            starts = 0;
            BOOL ok = [p parse];
            printf("big %s: %d %s line %ld column %ld\n", stream ? "stream" : "data", ok, error_text(p.parserError).UTF8String, (long)p.lineNumber, (long)p.columnNumber);
        }
        (void)starts; (void)chars; (void)text;
    }
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"finch-xmlparser-test.xml"];
    [cvslog writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    NSXMLParser *fp = [[NSXMLParser alloc] initWithContentsOfURL:[NSURL fileURLWithPath:path]];
    run(@"file URL", fp, [Logger new]);
    printf("missing file: %s\n", [[NSXMLParser alloc] initWithContentsOfURL:[NSURL fileURLWithPath:@"/nonexistent/x.xml"]] ? "object" : "nil");
    NSXMLParser *mp = [[NSXMLParser alloc] initWithContentsOfURL:[NSURL fileURLWithPath:@"/nonexistent/x.xml"]];
    if (mp) run(@"missing file parse", mp, [Logger new]);
    run(@"stream", [[NSXMLParser alloc] initWithStream:[NSInputStream inputStreamWithData:[misc dataUsingEncoding:NSUTF8StringEncoding]]], [Logger new]);
    run(@"stream error", [[NSXMLParser alloc] initWithStream:[NSInputStream inputStreamWithData:[@"<a><b></a>" dataUsingEncoding:NSUTF8StringEncoding]]], [Logger new]);
    run(@"missing stream", [[NSXMLParser alloc] initWithStream:[NSInputStream inputStreamWithFileAtPath:@"/nonexistent/x.xml"]], [Logger new]);
    printf("domain %s\n", NSXMLParserErrorDomain.UTF8String);
    for (NSString *key in @[@"NSXMLParserErrorMessageKey", @"NSXMLParserErrorLineNumberKey", @"NSXMLParserErrorColumnKey", @"NSXMLParserErrorFileNameKey"]) {
        void *sym = dlsym(RTLD_DEFAULT, key.UTF8String);
        printf("%s %s\n", key.UTF8String, sym ? (*(__unsafe_unretained NSString **)sym).UTF8String : "missing");
    }
}

int
main(int argc, char **argv)
{
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0);
        if (argc < 2 || strcmp(argv[1], "--no-path")) {
            Dl_info info;
            printf("Foundation: %s\n", dladdr((__bridge void *)[NSXMLParser class], &info) ? info.dli_fname : "?");
        }
        documents();
        more();
        errors();
        encodings_and_sources();
    }
    return 0;
}
