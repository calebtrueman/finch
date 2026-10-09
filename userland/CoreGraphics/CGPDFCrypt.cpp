/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * The standard security handler (ISO 32000-1 section 7.6.3, and ISO 32000-2
 * for revision 6): checking passwords, computing the file key, and
 * decrypting strings and streams with RC4 or AES. The writer uses the same
 * pieces to encrypt with revision 4 (AES-128). The ciphers and hashes are
 * CommonCrypto's.
 */
#include "CGPDFInternal.h"
#include <CommonCrypto/CommonCrypto.h>
#include <string.h>

static const uint8_t password_pad[32] = {
    0x28, 0xBF, 0x4E, 0x5E, 0x4E, 0x75, 0x8A, 0x41, 0x64, 0x00, 0x4E, 0x56, 0xFF, 0xFA, 0x01, 0x08,
    0x2E, 0x2E, 0x00, 0xB6, 0xD0, 0x68, 0x3E, 0x80, 0x2F, 0x0C, 0xA9, 0xFE, 0x64, 0x53, 0x69, 0x7A,
};

void
CGPDFMD5(const void *data, size_t n, uint8_t out[16])
{
    CC_MD5(data, (CC_LONG)n, out);
}

void
CGPDFRC4(const uint8_t *key, size_t keylen, uint8_t *data, size_t n)
{
    /* RC4 is a few lines; CommonCrypto's needs a key length of at least 5 bytes, which PDF guarantees */
    uint8_t S[256];
    for (int i = 0; i < 256; i++)
        S[i] = (uint8_t)i;
    for (int i = 0, j = 0; i < 256; i++) {
        j = (j + S[i] + key[i % keylen]) & 255;
        uint8_t t = S[i];
        S[i] = S[j], S[j] = t;
    }
    int i = 0, j = 0;
    for (size_t k = 0; k < n; k++) {
        i = (i + 1) & 255;
        j = (j + S[i]) & 255;
        uint8_t t = S[i];
        S[i] = S[j], S[j] = t;
        data[k] ^= S[(S[i] + S[j]) & 255];
    }
}

bool
CGPDFAES(bool encrypt, const uint8_t *key, size_t keylen, const uint8_t iv[16], const uint8_t *in, size_t n,
         std::vector<uint8_t> &out, bool padding)
{
    out.resize(n + 32);
    size_t moved = 0;
    CCCryptorStatus st = CCCrypt(encrypt ? kCCEncrypt : kCCDecrypt, kCCAlgorithmAES,
                                 padding ? kCCOptionPKCS7Padding : 0, key, keylen, iv, in, n, out.data(), out.size(),
                                 &moved);
    if (st != kCCSuccess && padding && !encrypt) {
        /* bad padding: keep the blocks without it */
        st = CCCrypt(kCCDecrypt, kCCAlgorithmAES, 0, key, keylen, iv, in, n & ~(size_t)15, out.data(), out.size(),
                     &moved);
    }
    out.resize(st == kCCSuccess ? moved : 0);
    return st == kCCSuccess;
}

static std::string
padded(const std::string &pw)
{
    std::string p = pw.substr(0, 32);
    p.append((const char *)password_pad, 32 - p.size());
    return p;
}

/* Algorithm 2: the file key from a (padded) user password. */
static std::vector<uint8_t>
file_key(const CGPDFCrypt &c, const std::string &password)
{
    std::string in = padded(password) + c.O.substr(0, 32);
    uint8_t p[4] = {(uint8_t)c.P, (uint8_t)(c.P >> 8), (uint8_t)(c.P >> 16), (uint8_t)(c.P >> 24)};
    in.append((const char *)p, 4);
    in += c.id0;
    if (c.R >= 4 && !c.encrypt_metadata)
        in.append("\xff\xff\xff\xff", 4);
    uint8_t h[16];
    CGPDFMD5(in.data(), in.size(), h);
    size_t n = c.R == 2 ? 5 : (size_t)std::min(16, std::max(5, c.length / 8));
    if (c.R >= 3)
        for (int i = 0; i < 50; i++)
            CGPDFMD5(h, n, h);
    return std::vector<uint8_t>(h, h + n);
}

/* Algorithms 4 and 5: the U entry a key produces (the first 16 bytes that matter, for R3 and up). */
static std::string
user_entry(const CGPDFCrypt &c, const std::vector<uint8_t> &key)
{
    if (c.R == 2) {
        std::string u((const char *)password_pad, 32);
        CGPDFRC4(key.data(), key.size(), (uint8_t *)u.data(), 32);
        return u;
    }
    std::string in((const char *)password_pad, 32);
    in += c.id0;
    uint8_t h[16];
    CGPDFMD5(in.data(), in.size(), h);
    CGPDFRC4(key.data(), key.size(), h, 16);
    for (int i = 1; i <= 19; i++) {
        std::vector<uint8_t> k = key;
        for (auto &b : k)
            b ^= (uint8_t)i;
        CGPDFRC4(k.data(), k.size(), h, 16);
    }
    return std::string((const char *)h, 16);
}

static bool
check_user(CGPDFCrypt &c, const std::string &password)
{
    std::vector<uint8_t> key = file_key(c, password);
    std::string u = user_entry(c, key);
    size_t n = c.R == 2 ? 32 : 16;
    if (c.U.size() < n || memcmp(u.data(), c.U.data(), n))
        return false;
    c.key = key;
    return true;
}

/* Algorithm 7: the user password hidden in O by the owner password. */
static std::string
owner_to_user(const CGPDFCrypt &c, const std::string &owner)
{
    std::string pw = padded(owner);
    uint8_t h[16];
    CGPDFMD5(pw.data(), pw.size(), h);
    size_t n = c.R == 2 ? 5 : (size_t)std::min(16, std::max(5, c.length / 8));
    if (c.R >= 3)
        for (int i = 0; i < 50; i++)
            CGPDFMD5(h, 16, h);
    std::string u = c.O.substr(0, 32);
    if (c.R == 2) {
        CGPDFRC4(h, n, (uint8_t *)u.data(), u.size());
    } else {
        for (int i = 19; i >= 0; i--) {
            uint8_t k[16];
            for (size_t j = 0; j < n; j++)
                k[j] = h[j] ^ (uint8_t)i;
            CGPDFRC4(k, n, (uint8_t *)u.data(), u.size());
        }
    }
    return u;
}

/* Revision 6's hash (ISO 32000-2, algorithm 2.B); revision 5 uses plain SHA-256. */
static void
hash_r6(int R, const std::string &pw, const std::string &salt, const std::string &udata, uint8_t out[32])
{
    std::string in = pw + salt + udata;
    uint8_t K[64];
    size_t klen = 32;
    CC_SHA256(in.data(), (CC_LONG)in.size(), K);
    if (R == 5) {
        memcpy(out, K, 32);
        return;
    }
    for (int i = 0;; i++) {
        std::string k1;
        std::string piece = pw + std::string((const char *)K, klen) + udata;
        for (int r = 0; r < 64; r++)
            k1 += piece;
        std::vector<uint8_t> E;
        CGPDFAES(true, K, 16, K + 16, (const uint8_t *)k1.data(), k1.size(), E, false);
        int sum = 0;
        for (int j = 0; j < 16; j++)
            sum += E[(size_t)j];
        switch (sum % 3) {
        case 0: CC_SHA256(E.data(), (CC_LONG)E.size(), K), klen = 32; break;
        case 1: CC_SHA384(E.data(), (CC_LONG)E.size(), K), klen = 48; break;
        default: CC_SHA512(E.data(), (CC_LONG)E.size(), K), klen = 64; break;
        }
        if (i >= 63 && E.back() <= i + 1 - 32)
            break;
    }
    memcpy(out, K, 32);
}

static bool
unlock_r6(CGPDFCrypt &c, const std::string &password)
{
    std::string pw = password.substr(0, 127);
    if (c.U.size() < 48 || c.O.size() < 48)
        return false;
    uint8_t h[32];
    std::string key_entry;
    hash_r6(c.R, pw, c.O.substr(32, 8), c.U.substr(0, 48), h);
    if (!memcmp(h, c.O.data(), 32)) {
        hash_r6(c.R, pw, c.O.substr(40, 8), c.U.substr(0, 48), h);
        key_entry = c.OE;
        c.owner = true;
    } else {
        hash_r6(c.R, pw, c.U.substr(32, 8), "", h);
        if (memcmp(h, c.U.data(), 32))
            return false;
        hash_r6(c.R, pw, c.U.substr(40, 8), "", h);
        key_entry = c.UE;
    }
    if (key_entry.size() < 32)
        return false;
    uint8_t iv[16] = {0};
    std::vector<uint8_t> key;
    CGPDFAES(false, h, 32, iv, (const uint8_t *)key_entry.data(), 32, key, false);
    if (key.size() != 32)
        return false;
    c.key = key;
    return true;
}

bool
CGPDFCryptUnlock(CGPDFDocData *d, const char *password)
{
    CGPDFCrypt &c = d->crypt;
    std::string pw = password ? password : "";
    if (c.R >= 5)
        return c.unlocked = unlock_r6(c, pw);
    if (check_user(c, pw)) {
        /* the owner password can be the same as the user's */
        c.owner = check_user(c, owner_to_user(c, pw)) || c.owner;
        check_user(c, pw);
        return c.unlocked = true;
    }
    if (check_user(c, owner_to_user(c, pw))) {
        c.owner = true;
        return c.unlocked = true;
    }
    return false;
}

static int
method(CGPDFDictionaryRef cf, const char *name)
{
    if (!name || !strcmp(name, "Identity"))
        return 0;
    CGPDFDictionaryRef filter;
    const char *cfm = NULL;
    if (!cf || !CGPDFDictionaryGetDictionary(cf, name, &filter) || !CGPDFDictionaryGetName(filter, "CFM", &cfm))
        return 1;
    if (!strcmp(cfm, "AESV2"))
        return 2;
    if (!strcmp(cfm, "AESV3"))
        return 3;
    if (!strcmp(cfm, "None"))
        return 0;
    return 1;
}

static std::string
string_entry(CGPDFDictionaryRef d, const char *key)
{
    CGPDFStringRef s;
    if (!CGPDFDictionaryGetString(d, key, &s))
        return "";
    return std::string((const char *)s->bytes, s->length);
}

bool
CGPDFCryptSetup(CGPDFDocData *d, CGPDFDictionaryRef enc)
{
    CGPDFCrypt &c = d->crypt;
    const char *filter = NULL;
    if (!CGPDFDictionaryGetName(enc, "Filter", &filter) || strcmp(filter, "Standard"))
        return false;
    CGPDFInteger v = 0, r = 0, len = 40, p = 0;
    CGPDFDictionaryGetInteger(enc, "V", &v);
    CGPDFDictionaryGetInteger(enc, "R", &r);
    CGPDFDictionaryGetInteger(enc, "Length", &len);
    CGPDFDictionaryGetInteger(enc, "P", &p);
    c.V = (int)v, c.R = (int)r, c.length = (int)len, c.P = (uint32_t)p;
    if (c.length < 40 || c.length > 256)
        c.length = c.length <= 16 ? c.length * 8 : 128;
    c.O = string_entry(enc, "O");
    c.U = string_entry(enc, "U");
    c.OE = string_entry(enc, "OE");
    c.UE = string_entry(enc, "UE");
    CGPDFBoolean em = 1;
    if (CGPDFDictionaryGetBoolean(enc, "EncryptMetadata", &em))
        c.encrypt_metadata = em;
    CGPDFArrayRef id;
    CGPDFStringRef id0;
    if (d->trailer && CGPDFDictionaryGetArray(d->trailer, "ID", &id) && CGPDFArrayGetString(id, 0, &id0))
        c.id0.assign((const char *)id0->bytes, id0->length);
    if (c.V >= 4) {
        CGPDFDictionaryRef cf = NULL;
        CGPDFDictionaryGetDictionary(enc, "CF", &cf);
        const char *stmf = "Identity", *strf = "Identity";
        CGPDFDictionaryGetName(enc, "StmF", &stmf);
        CGPDFDictionaryGetName(enc, "StrF", &strf);
        c.stm = method(cf, stmf);
        c.str = method(cf, strf);
        if (c.V == 4 && c.length > 128)
            c.length = 128;
        if (c.V == 4 && (c.stm == 2 || c.str == 2))
            c.length = 128;
    } else {
        c.stm = c.str = 1;
    }
    if (c.R < 2 || c.R > 6)
        return false;
    c.encrypted = true;
    return true;
}

void
CGPDFCryptObjectKey(const std::vector<uint8_t> &key, uint32_t num, uint32_t gen, bool aes, std::vector<uint8_t> &out)
{
    std::string in((const char *)key.data(), key.size());
    uint8_t ng[5] = {(uint8_t)num, (uint8_t)(num >> 8), (uint8_t)(num >> 16), (uint8_t)gen, (uint8_t)(gen >> 8)};
    in.append((const char *)ng, 5);
    if (aes)
        in.append("sAlT", 4);
    uint8_t h[16];
    CGPDFMD5(in.data(), in.size(), h);
    out.assign(h, h + std::min<size_t>(key.size() + 5, 16));
}

void
CGPDFCryptDecrypt(CGPDFDocData *d, uint32_t num, uint32_t gen, bool stream, std::vector<uint8_t> &data)
{
    CGPDFCrypt &c = d->crypt;
    if (!c.unlocked)
        return;
    int m = stream ? c.stm : c.str;
    if (m == 0 || data.empty())
        return;
    if (m == 3) {
        if (data.size() < 16)
            return data.clear();
        std::vector<uint8_t> out;
        CGPDFAES(false, c.key.data(), 32, data.data(), data.data() + 16, data.size() - 16, out, true);
        data.swap(out);
        return;
    }
    std::vector<uint8_t> k;
    CGPDFCryptObjectKey(c.key, num, gen, m == 2, k);
    if (m == 1) {
        CGPDFRC4(k.data(), k.size(), data.data(), data.size());
        return;
    }
    if (data.size() < 16)
        return data.clear();
    std::vector<uint8_t> out;
    CGPDFAES(false, k.data(), k.size(), data.data(), data.data() + 16, data.size() - 16, out, true);
    data.swap(out);
}

void
CGPDFCryptMakeR4(const std::string &owner, const std::string &user, uint32_t P, const std::string &id0,
                 std::string &O, std::string &U, std::vector<uint8_t> &key)
{
    CGPDFCrypt c;
    c.R = 4, c.V = 4, c.length = 128, c.P = P, c.id0 = id0;
    /* Algorithm 3: O from the owner password (the user's if there is none) */
    std::string opw = padded(owner.empty() ? user : owner);
    uint8_t h[16];
    CGPDFMD5(opw.data(), opw.size(), h);
    for (int i = 0; i < 50; i++)
        CGPDFMD5(h, 16, h);
    std::string o = padded(user);
    for (int i = 0; i <= 19; i++) {
        uint8_t k[16];
        for (int j = 0; j < 16; j++)
            k[j] = h[j] ^ (uint8_t)i;
        CGPDFRC4(k, 16, (uint8_t *)o.data(), 32);
    }
    c.O = O = o;
    /* Algorithm 5: U, padded to 32 bytes */
    key = file_key(c, user);
    U = user_entry(c, key);
    U.append(16, '\0');
}
