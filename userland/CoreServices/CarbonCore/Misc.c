/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * The rest of CarbonCore that apps still call: fixed-point math, 80-bit
 * extended conversions (big-endian, the 68K layout macOS keeps), user names,
 * Time Machine exclusion (the com.apple.metadata:com_apple_backup_excludeItem
 * attribute), Unicode comparison, the Text Encoding Converter's text <->
 * Unicode calls over CFString, and an empty Component Manager (Finch
 * registers no components).
 */
#include "CarbonCore_Finch.h"
#include <errno.h>
#include <math.h>
#include <pwd.h>
#include <sys/xattr.h>
#include <unistd.h>

#pragma mark - Fixed point and extended

const double_t pi = M_PI;

Fixed
FixMul(Fixed a, Fixed b)
{
    int64_t r = ((int64_t)a * b) >> 16;
    return r > INT32_MAX ? INT32_MAX : r < INT32_MIN ? INT32_MIN : (Fixed)r;
}

Fixed
FixRatio(short numer, short denom)
{
    if (!denom)
        return numer >= 0 ? 0x7fffffff : (Fixed)0x80000000;
    return (Fixed)(((int64_t)numer << 16) / denom);
}

Fixed
FixDiv(Fixed x, Fixed y)
{
    if (!y)
        return x >= 0 ? 0x7fffffff : (Fixed)0x80000000;
    int64_t r = ((int64_t)x << 16) / y;
    return r > INT32_MAX ? INT32_MAX : r < INT32_MIN ? INT32_MIN : (Fixed)r;
}

short FixRound(Fixed x) { return (short)((x + 0x8000) >> 16); }
Fract Fix2Frac(Fixed x) { int64_t r = (int64_t)x << 14; return r > INT32_MAX ? INT32_MAX : r < INT32_MIN ? INT32_MIN : (Fract)r; }
SInt32 Fix2Long(Fixed x) { return (x + (x < 0 ? -0x8000 : 0x8000)) / 0x10000; }
Fixed Long2Fix(SInt32 x) { return x > 0x7fff ? 0x7fffffff : x < -0x8000 ? (Fixed)0x80000000 : (Fixed)(x << 16); }
Fixed Frac2Fix(Fract x) { return (x + 0x2000) >> 14; }
Fract FracMul(Fract x, Fract y) { return (Fract)(((int64_t)x * y) >> 30); }
Fract FracDiv(Fract x, Fract y) { return y ? (Fract)(((int64_t)x << 30) / y) : (x >= 0 ? 0x7fffffff : (Fract)0x80000000); }
double Fix2X(Fixed x) { return x / 65536.0; }
Fixed X2Fix(double x) { double r = x * 65536.0; return r >= 2147483647.0 ? 0x7fffffff : r <= -2147483648.0 ? (Fixed)0x80000000 : (Fixed)lround(r); }
double Frac2X(Fract x) { return x / 1073741824.0; }
Fract X2Frac(double x) { double r = x * 1073741824.0; return r >= 2147483647.0 ? 0x7fffffff : r <= -2147483648.0 ? (Fract)0x80000000 : (Fract)lround(r); }
Fract FracSqrt(Fract x) { return x <= 0 ? 0 : X2Frac(sqrt(Frac2X(x))); }
Fract FracSin(Fixed x) { return X2Frac(sin(Fix2X(x))); }
Fract FracCos(Fixed x) { return X2Frac(cos(Fix2X(x))); }
Fixed FixATan2(SInt32 x, SInt32 y) { return X2Fix(atan2((double)y, (double)x)); }

double
x80tod(const extended80 *x80)
{
    const unsigned char *b = (const unsigned char *)x80;
    int sign = b[0] >> 7;
    int exp = ((b[0] & 0x7f) << 8) | b[1];
    uint64_t mant = 0;
    for (int i = 0; i < 8; i++)
        mant = mant << 8 | b[2 + i];
    if (exp == 0 && mant == 0)
        return sign ? -0.0 : 0.0;
    if (exp == 0x7fff)
        return (mant << 1) ? NAN : (sign ? -INFINITY : INFINITY);
    double v = ldexp((double)mant, exp - 16383 - 63);
    return sign ? -v : v;
}

void
dtox80(const double *x, extended80 *x80)
{
    unsigned char *b = (unsigned char *)x80;
    memset(b, 0, 10);
    double v = *x;
    int sign = signbit(v) ? 1 : 0;
    uint16_t exp = 0;
    uint64_t mant = 0;
    if (isnan(v)) {
        exp = 0x7fff;
        mant = 0xc000000000000000ULL;
    } else if (isinf(v)) {
        exp = 0x7fff;
        mant = 0x8000000000000000ULL;
    } else if (v != 0) {
        int e;
        double m = frexp(fabs(v), &e);  /* m in [0.5, 1) */
        exp = (uint16_t)(e - 1 + 16383);
        mant = (uint64_t)ldexp(m, 64);
    }
    exp |= sign << 15;
    b[0] = exp >> 8;
    b[1] = exp;
    for (int i = 0; i < 8; i++)
        b[2 + i] = (unsigned char)(mant >> (56 - 8 * i));
}

#pragma mark - Users and backups

CFStringRef
CSCopyUserName(Boolean useShortName)
{
    struct passwd *pw = getpwuid(geteuid());
    if (!pw)
        return CFSTR("");
    if (useShortName)
        return CFStringCreateWithCString(NULL, pw->pw_name, kCFStringEncodingUTF8);
    char full[256];
    strlcpy(full, pw->pw_gecos && *pw->pw_gecos ? pw->pw_gecos : pw->pw_name, sizeof full);
    char *comma = strchr(full, ',');
    if (comma)
        *comma = 0;
    return CFStringCreateWithCString(NULL, full, kCFStringEncodingUTF8);
}

CFStringRef
CSCopyMachineName(void)
{
    char host[256] = {0};
    gethostname(host, sizeof host - 1);
    char *dot = strstr(host, ".local");
    if (dot)
        *dot = 0;
    return CFStringCreateWithCString(NULL, host, kCFStringEncodingUTF8);
}

#define BACKUP_XATTR "com.apple.metadata:com_apple_backup_excludeItem"

OSStatus
CSBackupSetItemExcluded(CFURLRef item, Boolean exclude, Boolean excludeByPath)
{
    char path[PATH_MAX];
    if (!item || !CFURLGetFileSystemRepresentation(item, true, (UInt8 *)path, sizeof path))
        return paramErr;
    if (!exclude)
        return removexattr(path, BACKUP_XATTR, 0) == 0 || errno == ENOATTR ? noErr : errno;
    /* the binary property list "com.apple.backupd", as macOS writes it */
    static const unsigned char value[] = {
        'b', 'p', 'l', 'i', 's', 't', '0', '0', 0x5f, 0x10, 0x11, 'c', 'o', 'm', '.', 'a', 'p', 'p', 'l', 'e', '.',
        'b', 'a', 'c', 'k', 'u', 'p', 'd', 0x08, 0, 0, 0, 0, 0, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0x1c};
    return setxattr(path, BACKUP_XATTR, value, sizeof value, 0, 0) ? errno : noErr;
}

Boolean
CSBackupIsItemExcluded(CFURLRef item, Boolean *excludeByPath)
{
    char path[PATH_MAX];
    if (excludeByPath)
        *excludeByPath = false;
    if (!item || !CFURLGetFileSystemRepresentation(item, true, (UInt8 *)path, sizeof path))
        return false;
    return getxattr(path, BACKUP_XATTR, NULL, 0, 0, 0) >= 0;
}

#pragma mark - Unicode comparison

OSStatus
UCCompareTextDefault(UCCollateOptions options, const UniChar *text1Ptr, UniCharCount text1Length,
                     const UniChar *text2Ptr, UniCharCount text2Length, Boolean *equivalent, SInt32 *order)
{
    if (!text1Ptr || !text2Ptr)
        return paramErr;
    CFStringRef a = CFStringCreateWithCharactersNoCopy(NULL, text1Ptr, text1Length, kCFAllocatorNull);
    CFStringRef b = CFStringCreateWithCharactersNoCopy(NULL, text2Ptr, text2Length, kCFAllocatorNull);
    CFStringCompareFlags flags = kCFCompareLocalized;
    if (options & kUCCollateCaseInsensitiveMask)
        flags |= kCFCompareCaseInsensitive;
    if (options & kUCCollateDiacritInsensitiveMask)
        flags |= kCFCompareDiacriticInsensitive;
    if (options & kUCCollateWidthInsensitiveMask)
        flags |= kCFCompareWidthInsensitive;
    if (options & kUCCollateDigitsAsNumberMask)
        flags |= kCFCompareNumerically;
    CFComparisonResult r = CFStringCompare(a, b, flags);
    if (equivalent)
        *equivalent = r == kCFCompareEqualTo;
    /* equal under the options, the strings may still differ in what was ignored (case: lowercase first) */
    if (r == kCFCompareEqualTo)
        r = CFStringCompare(a, b, kCFCompareLocalized);
    if (order)
        *order = r == kCFCompareLessThan ? -1 : r == kCFCompareGreaterThan ? 1 : 0;
    CFRelease(a);
    CFRelease(b);
    return noErr;
}

#pragma mark - Text encodings

TextEncoding
CreateTextEncoding(TextEncodingBase encodingBase, TextEncodingVariant encodingVariant, TextEncodingFormat encodingFormat)
{
    return (encodingBase & 0xffff) | ((encodingVariant & 0x3ff) << 16) | ((encodingFormat & 0x3f) << 26);
}

TextEncodingBase GetTextEncodingBase(TextEncoding encoding) { return encoding & 0xffff; }
TextEncodingVariant GetTextEncodingVariant(TextEncoding encoding) { return (encoding >> 16) & 0x3ff; }
TextEncodingFormat GetTextEncodingFormat(TextEncoding encoding) { return (encoding >> 26) & 0x3f; }
TextEncoding ResolveDefaultTextEncoding(TextEncoding encoding) { return encoding; }

OSStatus
GetTextEncodingFromScriptInfo(ScriptCode iTextScriptID, LangCode iTextLanguageID, RegionCode iTextRegionID,
                              TextEncoding *oEncoding)
{
    if (iTextScriptID < 0 || iTextScriptID > 32)
        return paramErr;
    /* the Mac script codes are the Mac encodings' bases */
    *oEncoding = (TextEncoding)iTextScriptID;
    return noErr;
}

OSStatus
GetScriptInfoFromTextEncoding(TextEncoding iEncoding, ScriptCode *oTextScriptID, LangCode *oTextLanguageID)
{
    TextEncodingBase b = GetTextEncodingBase(iEncoding);
    if (oTextScriptID)
        *oTextScriptID = b <= 32 ? (ScriptCode)b : smRoman;
    if (oTextLanguageID)
        *oTextLanguageID = kTextLanguageDontCare;
    return noErr;
}

struct converter {
    CFStringEncoding from, to;
};

static CFStringEncoding
cf_encoding(TextEncoding te)
{
    TextEncodingBase base = GetTextEncodingBase(te);
    if (base == kTextEncodingUnicodeDefault || base == kTextEncodingUnicodeV2_0 || base == kTextEncodingUnicodeV3_0 ||
        (base >= kTextEncodingUnicodeV1_1 && base <= kTextEncodingUnicodeV10_0)) {
        TextEncodingFormat f = GetTextEncodingFormat(te);
        return f == kUnicodeUTF8Format ? kCFStringEncodingUTF8 : f == kUnicode32BitFormat ? kCFStringEncodingUTF32LE
                                                                                          : kCFStringEncodingUTF16LE;
    }
    return (CFStringEncoding)base;  /* CFStringEncoding uses the Text Encoding Converter's base values */
}

OSStatus
CreateTextToUnicodeInfoByEncoding(TextEncoding iEncoding, TextToUnicodeInfo *oTextToUnicodeInfo)
{
    if (!oTextToUnicodeInfo || !CFStringIsEncodingAvailable(cf_encoding(iEncoding)))
        return paramErr;
    struct converter *c = malloc(sizeof *c);
    c->from = cf_encoding(iEncoding);
    c->to = kCFStringEncodingUTF16LE;
    *oTextToUnicodeInfo = (TextToUnicodeInfo)c;
    return noErr;
}

OSStatus
CreateTextToUnicodeInfo(ConstUnicodeMappingPtr iUnicodeMapping, TextToUnicodeInfo *oTextToUnicodeInfo)
{
    if (!iUnicodeMapping)
        return paramErr;
    return CreateTextToUnicodeInfoByEncoding(iUnicodeMapping->otherEncoding, oTextToUnicodeInfo);
}

OSStatus
CreateUnicodeToTextInfoByEncoding(TextEncoding iEncoding, UnicodeToTextInfo *oUnicodeToTextInfo)
{
    if (!oUnicodeToTextInfo || !CFStringIsEncodingAvailable(cf_encoding(iEncoding)))
        return paramErr;
    struct converter *c = malloc(sizeof *c);
    c->from = kCFStringEncodingUTF16LE;
    c->to = cf_encoding(iEncoding);
    *oUnicodeToTextInfo = (UnicodeToTextInfo)c;
    return noErr;
}

OSStatus
CreateUnicodeToTextInfo(ConstUnicodeMappingPtr iUnicodeMapping, UnicodeToTextInfo *oUnicodeToTextInfo)
{
    if (!iUnicodeMapping)
        return paramErr;
    return CreateUnicodeToTextInfoByEncoding(iUnicodeMapping->otherEncoding, oUnicodeToTextInfo);
}

OSStatus
DisposeTextToUnicodeInfo(TextToUnicodeInfo *ioTextToUnicodeInfo)
{
    if (!ioTextToUnicodeInfo || !*ioTextToUnicodeInfo)
        return paramErr;
    free(*ioTextToUnicodeInfo);
    *ioTextToUnicodeInfo = NULL;
    return noErr;
}

OSStatus
DisposeUnicodeToTextInfo(UnicodeToTextInfo *ioUnicodeToTextInfo)
{
    if (!ioUnicodeToTextInfo || !*ioUnicodeToTextInfo)
        return paramErr;
    free(*ioUnicodeToTextInfo);
    *ioUnicodeToTextInfo = NULL;
    return noErr;
}

OSStatus
ConvertFromTextToUnicode(TextToUnicodeInfo iTextToUnicodeInfo, ByteCount iSourceLen, ConstLogicalAddress iSourceStr,
                         OptionBits iControlFlags, ItemCount iOffsetCount, const ByteOffset *iOffsetArray,
                         ItemCount *oOffsetCount, ByteOffset *oOffsetArray, ByteCount iOutputBufLen,
                         ByteCount *oSourceRead, ByteCount *oUnicodeLen, UniChar *oUnicodeStr)
{
    struct converter *c = (struct converter *)iTextToUnicodeInfo;
    if (!c || !iSourceStr || !oUnicodeStr)
        return paramErr;
    if (oOffsetCount)
        *oOffsetCount = 0;
    CFStringRef s = CFStringCreateWithBytes(NULL, iSourceStr, iSourceLen, c->from, false);
    if (!s) {
        if (oSourceRead)
            *oSourceRead = 0;
        if (oUnicodeLen)
            *oUnicodeLen = 0;
        return kTECUnmappableElementErr;
    }
    CFIndex len = CFStringGetLength(s);
    CFIndex fit = (CFIndex)(iOutputBufLen / sizeof(UniChar));
    CFIndex n = len < fit ? len : fit;
    CFStringGetCharacters(s, CFRangeMake(0, n), oUnicodeStr);
    CFRelease(s);
    if (oSourceRead)
        *oSourceRead = n == len ? iSourceLen : 0;
    if (oUnicodeLen)
        *oUnicodeLen = n * sizeof(UniChar);
    return n == len ? noErr : kTECOutputBufferFullStatus;
}

OSStatus
ConvertFromUnicodeToText(UnicodeToTextInfo iUnicodeToTextInfo, ByteCount iUnicodeLen, const UniChar *iUnicodeStr,
                         OptionBits iControlFlags, ItemCount iOffsetCount, const ByteOffset *iOffsetArray,
                         ItemCount *oOffsetCount, ByteOffset *oOffsetArray, ByteCount iOutputBufLen,
                         ByteCount *oInputRead, ByteCount *oOutputLen, LogicalAddress oOutputStr)
{
    struct converter *c = (struct converter *)iUnicodeToTextInfo;
    if (!c || !iUnicodeStr || !oOutputStr)
        return paramErr;
    if (oOffsetCount)
        *oOffsetCount = 0;
    CFStringRef s = CFStringCreateWithCharacters(NULL, iUnicodeStr, iUnicodeLen / sizeof(UniChar));
    CFIndex used = 0, len = CFStringGetLength(s);
    UInt8 lossByte = (iControlFlags & kUnicodeUseFallbacksMask) ? '?' : 0;
    CFIndex converted = CFStringGetBytes(s, CFRangeMake(0, len), c->to, lossByte, false, oOutputStr, iOutputBufLen, &used);
    CFRelease(s);
    if (oInputRead)
        *oInputRead = converted * sizeof(UniChar);
    if (oOutputLen)
        *oOutputLen = used;
    if (converted < len)
        return used >= (CFIndex)iOutputBufLen ? kTECOutputBufferFullStatus : kTECUnmappableElementErr;
    return noErr;
}

#pragma mark - Component Manager (nothing registered)

ComponentInstance OpenDefaultComponent(OSType componentType, OSType componentSubType) { return NULL; }
OSErr OpenADefaultComponent(OSType componentType, OSType componentSubType, ComponentInstance *ci)
{
    if (ci)
        *ci = NULL;
    return invalidComponentID;
}
ComponentInstance OpenComponent(Component aComponent) { return NULL; }
OSErr OpenAComponent(Component aComponent, ComponentInstance *ci)
{
    if (ci)
        *ci = NULL;
    return invalidComponentID;
}
OSErr CloseComponent(ComponentInstance aComponentInstance) { return invalidComponentID; }
Component FindNextComponent(Component aComponent, ComponentDescription *looking) { return NULL; }
long CountComponents(ComponentDescription *looking) { return 0; }
Component RegisterComponent(ComponentDescription *cd, ComponentRoutineUPP componentEntryPoint, SInt16 global,
                            Handle componentName, Handle componentInfo, Handle componentIcon)
{
    return NULL;
}
OSErr UnregisterComponent(Component aComponent) { return invalidComponentID; }
ComponentResult CallComponentCanDo(ComponentInstance ci, SInt16 ftnNumber) { return 0; }
OSErr GetComponentInfo(Component aComponent, ComponentDescription *cd, Handle componentName, Handle componentInfo,
                       Handle componentIcon)
{
    return invalidComponentID;
}

#pragma mark - Endian flippers

OSStatus
CoreEndianInstallFlipper(OSType dataDomain, OSType dataType, CoreEndianFlipProc flipProc, void *refCon)
{
    return noErr;  /* data is never flipped: Finch runs only little-endian code reading little-endian data */
}

OSStatus
CoreEndianGetFlipper(OSType dataDomain, OSType dataType, CoreEndianFlipProc *flipProc, void **refCon)
{
    return paramErr;
}

OSStatus
CoreEndianFlipData(OSType dataDomain, OSType dataType, SInt16 id, void *data, ByteCount dataLen, Boolean currentlyNative)
{
    return noErr;
}
