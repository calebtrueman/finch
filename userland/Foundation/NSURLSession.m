/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * The URL loading system: NSURLRequest and NSMutableURLRequest, NSURLResponse and
 * NSHTTPURLResponse, and NSURLSession with its configuration and data and download
 * tasks. Apple's is CFNetwork's, re-exported by Foundation; Finch's lives in
 * Foundation itself and loads:
 *   - file: URLs, by reading the file;
 *   - data: URLs (RFC 2397), base64 or percent-encoded;
 *   - http: and https: URLs over HTTP/1.1 (TLS through OpenSSL, linked privately,
 *     verifying the server against /etc/ssl/cert.pem), following redirects, with
 *     chunked and length-delimited bodies.
 * Tasks run on a private queue; completion handlers and delegate calls go to the
 * session's delegate queue. Caching, cookies, authentication challenges, HTTP/2 and
 * background sessions aren't there yet.
 */
#import <Foundation/Foundation.h>
#include <netdb.h>
#include <openssl/err.h>
#include <openssl/ssl.h>
#include <openssl/x509v3.h>
#include <sys/socket.h>
#include <unistd.h>

const int64_t NSURLSessionTransferSizeUnknown = -1;
const float NSURLSessionTaskPriorityDefault = 0.5f;
const float NSURLSessionTaskPriorityLow = 0.25f;
const float NSURLSessionTaskPriorityHigh = 0.75f;
NSString *const NSURLSessionDownloadTaskResumeData = @"NSURLSessionDownloadTaskResumeData";
NSString *const NSURLSessionUploadTaskResumeData = @"NSURLSessionUploadTaskResumeData";

#pragma mark - NSURLRequest

@implementation NSURLRequest {
  @protected
    NSURL *_URL;
    NSURLRequestCachePolicy _cachePolicy;
    NSTimeInterval _timeout;
    NSURL *_mainDocumentURL;
    NSURLRequestNetworkServiceType _serviceType;
    BOOL _allowsCellular, _allowsExpensive, _allowsConstrained, _handlesCookies, _pipelining, _assumesHTTP3;
    NSString *_method;
    NSMutableDictionary<NSString *, NSString *> *_headers;
    NSData *_body;
    NSInputStream *_bodyStream;
    NSURLRequestAttribution _attribution;
}

+ (BOOL)supportsSecureCoding { return YES; }
+ (instancetype)requestWithURL:(NSURL *)URL { return [[[self alloc] initWithURL:URL] autorelease]; }
+ (instancetype)requestWithURL:(NSURL *)URL cachePolicy:(NSURLRequestCachePolicy)cachePolicy timeoutInterval:(NSTimeInterval)timeout
{
    return [[[self alloc] initWithURL:URL cachePolicy:cachePolicy timeoutInterval:timeout] autorelease];
}

- (instancetype)init { return [self initWithURL:(NSURL *_Nonnull)nil]; }
- (instancetype)initWithURL:(NSURL *)URL { return [self initWithURL:URL cachePolicy:NSURLRequestUseProtocolCachePolicy timeoutInterval:60]; }

- (instancetype)initWithURL:(NSURL *)URL cachePolicy:(NSURLRequestCachePolicy)cachePolicy timeoutInterval:(NSTimeInterval)timeout
{
    if ((self = [super init])) {
        _URL = [URL copy];
        _cachePolicy = cachePolicy;
        _timeout = timeout;
        _allowsCellular = _allowsExpensive = _allowsConstrained = _handlesCookies = YES;
        _method = @"GET";
        _headers = [NSMutableDictionary new];
    }
    return self;
}

- (void)dealloc
{
    [_URL release];
    [_mainDocumentURL release];
    [_method release];
    [_headers release];
    [_body release];
    [_bodyStream release];
    [super dealloc];
}

- (void)_finchCopyTo:(NSURLRequest *)r
{
    r->_URL = [_URL copy];
    r->_cachePolicy = _cachePolicy;
    r->_timeout = _timeout;
    r->_mainDocumentURL = [_mainDocumentURL copy];
    r->_serviceType = _serviceType;
    r->_allowsCellular = _allowsCellular, r->_allowsExpensive = _allowsExpensive, r->_allowsConstrained = _allowsConstrained;
    r->_handlesCookies = _handlesCookies, r->_pipelining = _pipelining, r->_assumesHTTP3 = _assumesHTTP3;
    r->_method = [_method copy];
    r->_headers = [_headers mutableCopy];
    r->_body = [_body copy];
    r->_bodyStream = [_bodyStream retain];
    r->_attribution = _attribution;
}

- (id)copyWithZone:(NSZone *)zone
{
    if ([self class] == [NSURLRequest class])
        return [self retain];
    NSURLRequest *r = [[NSURLRequest allocWithZone:zone] init];
    [r->_headers release];
    [r->_method release];
    [self _finchCopyTo:r];
    return r;
}

- (id)mutableCopyWithZone:(NSZone *)zone
{
    NSMutableURLRequest *r = [[NSMutableURLRequest allocWithZone:zone] init];
    [((NSURLRequest *)r)->_headers release];
    [((NSURLRequest *)r)->_method release];
    [self _finchCopyTo:r];
    return r;
}

- (NSURL *)URL { return _URL; }
- (NSURLRequestCachePolicy)cachePolicy { return _cachePolicy; }
- (NSTimeInterval)timeoutInterval { return _timeout; }
- (NSURL *)mainDocumentURL { return _mainDocumentURL; }
- (NSURLRequestNetworkServiceType)networkServiceType { return _serviceType; }
- (BOOL)allowsCellularAccess { return _allowsCellular; }
- (BOOL)allowsExpensiveNetworkAccess { return _allowsExpensive; }
- (BOOL)allowsConstrainedNetworkAccess { return _allowsConstrained; }
- (BOOL)assumesHTTP3Capable { return _assumesHTTP3; }
- (NSURLRequestAttribution)attribution { return _attribution; }
- (BOOL)requiresDNSSECValidation { return NO; }
- (BOOL)allowsPersistentDNS { return NO; }
- (NSString *)cookiePartitionIdentifier { return nil; }
- (NSString *)HTTPMethod { return _method; }
- (NSDictionary<NSString *, NSString *> *)allHTTPHeaderFields { return [_headers count] ? [[_headers copy] autorelease] : nil; }
- (NSData *)HTTPBody { return _body; }
- (NSInputStream *)HTTPBodyStream { return _bodyStream; }
- (BOOL)HTTPShouldHandleCookies { return _handlesCookies; }
- (BOOL)HTTPShouldUsePipelining { return _pipelining; }

/* Header names compare without case. */
- (NSString *)valueForHTTPHeaderField:(NSString *)field
{
    for (NSString *k in _headers)
        if ([k caseInsensitiveCompare:field] == NSOrderedSame)
            return _headers[k];
    return nil;
}

- (BOOL)isEqual:(id)other
{
    if (other == self)
        return YES;
    if (![other isKindOfClass:[NSURLRequest class]])
        return NO;
    NSURLRequest *o = other;
    return (_URL == o->_URL || [_URL isEqual:o->_URL]) && [_method isEqual:o->_method] &&
           [_headers isEqual:o->_headers] && (_body == o->_body || [_body isEqual:o->_body]) &&
           _cachePolicy == o->_cachePolicy && _timeout == o->_timeout;
}

- (NSUInteger)hash { return [_URL hash] ^ [_method hash]; }

- (NSString *)description { return [NSString stringWithFormat:@"<%@: %p> { URL: %@ }", [self class], self, _URL]; }

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:_URL forKey:@"URL"];
    [coder encodeInteger:(NSInteger)_cachePolicy forKey:@"cachePolicy"];
    [coder encodeDouble:_timeout forKey:@"timeoutInterval"];
    [coder encodeObject:_method forKey:@"HTTPMethod"];
    [coder encodeObject:_headers forKey:@"headers"];
    [coder encodeObject:_body forKey:@"HTTPBody"];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    NSURL *u = [coder decodeObjectOfClass:[NSURL class] forKey:@"URL"];
    if ((self = [self initWithURL:u cachePolicy:(NSURLRequestCachePolicy)[coder decodeIntegerForKey:@"cachePolicy"]
                  timeoutInterval:[coder decodeDoubleForKey:@"timeoutInterval"]])) {
        NSString *m = [coder decodeObjectOfClass:[NSString class] forKey:@"HTTPMethod"];
        if (m) {
            [_method release];
            _method = [m copy];
        }
        NSDictionary *h = [coder decodeObjectOfClasses:[NSSet setWithObjects:[NSDictionary class], [NSString class], nil]
                                                forKey:@"headers"];
        if (h)
            [_headers setDictionary:h];
        _body = [[coder decodeObjectOfClass:[NSData class] forKey:@"HTTPBody"] copy];
    }
    return self;
}

@end

@implementation NSMutableURLRequest

- (void)setURL:(NSURL *)URL
{
    [_URL autorelease];
    _URL = [URL copy];
}
- (void)setCachePolicy:(NSURLRequestCachePolicy)p { _cachePolicy = p; }
- (void)setTimeoutInterval:(NSTimeInterval)t { _timeout = t; }
- (void)setMainDocumentURL:(NSURL *)u
{
    [_mainDocumentURL autorelease];
    _mainDocumentURL = [u copy];
}
- (void)setNetworkServiceType:(NSURLRequestNetworkServiceType)t { _serviceType = t; }
- (void)setAllowsCellularAccess:(BOOL)f { _allowsCellular = f; }
- (void)setAllowsExpensiveNetworkAccess:(BOOL)f { _allowsExpensive = f; }
- (void)setAllowsConstrainedNetworkAccess:(BOOL)f { _allowsConstrained = f; }
- (void)setAssumesHTTP3Capable:(BOOL)f { _assumesHTTP3 = f; }
- (void)setAttribution:(NSURLRequestAttribution)a { _attribution = a; }
- (void)setRequiresDNSSECValidation:(BOOL)f {}
- (void)setAllowsPersistentDNS:(BOOL)f {}
- (void)setCookiePartitionIdentifier:(NSString *)s {}
- (void)setHTTPMethod:(NSString *)m
{
    [_method autorelease];
    _method = [(m ?: @"GET") copy];
}
- (void)setAllHTTPHeaderFields:(NSDictionary<NSString *, NSString *> *)fields
{
    [_headers removeAllObjects];
    for (NSString *k in fields)
        [self setValue:fields[k] forHTTPHeaderField:k];
}
- (void)setValue:(NSString *)value forHTTPHeaderField:(NSString *)field
{
    for (NSString *k in [_headers allKeys])
        if ([k caseInsensitiveCompare:field] == NSOrderedSame)
            [_headers removeObjectForKey:k];
    if (value)
        _headers[field] = value;
}
- (void)addValue:(NSString *)value forHTTPHeaderField:(NSString *)field
{
    NSString *old = [self valueForHTTPHeaderField:field];
    [self setValue:old ? [NSString stringWithFormat:@"%@,%@", old, value] : value forHTTPHeaderField:field];
}
- (void)setHTTPBody:(NSData *)body
{
    [_body autorelease];
    _body = [body copy];
}
- (void)setHTTPBodyStream:(NSInputStream *)s
{
    [_bodyStream autorelease];
    _bodyStream = [s retain];
}
- (void)setHTTPShouldHandleCookies:(BOOL)f { _handlesCookies = f; }
- (void)setHTTPShouldUsePipelining:(BOOL)f { _pipelining = f; }

- (id)copyWithZone:(NSZone *)zone
{
    NSMutableURLRequest *r = [[NSMutableURLRequest allocWithZone:zone] init];
    [((NSURLRequest *)r)->_headers release];
    [((NSURLRequest *)r)->_method release];
    [self _finchCopyTo:r];
    return r;
}

@end

#pragma mark - NSURLResponse

/* The usual extension of a MIME type, for suggested file names. */
static NSString *
extension_for_mime(NSString *type)
{
    static NSDictionary *exts;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      exts = [@{@"text/html" : @"html", @"text/plain" : @"txt", @"application/json" : @"json", @"image/png" : @"png",
                @"image/jpeg" : @"jpeg", @"image/gif" : @"gif", @"application/pdf" : @"pdf", @"text/xml" : @"xml",
                @"application/xml" : @"xml", @"text/css" : @"css", @"text/javascript" : @"js", @"text/rtf" : @"rtf",
                @"image/svg+xml" : @"svg", @"image/heic" : @"heic", @"application/zip" : @"zip", @"text/csv" : @"csv",
                @"application/octet-stream" : @"bin"} retain];
    });
    return type ? exts[[type lowercaseString]] : nil;
}

@implementation NSURLResponse {
  @protected
    NSURL *_URL;
    NSString *_MIMEType, *_encoding;
    long long _length;
}

+ (BOOL)supportsSecureCoding { return YES; }

- (instancetype)initWithURL:(NSURL *)URL MIMEType:(NSString *)MIMEType expectedContentLength:(NSInteger)length
           textEncodingName:(NSString *)name
{
    if ((self = [super init])) {
        _URL = [URL copy];
        _MIMEType = [MIMEType copy];
        _length = length;
        _encoding = [name copy];
    }
    return self;
}

- (void)dealloc
{
    [_URL release];
    [_MIMEType release];
    [_encoding release];
    [super dealloc];
}

- (id)copyWithZone:(NSZone *)zone { return [self retain]; }
- (NSURL *)URL { return _URL; }
- (NSString *)MIMEType { return _MIMEType; }
- (long long)expectedContentLength { return _length; }
- (NSString *)textEncodingName { return _encoding; }

- (NSString *)suggestedFilename
{
    NSString *name = [[_URL path] lastPathComponent];
    if (![name length] || [name isEqualToString:@"/"])
        name = [_URL host] ?: @"Unknown";
    if ([name isEqualToString:@"Unknown"])
        return name;
    if (![[name pathExtension] length] && extension_for_mime(_MIMEType))
        name = [name stringByAppendingPathExtension:extension_for_mime(_MIMEType)];
    return name;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:_URL forKey:@"URL"];
    [coder encodeObject:_MIMEType forKey:@"MIMEType"];
    [coder encodeInt64:_length forKey:@"expectedContentLength"];
    [coder encodeObject:_encoding forKey:@"textEncodingName"];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    return [self initWithURL:[coder decodeObjectOfClass:[NSURL class] forKey:@"URL"]
                    MIMEType:[coder decodeObjectOfClass:[NSString class] forKey:@"MIMEType"]
       expectedContentLength:(NSInteger)[coder decodeInt64ForKey:@"expectedContentLength"]
            textEncodingName:[coder decodeObjectOfClass:[NSString class] forKey:@"textEncodingName"]];
}

@end

@implementation NSHTTPURLResponse {
    NSInteger _status;
    NSDictionary *_fields;
}

- (instancetype)initWithURL:(NSURL *)url statusCode:(NSInteger)statusCode HTTPVersion:(NSString *)version
               headerFields:(NSDictionary<NSString *, NSString *> *)fields
{
    NSString *type = nil, *charset = nil;
    NSString *ct = nil;
    for (NSString *k in fields)
        if ([k caseInsensitiveCompare:@"Content-Type"] == NSOrderedSame)
            ct = fields[k];
    if (ct) {
        NSArray *parts = [ct componentsSeparatedByString:@";"];
        type = [[parts[0] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] lowercaseString];
        for (NSString *p in parts) {
            NSString *t = [p stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if ([[t lowercaseString] hasPrefix:@"charset="])
                charset = [[t substringFromIndex:8] lowercaseString];
        }
    }
    long long length = -1;
    for (NSString *k in fields)
        if ([k caseInsensitiveCompare:@"Content-Length"] == NSOrderedSame)
            length = [fields[k] longLongValue];
    if ((self = [super initWithURL:url MIMEType:type expectedContentLength:(NSInteger)length textEncodingName:charset])) {
        _status = statusCode;
        _fields = [fields copy] ?: [NSDictionary new];
    }
    return self;
}

- (void)dealloc
{
    [_fields release];
    [super dealloc];
}

- (NSInteger)statusCode { return _status; }

/* A Content-Disposition filename, if the server gave one. */
- (NSString *)suggestedFilename
{
    NSString *cd = [self valueForHTTPHeaderField:@"Content-Disposition"];
    for (NSString *part in [cd componentsSeparatedByString:@";"]) {
        NSString *t = [part stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if ([[t lowercaseString] hasPrefix:@"filename="]) {
            NSString *name = [[t substringFromIndex:9] stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\""]];
            name = [name lastPathComponent];
            if ([name length])
                return name;
        }
    }
    return [super suggestedFilename];
}
- (NSDictionary *)allHeaderFields { return _fields; }

- (NSString *)valueForHTTPHeaderField:(NSString *)field
{
    for (NSString *k in _fields)
        if ([k caseInsensitiveCompare:field] == NSOrderedSame)
            return _fields[k];
    return nil;
}

+ (NSString *)localizedStringForStatusCode:(NSInteger)code
{
    switch (code) {
    case 200: return @"no error";
    case 201: return @"created";
    case 204: return @"no content";
    case 301: return @"moved permanently";
    case 302: return @"found";
    case 304: return @"not modified";
    case 400: return @"bad request";
    case 401: return @"unauthorized";
    case 403: return @"forbidden";
    case 404: return @"not found";
    case 500: return @"internal server error";
    case 503: return @"service unavailable";
    }
    return code < 200 ? @"informational" : code < 300 ? @"success" : code < 400 ? @"redirected" : code < 500 ? @"client error" : @"server error";
}

@end

#pragma mark - Loading

static NSError *
url_error(NSInteger code, NSURL *url, NSString *description)
{
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    if (url) {
        info[NSURLErrorFailingURLErrorKey] = url;
        info[NSURLErrorFailingURLStringErrorKey] = [url absoluteString];
    }
    if (description)
        info[NSLocalizedDescriptionKey] = description;
    return [NSError errorWithDomain:NSURLErrorDomain code:code userInfo:info];
}

/* data:[<mediatype>][;base64],<data> */
static NSData *
load_data_url(NSURL *url, NSURLResponse **response)
{
    NSString *s = [url resourceSpecifier];
    NSRange comma = [s rangeOfString:@","];
    if (comma.location == NSNotFound)
        return nil;
    NSString *meta = [s substringToIndex:comma.location], *payload = [s substringFromIndex:NSMaxRange(comma)];
    BOOL base64 = [meta hasSuffix:@";base64"];
    if (base64)
        meta = [meta substringToIndex:[meta length] - 7];
    NSData *d = base64 ? [[[NSData alloc] initWithBase64EncodedString:[payload stringByRemovingPercentEncoding] ?: payload
                                                              options:NSDataBase64DecodingIgnoreUnknownCharacters] autorelease]
                       : [[payload stringByRemovingPercentEncoding] dataUsingEncoding:NSUTF8StringEncoding];
    NSArray *parts = [meta componentsSeparatedByString:@";"];
    NSString *type = [parts[0] length] ? parts[0] : @"text/plain";
    NSString *charset = nil;
    for (NSString *p in parts)
        if ([p hasPrefix:@"charset="])
            charset = [p substringFromIndex:8];
    *response = [[[NSURLResponse alloc] initWithURL:url MIMEType:type expectedContentLength:(NSInteger)[d length]
                                   textEncodingName:charset] autorelease];
    return d;
}

static NSString *
mime_for_extension(NSString *ext)
{
    static NSDictionary *types;
    if (!types)
        types = [@{@"html" : @"text/html", @"htm" : @"text/html", @"txt" : @"text/plain", @"json" : @"application/json",
                   @"png" : @"image/png", @"jpg" : @"image/jpeg", @"jpeg" : @"image/jpeg", @"gif" : @"image/gif",
                   @"pdf" : @"application/pdf", @"xml" : @"text/xml", @"css" : @"text/css", @"js" : @"text/javascript",
                   @"rtf" : @"text/rtf", @"svg" : @"image/svg+xml", @"heic" : @"image/heic"} retain];
    return types[[ext lowercaseString]] ?: @"application/octet-stream";
}

/* An HTTP/1.1 connection: a socket, and OpenSSL over it for https. */
typedef struct {
    int fd;
    SSL *ssl;
    SSL_CTX *ctx;
} Connection;

static ssize_t
conn_read(Connection *c, void *buf, size_t n)
{
    return c->ssl ? SSL_read(c->ssl, buf, (int)n) : read(c->fd, buf, n);
}

static BOOL
conn_write(Connection *c, const void *buf, size_t n)
{
    const char *p = buf;
    while (n) {
        ssize_t w = c->ssl ? SSL_write(c->ssl, p, (int)n) : write(c->fd, p, n);
        if (w <= 0)
            return NO;
        p += w;
        n -= (size_t)w;
    }
    return YES;
}

static void
conn_close(Connection *c)
{
    if (c->ssl) {
        SSL_shutdown(c->ssl);
        SSL_free(c->ssl);
    }
    if (c->ctx)
        SSL_CTX_free(c->ctx);
    if (c->fd >= 0)
        close(c->fd);
}

/* OpenSSL is built without sockets (no-sock), so TLS runs over a BIO of our own on the
 * connected descriptor. */
static int
fd_bio_write(BIO *b, const char *buf, int n)
{
    ssize_t w = write((int)(intptr_t)BIO_get_data(b), buf, (size_t)n);
    return (int)w;
}

static int
fd_bio_read(BIO *b, char *buf, int n)
{
    ssize_t r = read((int)(intptr_t)BIO_get_data(b), buf, (size_t)n);
    return (int)r;
}

static long
fd_bio_ctrl(BIO *b, int cmd, long num, void *ptr)
{
    return cmd == BIO_CTRL_FLUSH ? 1 : 0;
}

static BIO_METHOD *
fd_bio_method(void)
{
    static BIO_METHOD *m;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      m = BIO_meth_new(BIO_get_new_index() | BIO_TYPE_SOURCE_SINK, "finch fd");
      BIO_meth_set_write(m, fd_bio_write);
      BIO_meth_set_read(m, fd_bio_read);
      BIO_meth_set_ctrl(m, fd_bio_ctrl);
    });
    return m;
}

static NSInteger
conn_open(Connection *c, NSURL *url, NSTimeInterval timeout)
{
    c->fd = -1;
    c->ssl = NULL;
    c->ctx = NULL;
    BOOL tls = [[[url scheme] lowercaseString] isEqualToString:@"https"];
    NSString *host = [url host];
    if (![host length])
        return NSURLErrorBadURL;
    int port = [url port] ? [[url port] intValue] : tls ? 443 : 80;
    struct addrinfo hints = {0}, *res = NULL;
    hints.ai_socktype = SOCK_STREAM;
    char portStr[8];
    snprintf(portStr, sizeof portStr, "%d", port);
    if (getaddrinfo([host UTF8String], portStr, &hints, &res) != 0 || !res)
        return NSURLErrorCannotFindHost;
    for (struct addrinfo *a = res; a; a = a->ai_next) {
        int fd = socket(a->ai_family, a->ai_socktype, a->ai_protocol);
        if (fd < 0)
            continue;
        struct timeval tv = {(time_t)timeout, 0};
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
        if (connect(fd, a->ai_addr, a->ai_addrlen) == 0) {
            c->fd = fd;
            break;
        }
        close(fd);
    }
    freeaddrinfo(res);
    if (c->fd < 0)
        return NSURLErrorCannotConnectToHost;
    if (!tls)
        return 0;
    c->ctx = SSL_CTX_new(TLS_client_method());
    SSL_CTX_set_min_proto_version(c->ctx, TLS1_2_VERSION);
    if (SSL_CTX_load_verify_locations(c->ctx, "/etc/ssl/cert.pem", NULL) != 1)
        return NSURLErrorSecureConnectionFailed;
    SSL_CTX_set_verify(c->ctx, SSL_VERIFY_PEER, NULL);
    c->ssl = SSL_new(c->ctx);
    SSL_set_tlsext_host_name(c->ssl, [host UTF8String]);
    SSL_set1_host(c->ssl, [host UTF8String]);
    BIO *bio = BIO_new(fd_bio_method());
    BIO_set_data(bio, (void *)(intptr_t)c->fd);
    BIO_set_init(bio, 1);
    SSL_set_bio(c->ssl, bio, bio);
    if (SSL_connect(c->ssl) != 1)
        return SSL_get_verify_result(c->ssl) != X509_V_OK ? NSURLErrorServerCertificateUntrusted : NSURLErrorSecureConnectionFailed;
    return 0;
}

/* One request and its response over HTTP/1.1 (the connection closes after it). */
static NSData *
load_http_once(NSURLRequest *request, NSURL *url, NSHTTPURLResponse **outResponse, NSInteger *outError)
{
    Connection c;
    NSInteger err = conn_open(&c, url, [request timeoutInterval] > 0 ? [request timeoutInterval] : 60);
    if (err) {
        conn_close(&c);
        *outError = err;
        return nil;
    }
    NSString *path = [(NSString *)CFURLCopyPath((CFURLRef)url) autorelease];
    if (![path length])
        path = @"/";
    NSString *query = [url query];
    NSString *pq = query ? [NSString stringWithFormat:@"%@?%@", path, query] : path;
    NSMutableString *head = [NSMutableString stringWithFormat:@"%@ %@ HTTP/1.1\r\nHost: %@\r\n", [request HTTPMethod], pq,
                                                              [url port] ? [NSString stringWithFormat:@"%@:%@", [url host], [url port]] : [url host]];
    NSDictionary *fields = [request allHTTPHeaderFields] ?: @{};
    BOOL hasUA = NO, hasAccept = NO;
    for (NSString *k in fields) {
        [head appendFormat:@"%@: %@\r\n", k, fields[k]];
        hasUA |= [k caseInsensitiveCompare:@"User-Agent"] == NSOrderedSame;
        hasAccept |= [k caseInsensitiveCompare:@"Accept"] == NSOrderedSame;
    }
    if (!hasUA)
        [head appendFormat:@"User-Agent: %@ (Finch)\r\n", [[NSProcessInfo processInfo] processName]];
    if (!hasAccept)
        [head appendString:@"Accept: */*\r\n"];
    NSData *body = [request HTTPBody];
    if (body || ![[request HTTPMethod] isEqualToString:@"GET"])
        [head appendFormat:@"Content-Length: %lu\r\n", (unsigned long)[body length]];
    [head appendString:@"Connection: close\r\n\r\n"];
    NSData *headData = [head dataUsingEncoding:NSUTF8StringEncoding];
    if (!conn_write(&c, [headData bytes], [headData length]) || (body && !conn_write(&c, [body bytes], [body length]))) {
        conn_close(&c);
        *outError = NSURLErrorNetworkConnectionLost;
        return nil;
    }
    NSMutableData *all = [NSMutableData data];
    char buf[16384];
    ssize_t n;
    while ((n = conn_read(&c, buf, sizeof buf)) > 0)
        [all appendBytes:buf length:(NSUInteger)n];
    conn_close(&c);
    const char *bytes = [all bytes];
    NSUInteger len = [all length], end = 0;
    for (NSUInteger i = 0; i + 3 < len; i++)
        if (!memcmp(bytes + i, "\r\n\r\n", 4)) {
            end = i;
            break;
        }
    if (!end) {
        *outError = len ? NSURLErrorBadServerResponse : NSURLErrorTimedOut;
        return nil;
    }
    NSString *headerText = [[[NSString alloc] initWithBytes:bytes length:end encoding:NSISOLatin1StringEncoding] autorelease];
    NSArray *lines = [headerText componentsSeparatedByString:@"\r\n"];
    NSArray *status = [lines[0] componentsSeparatedByString:@" "];
    if ([status count] < 2) {
        *outError = NSURLErrorBadServerResponse;
        return nil;
    }
    NSMutableDictionary *h = [NSMutableDictionary dictionary];
    for (NSUInteger i = 1; i < [lines count]; i++) {
        NSRange colon = [lines[i] rangeOfString:@":"];
        if (colon.location == NSNotFound)
            continue;
        NSString *k = [lines[i] substringToIndex:colon.location];
        NSString *v = [[lines[i] substringFromIndex:NSMaxRange(colon)]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        h[k] = h[k] ? [NSString stringWithFormat:@"%@, %@", h[k], v] : v;
    }
    *outResponse = [[[NSHTTPURLResponse alloc] initWithURL:url statusCode:[status[1] integerValue] HTTPVersion:status[0]
                                              headerFields:h] autorelease];
    NSData *payload = [all subdataWithRange:NSMakeRange(end + 4, len - end - 4)];
    if ([[[*outResponse valueForHTTPHeaderField:@"Transfer-Encoding"] lowercaseString] containsString:@"chunked"]) {
        NSMutableData *out = [NSMutableData data];
        const char *p = [payload bytes], *e = p + [payload length];
        while (p < e) {
            char *after;
            unsigned long size = strtoul(p, &after, 16);
            const char *line = strstr(after, "\r\n");
            if (!line || size == 0)
                break;
            p = line + 2;
            if (p + size > e)
                size = (unsigned long)(e - p);
            [out appendBytes:p length:size];
            p += size + 2;
        }
        payload = out;
    }
    return payload;
}

/* Load a request, following up to 16 redirects. */
static NSData *
load(NSURLRequest *request, NSURLResponse **outResponse, NSError **outError)
{
    NSURL *url = [request URL];
    NSString *scheme = [[url scheme] lowercaseString];
    *outResponse = nil;
    *outError = nil;
    if ([url isFileURL]) {
        NSError *e = nil;
        NSData *d = [NSData dataWithContentsOfURL:url options:0 error:&e];
        if (!d) {
            *outError = url_error(NSURLErrorFileDoesNotExist, url, @"The requested URL was not found on this server.");
            return nil;
        }
        *outResponse = [[[NSURLResponse alloc] initWithURL:url MIMEType:mime_for_extension([url pathExtension])
                                     expectedContentLength:(NSInteger)[d length] textEncodingName:nil] autorelease];
        return d;
    }
    if ([scheme isEqualToString:@"data"]) {
        NSData *d = load_data_url(url, outResponse);
        if (!d)
            *outError = url_error(NSURLErrorBadURL, url, @"bad URL");
        return d;
    }
    if (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"]) {
        *outError = url_error(NSURLErrorUnsupportedURL, url, @"unsupported URL");
        return nil;
    }
    NSMutableURLRequest *r = [[request mutableCopy] autorelease];
    for (int hops = 0; hops < 16; hops++) {
        NSHTTPURLResponse *resp = nil;
        NSInteger code = 0;
        NSData *d = load_http_once(r, [r URL], &resp, &code);
        if (code) {
            *outError = url_error(code, [r URL], nil);
            return nil;
        }
        NSInteger s = [resp statusCode];
        NSString *loc = [resp valueForHTTPHeaderField:@"Location"];
        if ((s == 301 || s == 302 || s == 303 || s == 307 || s == 308) && loc) {
            NSURL *next = [NSURL URLWithString:loc relativeToURL:[r URL]];
            [r setURL:[next absoluteURL]];
            if (s == 303 || ((s == 301 || s == 302) && [[r HTTPMethod] isEqualToString:@"POST"])) {
                [r setHTTPMethod:@"GET"];
                [r setHTTPBody:nil];
            }
            continue;
        }
        *outResponse = resp;
        return d;
    }
    *outError = url_error(NSURLErrorHTTPTooManyRedirects, [r URL], @"too many HTTP redirects");
    return nil;
}

#pragma mark - NSURLSessionConfiguration

@implementation NSURLSessionConfiguration {
    NSString *_identifier;
}

+ (NSURLSessionConfiguration *)defaultSessionConfiguration { return [[[self alloc] init] autorelease]; }
+ (NSURLSessionConfiguration *)ephemeralSessionConfiguration { return [[[self alloc] init] autorelease]; }
+ (NSURLSessionConfiguration *)backgroundSessionConfigurationWithIdentifier:(NSString *)identifier
{
    NSURLSessionConfiguration *c = [[[self alloc] init] autorelease];
    c->_identifier = [identifier copy];
    return c;
}

- (instancetype)init
{
    if ((self = [super init])) {
        self.timeoutIntervalForRequest = 60;
        self.timeoutIntervalForResource = 7 * 24 * 3600;
        self.allowsCellularAccess = YES;
        self.HTTPMaximumConnectionsPerHost = 6;
        self.HTTPShouldSetCookies = YES;
        self.requestCachePolicy = NSURLRequestUseProtocolCachePolicy;
    }
    return self;
}

- (void)dealloc
{
    [_identifier release];
    [super dealloc];
}

- (NSString *)identifier { return _identifier; }

- (id)copyWithZone:(NSZone *)zone
{
    NSURLSessionConfiguration *c = [[NSURLSessionConfiguration allocWithZone:zone] init];
    c->_identifier = [_identifier copy];
    c.timeoutIntervalForRequest = self.timeoutIntervalForRequest;
    c.timeoutIntervalForResource = self.timeoutIntervalForResource;
    c.HTTPAdditionalHeaders = self.HTTPAdditionalHeaders;
    c.requestCachePolicy = self.requestCachePolicy;
    c.allowsCellularAccess = self.allowsCellularAccess;
    return c;
}

@end

#pragma mark - Tasks

@interface NSURLSessionTask ()
- (instancetype)_finchInitWithSession:(NSURLSession *)session request:(NSURLRequest *)request identifier:(NSUInteger)ident
                             download:(BOOL)download
                           completion:(void (^)(id result, NSURLResponse *response, NSError *error))completion;
@end

@implementation NSURLSessionTask {
    NSURLSession *_session; /* retained while running, as Apple's */
    NSURLRequest *_original;
    NSURLResponse *_response;
    NSError *_error;
    NSUInteger _identifier;
    NSURLSessionTaskState _state;
    BOOL _download;
    int64_t _received, _expected;
    void (^_completion)(id, NSURLResponse *, NSError *);
    NSString *_description;
    float _priority;
}

- (instancetype)_finchInitWithSession:(NSURLSession *)session request:(NSURLRequest *)request identifier:(NSUInteger)ident
                             download:(BOOL)download completion:(void (^)(id, NSURLResponse *, NSError *))completion
{
    if ((self = [super init])) {
        _session = [session retain];
        _original = [request copy];
        _identifier = ident;
        _download = download;
        _completion = [completion copy];
        _state = NSURLSessionTaskStateSuspended;
        _expected = NSURLSessionTransferSizeUnknown;
        _priority = NSURLSessionTaskPriorityDefault;
    }
    return self;
}

- (void)dealloc
{
    [_session release];
    [_original release];
    [_response release];
    [_error release];
    [_completion release];
    [_description release];
    [super dealloc];
}

- (NSUInteger)taskIdentifier { return _identifier; }
- (NSURLRequest *)originalRequest { return _original; }
- (NSURLRequest *)currentRequest { return _original; }
- (NSURLResponse *)response { return _response; }
- (NSError *)error { return _error; }
- (NSURLSessionTaskState)state { return _state; }
- (int64_t)countOfBytesReceived { return _received; }
- (int64_t)countOfBytesSent { return 0; }
- (int64_t)countOfBytesExpectedToSend { return 0; }
- (int64_t)countOfBytesExpectedToReceive { return _expected; }
- (NSString *)taskDescription { return _description; }
- (void)setTaskDescription:(NSString *)d
{
    [_description autorelease];
    _description = [d copy];
}
- (float)priority { return _priority; }
- (void)setPriority:(float)p { _priority = p; }
- (NSProgress *)progress { return [NSProgress progressWithTotalUnitCount:_expected > 0 ? _expected : -1]; }

- (void)resume
{
    @synchronized(self) {
        if (_state != NSURLSessionTaskStateSuspended)
            return;
        _state = NSURLSessionTaskStateRunning;
    }
    [self retain];
    NSURLRequest *request = _original;
    BOOL download = _download;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      NSURLResponse *response = nil;
      NSError *error = nil;
      NSData *data = load(request, &response, &error);
      id result = data;
      if (data && download) {
          NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:
                                                      [NSString stringWithFormat:@"CFNetworkDownload_%@.tmp", [[NSUUID UUID] UUIDString]]];
          result = [data writeToFile:tmp atomically:YES] ? [NSURL fileURLWithPath:tmp] : nil;
      }
      [self _finchFinishWithResult:result response:response error:error];
      [self release];
    });
}

- (void)_finchFinishWithResult:(id)result response:(NSURLResponse *)response error:(NSError *)error
{
    @synchronized(self) {
        if (_state == NSURLSessionTaskStateCompleted)
            return;
        _state = NSURLSessionTaskStateCompleted;
        _response = [response retain];
        _error = [error retain];
        _received = [result isKindOfClass:[NSData class]] ? (int64_t)[result length] : [response expectedContentLength];
    }
    void (^completion)(id, NSURLResponse *, NSError *) = [[_completion retain] autorelease];
    NSURLSession *session = [[_session retain] autorelease];
    [session.delegateQueue addOperationWithBlock:^{
      if (completion) {
          completion(result, response, error);
      } else {
          id d = session.delegate;
          if (result && [result isKindOfClass:[NSData class]] && [d respondsToSelector:@selector(URLSession:dataTask:didReceiveData:)])
              [(id<NSURLSessionDataDelegate>)d URLSession:session dataTask:(NSURLSessionDataTask *)self didReceiveData:result];
          if (result && [result isKindOfClass:[NSURL class]] &&
              [d respondsToSelector:@selector(URLSession:downloadTask:didFinishDownloadingToURL:)])
              [(id<NSURLSessionDownloadDelegate>)d URLSession:session downloadTask:(NSURLSessionDownloadTask *)self
                                    didFinishDownloadingToURL:result];
          if ([d respondsToSelector:@selector(URLSession:task:didCompleteWithError:)])
              [(id<NSURLSessionTaskDelegate>)d URLSession:session task:self didCompleteWithError:error];
      }
      if ([result isKindOfClass:[NSURL class]])
          [[NSFileManager defaultManager] removeItemAtURL:result error:NULL];
    }];
    [_session release];
    _session = nil;
}

- (void)cancel
{
    [self _finchFinishWithResult:nil response:nil
                           error:url_error(NSURLErrorCancelled, [_original URL], @"cancelled")];
}

- (void)suspend {}

@end

@implementation NSURLSessionDataTask
@end
@implementation NSURLSessionUploadTask
@end
@implementation NSURLSessionDownloadTask
- (void)cancelByProducingResumeData:(void (^)(NSData *))handler
{
    [self cancel];
    if (handler)
        handler(nil);
}
@end

#pragma mark - NSURLSession

@implementation NSURLSession {
    NSURLSessionConfiguration *_configuration;
    id<NSURLSessionDelegate> _delegate;
    NSOperationQueue *_queue;
    NSUInteger _nextIdentifier;
    NSString *_description;
}

+ (NSURLSession *)sharedSession
{
    static NSURLSession *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      shared = [[NSURLSession alloc] _finchInitWithConfiguration:[NSURLSessionConfiguration defaultSessionConfiguration]
                                                        delegate:nil queue:nil];
    });
    return shared;
}

+ (NSURLSession *)sessionWithConfiguration:(NSURLSessionConfiguration *)configuration
{
    return [self sessionWithConfiguration:configuration delegate:nil delegateQueue:nil];
}

+ (NSURLSession *)sessionWithConfiguration:(NSURLSessionConfiguration *)configuration delegate:(id<NSURLSessionDelegate>)delegate
                             delegateQueue:(NSOperationQueue *)queue
{
    return [[[self alloc] _finchInitWithConfiguration:configuration delegate:delegate queue:queue] autorelease];
}

- (instancetype)_finchInitWithConfiguration:(NSURLSessionConfiguration *)configuration delegate:(id)delegate queue:(NSOperationQueue *)queue
{
    if ((self = [super init])) {
        _configuration = [configuration copy];
        _delegate = [delegate retain]; /* as Apple's: until invalidated */
        if (queue) {
            _queue = [queue retain];
        } else {
            _queue = [NSOperationQueue new];
            _queue.maxConcurrentOperationCount = 1;
        }
        _nextIdentifier = 1;
    }
    return self;
}

- (void)dealloc
{
    [_configuration release];
    [_delegate release];
    [_queue release];
    [_description release];
    [super dealloc];
}

- (NSURLSessionConfiguration *)configuration { return [[_configuration copy] autorelease]; }
- (id<NSURLSessionDelegate>)delegate { return _delegate; }
- (NSOperationQueue *)delegateQueue { return _queue; }
- (NSString *)sessionDescription { return _description; }
- (void)setSessionDescription:(NSString *)d
{
    [_description autorelease];
    _description = [d copy];
}

/* The request with the configuration's timeout and extra headers. */
- (NSURLRequest *)_finchPrepare:(NSURLRequest *)request
{
    NSMutableURLRequest *r = [[request mutableCopy] autorelease];
    if ([request timeoutInterval] == 60)
        [r setTimeoutInterval:_configuration.timeoutIntervalForRequest];
    NSDictionary *extra = _configuration.HTTPAdditionalHeaders;
    for (NSString *k in extra)
        if (![r valueForHTTPHeaderField:k])
            [r setValue:[extra[k] description] forHTTPHeaderField:k];
    return r;
}

- (id)_finchTask:(Class)cls request:(NSURLRequest *)request download:(BOOL)download completion:(id)completion
{
    NSUInteger ident;
    @synchronized(self) {
        ident = _nextIdentifier++;
    }
    return [[[cls alloc] _finchInitWithSession:self request:[self _finchPrepare:request] identifier:ident download:download
                                    completion:completion] autorelease];
}

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request
{
    return [self _finchTask:[NSURLSessionDataTask class] request:request download:NO completion:nil];
}
- (NSURLSessionDataTask *)dataTaskWithURL:(NSURL *)url { return [self dataTaskWithRequest:[NSURLRequest requestWithURL:url]]; }
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request
                            completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler
{
    return [self _finchTask:[NSURLSessionDataTask class] request:request download:NO completion:completionHandler];
}
- (NSURLSessionDataTask *)dataTaskWithURL:(NSURL *)url
                        completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler
{
    return [self dataTaskWithRequest:[NSURLRequest requestWithURL:url] completionHandler:completionHandler];
}
- (NSURLSessionDownloadTask *)downloadTaskWithRequest:(NSURLRequest *)request
{
    return [self _finchTask:[NSURLSessionDownloadTask class] request:request download:YES completion:nil];
}
- (NSURLSessionDownloadTask *)downloadTaskWithURL:(NSURL *)url { return [self downloadTaskWithRequest:[NSURLRequest requestWithURL:url]]; }
- (NSURLSessionDownloadTask *)downloadTaskWithRequest:(NSURLRequest *)request
                                    completionHandler:(void (^)(NSURL *, NSURLResponse *, NSError *))completionHandler
{
    return [self _finchTask:[NSURLSessionDownloadTask class] request:request download:YES completion:completionHandler];
}
- (NSURLSessionDownloadTask *)downloadTaskWithURL:(NSURL *)url
                                completionHandler:(void (^)(NSURL *, NSURLResponse *, NSError *))completionHandler
{
    return [self downloadTaskWithRequest:[NSURLRequest requestWithURL:url] completionHandler:completionHandler];
}
- (NSURLSessionUploadTask *)uploadTaskWithRequest:(NSURLRequest *)request fromData:(NSData *)bodyData
                                completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler
{
    NSMutableURLRequest *r = [[request mutableCopy] autorelease];
    [r setHTTPBody:bodyData];
    return [self _finchTask:[NSURLSessionUploadTask class] request:r download:NO completion:completionHandler];
}
- (NSURLSessionUploadTask *)uploadTaskWithRequest:(NSURLRequest *)request fromData:(NSData *)bodyData
{
    return [self uploadTaskWithRequest:request fromData:bodyData completionHandler:(id _Nonnull)nil];
}

- (void)finishTasksAndInvalidate
{
    id d = _delegate;
    [_queue addOperationWithBlock:^{
      if ([d respondsToSelector:@selector(URLSession:didBecomeInvalidWithError:)])
          [d URLSession:self didBecomeInvalidWithError:nil];
    }];
}

- (void)invalidateAndCancel { [self finishTasksAndInvalidate]; }
- (void)resetWithCompletionHandler:(void (^)(void))completionHandler { [_queue addOperationWithBlock:completionHandler]; }
- (void)flushWithCompletionHandler:(void (^)(void))completionHandler { [_queue addOperationWithBlock:completionHandler]; }
- (void)getAllTasksWithCompletionHandler:(void (^)(NSArray<__kindof NSURLSessionTask *> *))completionHandler
{
    [_queue addOperationWithBlock:^{ completionHandler(@[]); }];
}

@end
