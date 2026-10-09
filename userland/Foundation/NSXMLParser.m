/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * NSXMLParser (docs/design/FOUNDATION.md), against the SDK's
 * <Foundation/NSXMLParser.h>, over libxml2's push parser and SAX2 callbacks,
 * as Apple's is (Finch builds Apple's libxml2, userland/oss/libxml2.build.sh).
 * The structure follows swift-corelibs-foundation's XMLParser (Apache 2.0),
 * itself a port of Apple's: data goes to libxml2 in chunks, the first four
 * bytes choosing the encoding; entities are substituted; a delegate may
 * resolve entities the document doesn't declare.
 *
 * As Apple's: the first fatal libxml2 error goes to the delegate with its
 * libxml2 code, message, line and column; the delegate hears nothing more
 * (libxml2 reads on to the end of the data it has), and the parse ends with
 * libxml2's "stopped" code (111); a delegate that aborts gets
 * NSXMLParserDelegateAbortedParseError; text that follows a reference to a
 * declared entity's start is dropped, a quirk of Apple's (and Swift's)
 * entity handling that callers see and so Finch keeps.
 */
#import <Foundation/Foundation.h>
#include <libxml/parser.h>
#include <libxml/parserInternals.h>
#include <libxml/SAX2.h>
#include <libxml/entities.h>
#include <libxml/xmlerror.h>
#include <mach/mach.h>

#include "Foundation_Finch.h"

NSString *const NSXMLParserErrorDomain = @"NSXMLParserErrorDomain";
NSString *const NSXMLParserErrorMessageKey = @"NSXMLParserErrorMessage";
NSString *const NSXMLParserErrorLineNumberKey = @"NSXMLParserErrorLineNumber";
NSString *const NSXMLParserErrorColumnKey = @"NSXMLParserErrorColumn";
NSString *const NSXMLParserErrorFileNameKey = @"NSXMLParserErrorFileName";

/* The parser parsing on this thread (Apple's +currentParser), for the
 * external entity loader, which libxml2 calls without a context. */
static __thread NSXMLParser *current_parser;

static xmlExternalEntityLoader original_loader;

@interface NSXMLParser (FinchPrivate)
- (xmlParserInputPtr)_xmlExternalEntityWithURL:(const char *)url identifier:(const char *)identifier context:(xmlParserCtxtPtr)context
                        originalLoaderFunction:(xmlExternalEntityLoader)loader;
@end

static xmlParserInputPtr
external_entity_loader(const char *url, const char *identifier, xmlParserCtxtPtr context)
{
    NSXMLParser *p = current_parser;
    if (p) return [p _xmlExternalEntityWithURL:url identifier:identifier context:context originalLoaderFunction:original_loader];
    return original_loader(url, identifier, context);
}

static NSString *
utf8(const xmlChar *s)
{
    return s ? [NSString stringWithUTF8String:(const char *)s] : nil;
}

@implementation NSXMLParser {
    id<NSXMLParserDelegate> _delegate;
    NSInputStream *_stream;          /* data, too, is read through a stream */
    NSURL *_url;
    xmlSAXHandler *_saxHandler;
    xmlParserCtxtPtr _parserContext;
    BOOL _processNamespaces, _reportPrefixes, _resolveExternalEntities, _continueAfterFatalError;
    NSError *_error;
    NSMutableArray *_namespaces;
    BOOL _delegateAborted;
    BOOL _haveDetectedEncoding;
    BOOL _shouldStopXMLParser;       /* a fatal error: callbacks end, the parse stops */
    NSMutableData *_bomChunk;
    NSUInteger _chunkSize;
    NSSet *_allowedEntityURLs;
    NSXMLParserExternalEntityResolvingPolicy _externalEntityResolvingPolicy;
}

static void
setup_libxml(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        xmlInitParser();
        original_loader = xmlGetExternalEntityLoader();
        xmlSetExternalEntityLoader(external_entity_loader);
    });
}

+ (NSXMLParser *)currentParser { return current_parser; }
+ (void)setCurrentParser:(NSXMLParser *)parser { current_parser = parser; }

- (instancetype)initWithContentsOfURL:(NSURL *)url
{
    if ([url isFileURL]) {
        NSInputStream *stream = [NSInputStream inputStreamWithURL:url];
        if (!stream) {
            [self release];
            return nil;
        }
        self = [self initWithStream:stream];
    } else {
        NSData *data = [NSData dataWithContentsOfURL:url];
        if (!data) {
            [self release];
            return nil;
        }
        self = [self initWithData:data];
    }
    if (self) _url = [url copy];
    return self;
}

/* Data is read in one chunk (up to a megabyte); a stream in chunks of 32
 * pages, as Apple's reads them. */
- (instancetype)initWithData:(NSData *)data { return [self _initWithData:data]; }

- (instancetype)_initWithData:(NSData *)data
{
    setup_libxml();
    if ((self = [super init])) {
        _namespaces = [[NSMutableArray alloc] init];
        [self _initializeSAX2Callbacks];
        if (data) {
            _stream = [[NSInputStream alloc] initWithData:data];
            _chunkSize = MIN([data length], (NSUInteger)1 << 20);
        } else {
            _chunkSize = 32 * vm_page_size;
        }
    }
    return self;
}

- (instancetype)initForIncrementalParsing { return [self _initWithData:nil]; }

- (instancetype)initWithStream:(NSInputStream *)stream
{
    if ((self = [self initForIncrementalParsing])) _stream = [stream retain];
    return self;
}

- (void)dealloc
{
    if (_parserContext) {
        if (_parserContext->myDoc) xmlFreeDoc(_parserContext->myDoc);
        _parserContext->myDoc = NULL;
        xmlFreeParserCtxt(_parserContext);
    }
    free(_saxHandler);
    [_stream release];
    [_url release];
    [_error release];
    [_namespaces release];
    [_bomChunk release];
    [_allowedEntityURLs release];
    [super dealloc];
}

- (id<NSXMLParserDelegate>)delegate { return _delegate; }
- (void)setDelegate:(id<NSXMLParserDelegate>)delegate { _delegate = delegate; }
- (BOOL)shouldProcessNamespaces { return _processNamespaces; }
- (void)setShouldProcessNamespaces:(BOOL)b { _processNamespaces = b; }
- (BOOL)shouldReportNamespacePrefixes { return _reportPrefixes; }
- (void)setShouldReportNamespacePrefixes:(BOOL)b { _reportPrefixes = b; }
- (BOOL)shouldResolveExternalEntities { return _resolveExternalEntities; }
- (void)setShouldResolveExternalEntities:(BOOL)b { _resolveExternalEntities = b; }
- (BOOL)shouldContinueAfterFatalError { return _continueAfterFatalError; }
- (void)setShouldContinueAfterFatalError:(BOOL)b { _continueAfterFatalError = b; }
- (NSXMLParserExternalEntityResolvingPolicy)externalEntityResolvingPolicy { return _externalEntityResolvingPolicy; }
- (void)setExternalEntityResolvingPolicy:(NSXMLParserExternalEntityResolvingPolicy)p { _externalEntityResolvingPolicy = p; }
- (NSSet *)allowedExternalEntityURLs { return _allowedEntityURLs; }
- (void)setAllowedExternalEntityURLs:(NSSet *)urls
{
    NSSet *o = _allowedEntityURLs;
    _allowedEntityURLs = [urls copy];
    [o release];
}

- (NSError *)parserError { return _error; }
- (void)_setExpandedParserError:(NSError *)error
{
    NSError *o = _error;
    _error = [error retain];
    [o release];
}
- (void)_setParserError:(NSInteger)code
{
    [self _setExpandedParserError:[NSError errorWithDomain:NSXMLParserErrorDomain code:code userInfo:nil]];
}

- (NSString *)publicID { return nil; }
- (NSString *)systemID { return nil; }
- (NSInteger)lineNumber { return _parserContext ? xmlSAX2GetLineNumber(_parserContext) : 0; }
- (NSInteger)columnNumber { return _parserContext ? xmlSAX2GetColumnNumber(_parserContext) : 0; }

/* MARK: - Namespaces */

/* An element's prefixes (prefix -> URI), reported in the dictionary's
 * order, as Apple's are. */
- (void)_pushNamespaces:(NSDictionary *)prefixes
{
    [_namespaces addObject:prefixes];
    for (NSString *prefix in prefixes)
        if ([_delegate respondsToSelector:@selector(parser:didStartMappingPrefix:toURI:)])
            [_delegate parser:self didStartMappingPrefix:prefix toURI:[prefixes objectForKey:prefix]];
}

- (void)_popNamespaces
{
    NSDictionary *prefixes = [[[_namespaces lastObject] retain] autorelease];
    [_namespaces removeLastObject];
    for (NSString *prefix in prefixes)
        if ([_delegate respondsToSelector:@selector(parser:didEndMappingPrefix:)])
            [_delegate parser:self didEndMappingPrefix:prefix];
}

/* MARK: - SAX callbacks */

#define PARSER ((NSXMLParser *)ctx)
/* After a fatal error libxml2 recovers and goes on to the end of the
 * data, but the delegate hears nothing more (but the end of the document). */
#define RETURN_IF_STOPPED(...) do { if (PARSER->_shouldStopXMLParser) return __VA_ARGS__; } while (0)
#define DELEGATE_DOES(sel) [PARSER->_delegate respondsToSelector:@selector(sel)]

static void
internal_subset(void *ctx, const xmlChar *name, const xmlChar *externalID, const xmlChar *systemID)
{
    RETURN_IF_STOPPED();
    xmlSAX2InternalSubset(PARSER->_parserContext, name, externalID, systemID);
}

static void
external_subset(void *ctx, const xmlChar *name, const xmlChar *externalID, const xmlChar *systemID)
{
    RETURN_IF_STOPPED();
    xmlSAX2ExternalSubset(PARSER->_parserContext, name, externalID, systemID);
}

static int
is_standalone(void *ctx)
{
    xmlDocPtr doc = PARSER->_parserContext->myDoc;
    return doc ? doc->standalone == 1 : 0;
}

static int
has_internal_subset(void *ctx)
{
    xmlDocPtr doc = PARSER->_parserContext->myDoc;
    return doc && doc->intSubset;
}

static int
has_external_subset(void *ctx)
{
    xmlDocPtr doc = PARSER->_parserContext->myDoc;
    return doc && doc->extSubset;
}

static void characters(void *ctx, const xmlChar *ch, int len);

/* Declared entities, then the delegate's. A declared entity referred to
 * in content marks the context, and the next run of characters is
 * dropped (Apple's behaviour). */
static xmlEntityPtr
get_entity(void *ctx, const xmlChar *name)
{
    RETURN_IF_STOPPED(NULL);
    NSXMLParser *p = PARSER;
    xmlParserCtxtPtr c = p->_parserContext;
    xmlEntityPtr entity = xmlGetPredefinedEntity(name);
    if (entity) return entity;
    entity = xmlSAX2GetEntity(c, name);
    if (entity) {
        if (c->instate == XML_PARSER_CONTENT) c->_private = (void *)1;
        return entity;
    }
    if (DELEGATE_DOES(parser:resolveExternalEntityName:systemID:)) {
        NSData *data = [p->_delegate parser:p resolveExternalEntityName:utf8(name) systemID:nil];
        if (c->myDoc && data) characters(ctx, [data bytes], (int)[data length]);
    }
    return NULL;
}

static void
entity_decl(void *ctx, const xmlChar *name, int type, const xmlChar *publicID, const xmlChar *systemID, xmlChar *content)
{
    RETURN_IF_STOPPED();
    NSXMLParser *p = PARSER;
    xmlSAX2EntityDecl(p->_parserContext, name, type, publicID, systemID, content);
    /* (An entity with a value is internal, as Apple's tells them apart.) */
    if (content && *content) {
        if (DELEGATE_DOES(parser:foundInternalEntityDeclarationWithName:value:))
            [p->_delegate parser:p foundInternalEntityDeclarationWithName:utf8(name) value:utf8(content)];
    } else if (p->_resolveExternalEntities) {
        if (DELEGATE_DOES(parser:foundExternalEntityDeclarationWithName:publicID:systemID:))
            [p->_delegate parser:p foundExternalEntityDeclarationWithName:utf8(name) publicID:utf8(publicID) systemID:utf8(systemID)];
    }
}

static void
notation_decl(void *ctx, const xmlChar *name, const xmlChar *publicID, const xmlChar *systemID)
{
    RETURN_IF_STOPPED();
    NSXMLParser *p = PARSER;
    if (DELEGATE_DOES(parser:foundNotationDeclarationWithName:publicID:systemID:))
        [p->_delegate parser:p foundNotationDeclarationWithName:utf8(name) publicID:utf8(publicID) systemID:utf8(systemID)];
}

/* (Apple's gives no type, and no model below.) */
static void
attribute_decl(void *ctx, const xmlChar *element, const xmlChar *name, int type, int def, const xmlChar *defaultValue, xmlEnumerationPtr tree)
{
    if (PARSER->_shouldStopXMLParser) {
        if (tree) xmlFreeEnumeration(tree);
        return;
    }
    NSXMLParser *p = PARSER;
    if (DELEGATE_DOES(parser:foundAttributeDeclarationWithName:forElement:type:defaultValue:))
        [p->_delegate parser:p foundAttributeDeclarationWithName:utf8(name) forElement:utf8(element) type:@"" defaultValue:utf8(defaultValue)];
    if (tree) xmlFreeEnumeration(tree);
}

static void
element_decl(void *ctx, const xmlChar *name, int type, xmlElementContentPtr content)
{
    RETURN_IF_STOPPED();
    NSXMLParser *p = PARSER;
    if (DELEGATE_DOES(parser:foundElementDeclarationWithName:model:))
        [p->_delegate parser:p foundElementDeclarationWithName:utf8(name) model:@""];
}

static void
unparsed_entity_decl(void *ctx, const xmlChar *name, const xmlChar *publicID, const xmlChar *systemID, const xmlChar *notation)
{
    RETURN_IF_STOPPED();
    NSXMLParser *p = PARSER;
    xmlSAX2UnparsedEntityDecl(p->_parserContext, name, publicID, systemID, notation);
    if (DELEGATE_DOES(parser:foundUnparsedEntityDeclarationWithName:publicID:systemID:notationName:))
        [p->_delegate parser:p foundUnparsedEntityDeclarationWithName:utf8(name) publicID:utf8(publicID) systemID:utf8(systemID)
                notationName:utf8(notation)];
}

static void
start_document(void *ctx)
{
    RETURN_IF_STOPPED();
    NSXMLParser *p = PARSER;
    if (DELEGATE_DOES(parserDidStartDocument:)) [p->_delegate parserDidStartDocument:p];
}

static void
end_document(void *ctx)
{
    RETURN_IF_STOPPED();
    NSXMLParser *p = PARSER;
    if (DELEGATE_DOES(parserDidEndDocument:)) [p->_delegate parserDidEndDocument:p];
}

static NSString *
element_name(NSXMLParser *p, const xmlChar *localname, const xmlChar *prefix, const xmlChar *URI, NSString **uri, NSString **qname)
{
    NSString *name = utf8(localname);
    *uri = nil;
    *qname = nil;
    if (p->_processNamespaces) {
        *uri = URI ? utf8(URI) : @"";
        *qname = prefix ? [NSString stringWithFormat:@"%s:%@", prefix, name] : name;
    } else if (prefix) {
        name = [NSString stringWithFormat:@"%s:%@", prefix, name];
    }
    return name;
}

static void
start_element(void *ctx, const xmlChar *localname, const xmlChar *prefix, const xmlChar *URI, int nb_namespaces, const xmlChar **namespaces,
    int nb_attributes, int nb_defaulted, const xmlChar **attributes)
{
    RETURN_IF_STOPPED();
    NSXMLParser *p = PARSER;
    NSMutableDictionary *attrs = [NSMutableDictionary dictionary];
    NSMutableDictionary *mappings = [NSMutableDictionary dictionary];
    for (int i = 0; i < nb_namespaces; i++) {
        const xmlChar *ns = namespaces[2 * i], *href = namespaces[2 * i + 1];
        NSString *value = href ? utf8(href) : @"";
        if (p->_reportPrefixes) [mappings setObject:value forKey:ns ? utf8(ns) : @""];
        if (!p->_processNamespaces) [attrs setObject:value forKey:ns ? [NSString stringWithFormat:@"xmlns:%s", ns] : @"xmlns"];
    }
    if (p->_reportPrefixes) [p _pushNamespaces:mappings];
    for (int i = 0; i < nb_attributes; i++) {
        const xmlChar **a = attributes + 5 * i;
        if (!a[0]) continue;
        NSString *name = utf8(a[0]);
        if (a[1] && *a[1]) name = [NSString stringWithFormat:@"%s:%@", a[1], name];
        NSString *value = @"";
        if (a[3] && a[4] > a[3])
            value = [[[NSString alloc] initWithBytes:a[3] length:a[4] - a[3] encoding:NSUTF8StringEncoding] autorelease];
        if (a[3] && a[4]) [attrs setObject:value ? value : @"" forKey:name];
    }
    NSString *uri, *qname;
    NSString *name = element_name(p, localname, prefix, URI, &uri, &qname);
    if (DELEGATE_DOES(parser:didStartElement:namespaceURI:qualifiedName:attributes:))
        [p->_delegate parser:p didStartElement:name namespaceURI:uri qualifiedName:qname attributes:attrs];
}

static void
end_element(void *ctx, const xmlChar *localname, const xmlChar *prefix, const xmlChar *URI)
{
    RETURN_IF_STOPPED();
    NSXMLParser *p = PARSER;
    NSString *uri, *qname;
    NSString *name = element_name(p, localname, prefix, URI, &uri, &qname);
    if (DELEGATE_DOES(parser:didEndElement:namespaceURI:qualifiedName:))
        [p->_delegate parser:p didEndElement:name namespaceURI:uri qualifiedName:qname];
    if (p->_reportPrefixes) [p _popNamespaces];
}

static void
characters(void *ctx, const xmlChar *ch, int len)
{
    RETURN_IF_STOPPED();
    NSXMLParser *p = PARSER;
    xmlParserCtxtPtr c = p->_parserContext;
    if (c->_private == (void *)1) {
        c->_private = NULL;
        return;
    }
    if (DELEGATE_DOES(parser:foundCharacters:)) {
        NSString *s = [[NSString alloc] initWithBytes:ch length:len encoding:NSUTF8StringEncoding];
        if (s) [p->_delegate parser:p foundCharacters:s];
        [s release];
    }
}

static void
processing_instruction(void *ctx, const xmlChar *target, const xmlChar *data)
{
    RETURN_IF_STOPPED();
    NSXMLParser *p = PARSER;
    if (DELEGATE_DOES(parser:foundProcessingInstructionWithTarget:data:))
        [p->_delegate parser:p foundProcessingInstructionWithTarget:utf8(target) data:utf8(data)];
}

static void
cdata_block(void *ctx, const xmlChar *value, int len)
{
    RETURN_IF_STOPPED();
    NSXMLParser *p = PARSER;
    if (DELEGATE_DOES(parser:foundCDATA:)) [p->_delegate parser:p foundCDATA:[NSData dataWithBytes:value length:len]];
    else characters(ctx, value, len);
}

static void
comment(void *ctx, const xmlChar *value)
{
    RETURN_IF_STOPPED();
    NSXMLParser *p = PARSER;
    if (DELEGATE_DOES(parser:foundComment:)) [p->_delegate parser:p foundComment:utf8(value)];
}

/* An NSError for a libxml2 error: its code, line, column and message;
 * once the delegate has aborted, NSXMLParserDelegateAbortedParseError. */
static NSError *
error_from_xml(xmlErrorPtr error, NSXMLParser *p)
{
    if (p->_delegateAborted) return [NSError errorWithDomain:NSXMLParserErrorDomain code:NSXMLParserDelegateAbortedParseError userInfo:nil];
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    [info setObject:[NSNumber numberWithInt:error->line] forKey:NSXMLParserErrorLineNumberKey];
    [info setObject:[NSNumber numberWithInt:error->int2] forKey:NSXMLParserErrorColumnKey];
    NSString *message = error->message ? [NSString stringWithUTF8String:error->message] : nil;
    if (message) [info setObject:message forKey:NSXMLParserErrorMessageKey];
    return [NSError errorWithDomain:NSXMLParserErrorDomain code:error->code userInfo:info];
}

/* The first fatal error goes to the delegate and becomes the parser's.
 * Reported while a chunk is parsed (`deferred`), it stops the parse when
 * libxml2 is done with the chunk, the delegate hearing nothing more till
 * then; at the end of the data, it stops it at once. */
static void
report_error(xmlErrorPtr error, NSXMLParser *p, BOOL deferred)
{
    if (!error || error->level != XML_ERR_FATAL || p->_shouldStopXMLParser) return;
    NSError *e = error_from_xml(error, p);
    if ([p->_delegate respondsToSelector:@selector(parser:parseErrorOccurred:)]) [p->_delegate parser:p parseErrorOccurred:e];
    [p _setExpandedParserError:e];
    if (p->_continueAfterFatalError || p->_delegateAborted) return;
    if (deferred) p->_shouldStopXMLParser = YES;
    else xmlStopParser(p->_parserContext);
}

/* libxml2's structured error handler while a chunk is parsed... */
static void
structured_error(void *ctx, xmlErrorPtr error)
{
    report_error(error, PARSER, YES);
}

/* ...and its SAX error callback otherwise. */
static void
error_callback(void *ctx, const char *message, ...)
{
    report_error(xmlCtxtGetLastError(PARSER->_parserContext), PARSER, NO);
}

- (void)_initializeSAX2Callbacks
{
    _saxHandler = calloc(1, sizeof(xmlSAXHandler));
    _saxHandler->internalSubset = internal_subset;
    _saxHandler->isStandalone = is_standalone;
    _saxHandler->hasInternalSubset = has_internal_subset;
    _saxHandler->hasExternalSubset = has_external_subset;
    _saxHandler->getEntity = get_entity;
    _saxHandler->entityDecl = entity_decl;
    _saxHandler->notationDecl = notation_decl;
    _saxHandler->attributeDecl = attribute_decl;
    _saxHandler->elementDecl = element_decl;
    _saxHandler->unparsedEntityDecl = unparsed_entity_decl;
    _saxHandler->startDocument = start_document;
    _saxHandler->endDocument = end_document;
    _saxHandler->startElementNs = start_element;
    _saxHandler->endElementNs = end_element;
    _saxHandler->characters = characters;
    _saxHandler->processingInstruction = processing_instruction;
    _saxHandler->cdataBlock = cdata_block;
    _saxHandler->comment = comment;
    _saxHandler->externalSubset = external_subset;
    _saxHandler->error = error_callback;
    _saxHandler->initialized = XML_SAX2_MAGIC;
}

/* MARK: - External entities */

- (xmlParserInputPtr)_xmlExternalEntityWithURL:(const char *)urlString identifier:(const char *)identifier context:(xmlParserCtxtPtr)context
                        originalLoaderFunction:(xmlExternalEntityLoader)loader
{
    NSURL *a = nil;
    if (_allowedEntityURLs) {
        a = [NSURL URLWithString:[NSString stringWithUTF8String:urlString]];
        if ([[a scheme] isEqualToString:@"file"]) a = [NSURL fileURLWithPath:[a path]];
        if (a && [_allowedEntityURLs containsObject:a]) return loader(urlString, identifier, context);
    }
    switch (_externalEntityResolvingPolicy) {
    case NSXMLParserResolveExternalEntitiesNever:
        return NULL;
    case NSXMLParserResolveExternalEntitiesNoNetwork:
        return xmlNoNetExternalEntityLoader(urlString, identifier, context);
    case NSXMLParserResolveExternalEntitiesSameOriginOnly:
        if (!_url) break;
        if (!a) a = [NSURL URLWithString:[NSString stringWithUTF8String:urlString]];
        if (!a) break;
        if (![a host] || ![_url host] || ![a port] || ![_url port] || ![a scheme] || ![_url scheme]) return NULL;
        if (![[a host] isEqual:[_url host]] || ![[a port] isEqual:[_url port]] || ![[a scheme] isEqual:[_url scheme]]) return NULL;
        break;
    case NSXMLParserResolveExternalEntitiesAlways:
        break;
    }
    return loader(urlString, identifier, context);
}

/* MARK: - Parsing */

- (BOOL)_handleParseResult:(int)result
{
    if (result == XML_ERR_OK) return YES;
    if (result == -1 && _delegateAborted) {
        NSError *e = [NSError errorWithDomain:NSXMLParserErrorDomain code:NSXMLParserDelegateAbortedParseError userInfo:nil];
        [self _setExpandedParserError:e];
        if ([_delegate respondsToSelector:@selector(parser:parseErrorOccurred:)]) [_delegate parser:self parseErrorOccurred:e];
        return NO;
    }
    xmlErrorPtr last = xmlCtxtGetLastError(_parserContext);
    if (last && last->code == result) [self _setExpandedParserError:error_from_xml(last, self)];
    else [self _setParserError:result];
    return NO;
}

/* Feeds a chunk to libxml2. The first four bytes, which tell the
 * encoding, make the push parser. */
- (BOOL)parseData:(NSData *)data
{
    BOOL ok = YES;
    xmlSetStructuredErrorFunc(self, structured_error);
    if (_haveDetectedEncoding) {
        int result = xmlParseChunk(_parserContext, [data bytes], (int)[data length], 0);
        if (_shouldStopXMLParser) {
            _shouldStopXMLParser = NO;
            xmlStopParser(_parserContext);
            if (result >= -1) result = -1;
        }
        ok = [self _handleParseResult:result];
    } else if ([_bomChunk length] + [data length] < 4) {
        if (!_bomChunk) _bomChunk = [[NSMutableData alloc] init];
        [_bomChunk appendData:data];
    } else {
        NSMutableData *chunk = [NSMutableData dataWithData:_bomChunk ? _bomChunk : [NSData data]];
        [chunk appendData:data];
        xmlSAXHandler *handler = _delegate ? _saxHandler : NULL;
        _parserContext = xmlCreatePushParserCtxt(handler, self, [chunk bytes], 4, NULL);
        int options = XML_PARSE_RECOVER | XML_PARSE_NOENT;
        if ([self shouldResolveExternalEntities]) options |= XML_PARSE_DTDLOAD;
        if (!handler) options |= XML_PARSE_NOERROR | XML_PARSE_NOWARNING;
        xmlCtxtUseOptions(_parserContext, options);
        _haveDetectedEncoding = YES;
        [_bomChunk release];
        _bomChunk = nil;
        /* (Like Apple's, this reports success whatever the rest does:
         * the end of the parse has the final word.) */
        if ([chunk length] != 4) [self parseData:[chunk subdataWithRange:NSMakeRange(4, [chunk length] - 4)]];
    }
    xmlSetStructuredErrorFunc(NULL, NULL);
    return ok;
}

- (BOOL)finishIncrementalParse
{
    return [self _handleParseResult:xmlParseChunk(_parserContext, NULL, 0, 1)];
}

- (BOOL)parseFromStream
{
    BOOL ok = NO;
    current_parser = self;
    if (!_stream) {
        NSDictionary *info = [NSDictionary dictionaryWithObject:@"Could not open data stream" forKey:NSXMLParserErrorMessageKey];
        [self _setExpandedParserError:[NSError errorWithDomain:NSCocoaErrorDomain code:-1 userInfo:info]];
    } else {
        [_stream open];
        uint8_t *buffer = malloc(_chunkSize ? _chunkSize : 1);
        NSInteger n = [_stream read:buffer maxLength:_chunkSize];
        if (n != -1) {
            while (n >= 1) {
                NSData *chunk = [[NSData alloc] initWithBytesNoCopy:buffer length:n freeWhenDone:NO];
                ok = [self parseData:chunk];
                [chunk release];
                n = [_stream read:buffer maxLength:_chunkSize];
            }
            ok = [self finishIncrementalParse];
        }
        free(buffer);
        [_stream close];
    }
    current_parser = nil;
    return ok;
}

- (BOOL)parse
{
    BOOL ok;
    @autoreleasepool {
        ok = [self parseFromStream];
    }
    return ok;
}

- (void)abortParsing
{
    if (_parserContext) {
        xmlStopParser(_parserContext);
        _delegateAborted = YES;
    }
}

@end
