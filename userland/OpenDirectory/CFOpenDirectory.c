/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * CFOpenDirectory: Open Directory's C API (Apple's is closed). Finch's first
 * cut serves the local node only, from the user database libSystem reads
 * (/etc/master.passwd through getpwnam), and verifies passwords with crypt(3),
 * as Finch's pam_unix does. Sessions, nodes and records are CF types, so
 * callers CFRelease them as with Apple's.
 *
 * Implemented (what Finch's binaries import, chkpasswd's -i od): sessions,
 * nodes by type or name (the local and authentication nodes, which here are
 * the same), user records by name, password verification. The rest comes as
 * something needs it, along with opendirectoryd and directory services proper.
 */

#include <CFOpenDirectory/CFOpenDirectory.h>
#include <CoreFoundation/CFRuntime.h>
#include <pwd.h>
#include <string.h>
#include <unistd.h>

const CFStringRef kODErrorDomainFramework = CFSTR("com.apple.OpenDirectory");
const ODRecordType kODRecordTypeUsers = CFSTR("dsRecTypeStandard:Users");

#define LOCAL_NODE_NAME CFSTR("/Local/Default")

struct __ODSession { CFRuntimeBase base; };
struct __ODNode { CFRuntimeBase base; CFStringRef name; };
struct __ODRecord { CFRuntimeBase base; CFStringRef type; CFStringRef name; };

static void node_finalize(CFTypeRef cf) { CFRelease(((ODNodeRef)cf)->name); }
static void record_finalize(CFTypeRef cf) {
    CFRelease(((ODRecordRef)cf)->type);
    CFRelease(((ODRecordRef)cf)->name);
}

static const CFRuntimeClass session_class = { .className = "ODSession" };
static const CFRuntimeClass node_class = { .className = "ODNode", .finalize = node_finalize };
static const CFRuntimeClass record_class = { .className = "ODRecord", .finalize = record_finalize };
static CFTypeID session_id, node_id, record_id;

static void register_classes(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        session_id = _CFRuntimeRegisterClass(&session_class);
        node_id = _CFRuntimeRegisterClass(&node_class);
        record_id = _CFRuntimeRegisterClass(&record_class);
    });
}

CFTypeID ODSessionGetTypeID(void) { register_classes(); return session_id; }
CFTypeID ODNodeGetTypeID(void) { register_classes(); return node_id; }
CFTypeID ODRecordGetTypeID(void) { register_classes(); return record_id; }

static CFTypeRef create(CFAllocatorRef allocator, CFTypeID type, size_t size) {
    return _CFRuntimeCreateInstance(allocator, type, (CFIndex)(size - sizeof(CFRuntimeBase)), NULL);
}

static void set_error(CFErrorRef *error, CFIndex code, CFStringRef description) {
    if (!error) return;
    const void *keys[] = { kCFErrorDescriptionKey };
    const void *values[] = { description };
    CFDictionaryRef info = CFDictionaryCreate(NULL, keys, values, 1, &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks);
    *error = CFErrorCreate(NULL, kODErrorDomainFramework, code, info);
    CFRelease(info);
}

/* A user's name as a C string, or false if it doesn't convert. */
static bool c_name(CFStringRef s, char *buf, size_t size) {
    return s && CFStringGetCString(s, buf, (CFIndex)size, kCFStringEncodingUTF8);
}

ODSessionRef ODSessionCreate(CFAllocatorRef allocator, CFDictionaryRef options, CFErrorRef *error) {
    (void)options; (void)error;
    register_classes();
    return (ODSessionRef)create(allocator, session_id, sizeof(struct __ODSession));
}

static ODNodeRef local_node(CFAllocatorRef allocator) {
    register_classes();
    struct __ODNode *n = (struct __ODNode *)create(allocator, node_id, sizeof(struct __ODNode));
    if (n) n->name = CFRetain(LOCAL_NODE_NAME);
    return n;
}

ODNodeRef ODNodeCreateWithNodeType(CFAllocatorRef allocator, ODSessionRef session, ODNodeType nodeType,
    CFErrorRef *error) {
    (void)session;
    /* Only the local directory exists, so authentication and search go there. */
    if (nodeType == kODNodeTypeAuthentication || nodeType == kODNodeTypeLocalNodes ||
        nodeType == kODNodeTypeNetwork || nodeType == kODNodeTypeContacts) {
        return local_node(allocator);
    }
    set_error(error, kODErrorNodeUnknownType, CFSTR("Unknown node type"));
    return NULL;
}

ODNodeRef ODNodeCreateWithName(CFAllocatorRef allocator, ODSessionRef session, CFStringRef nodeName,
    CFErrorRef *error) {
    (void)session;
    if (nodeName && (CFEqual(nodeName, LOCAL_NODE_NAME) || CFEqual(nodeName, CFSTR("/Search")) ||
        CFEqual(nodeName, CFSTR("/Local")))) {
        return local_node(allocator);
    }
    set_error(error, kODErrorNodeUnknownName, CFSTR("Unknown node name"));
    return NULL;
}

CFStringRef ODNodeGetName(ODNodeRef node) { return node->name; }

ODRecordRef ODNodeCopyRecord(ODNodeRef node, ODRecordType recordType, CFStringRef recordName, CFTypeRef attributes,
    CFErrorRef *error) {
    (void)node; (void)attributes; (void)error;
    char name[256];
    /* Not found is NULL without an error, as in Open Directory. */
    if (!recordType || !CFEqual(recordType, kODRecordTypeUsers) || !c_name(recordName, name, sizeof(name)) ||
        getpwnam(name) == NULL) {
        return NULL;
    }
    struct __ODRecord *r = (struct __ODRecord *)create(CFGetAllocator(node), record_id, sizeof(struct __ODRecord));
    if (r) {
        r->type = CFRetain(recordType);
        r->name = CFStringCreateCopy(NULL, recordName);
    }
    return r;
}

CFStringRef ODRecordGetRecordName(ODRecordRef record) { return record->name; }
CFStringRef ODRecordGetRecordType(ODRecordRef record) { return record->type; }

bool ODRecordVerifyPassword(ODRecordRef record, CFStringRef password, CFErrorRef *error) {
    char name[256], pass[1024];
    struct passwd *pw;
    if (!CFEqual(record->type, kODRecordTypeUsers) || !c_name(record->name, name, sizeof(name)) ||
        !c_name(password, pass, sizeof(pass)) || (pw = getpwnam(name)) == NULL) {
        set_error(error, kODErrorCredentialsInvalid, CFSTR("Credentials could not be verified"));
        return false;
    }
    /* The hash is in master.passwd, which getpwnam(3) reads for root. "*" and
     * other non-hashes never match; an empty field means no password. */
    const char *hash = pw->pw_passwd ? pw->pw_passwd : "*";
    bool ok = hash[0] == '\0' ? pass[0] == '\0' : ({
        const char *c = crypt(pass, hash);
        c && strcmp(c, hash) == 0 && strcmp(hash, "*") != 0;
    });
    memset(pass, 0, sizeof(pass));
    if (!ok) set_error(error, kODErrorCredentialsInvalid, CFSTR("Credentials could not be verified"));
    return ok;
}
