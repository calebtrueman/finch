/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * CFStringTokenizer: words, sentences, paragraphs and line breaks of a string
 * (public API, <CoreFoundation/CFStringTokenizer.h>). swift-corelibs has no
 * implementation, so this is Finch's, over ICU's break iterators:
 *
 *   - Words skip what ICU says isn't a word (spaces, punctuation); word
 *     boundaries give every segment.
 *   - Paragraphs end at paragraph separators (newlines, U+2029); their ranges
 *     include the separator, as sentences' do.
 *   - A token's type says whether it has numbers, non-letters, or is CJK.
 *
 * Latin transcriptions, sub-tokens and language guessing aren't provided:
 * CopyCurrentTokenAttribute returns NULL, GetCurrentSubTokens 0, and
 * CopyBestStringLanguage the system's first language (or NULL).
 */

#include "CFInternal.h"
#include "CFRuntime_Internal.h"

#include <_foundation_unicode/ubrk.h>
#include <dispatch/dispatch.h>

/* <CoreFoundation/CFStringTokenizer.h>'s public declarations; swift-corelibs has no copy of it. */
typedef struct __CFStringTokenizer *CFStringTokenizerRef;
enum {
    kCFStringTokenizerUnitWord = 0,
    kCFStringTokenizerUnitSentence = 1,
    kCFStringTokenizerUnitParagraph = 2,
    kCFStringTokenizerUnitLineBreak = 3,
    kCFStringTokenizerUnitWordBoundary = 4,
    kCFStringTokenizerAttributeLatinTranscription = 1UL << 16,
    kCFStringTokenizerAttributeLanguage = 1UL << 17,
};
typedef CFOptionFlags CFStringTokenizerTokenType;
enum {
    kCFStringTokenizerTokenNone = 0,
    kCFStringTokenizerTokenNormal = 1UL << 0,
    kCFStringTokenizerTokenHasSubTokensMask = 1UL << 1,
    kCFStringTokenizerTokenHasDerivedSubTokensMask = 1UL << 2,
    kCFStringTokenizerTokenHasHasNumbersMask = 1UL << 3,
    kCFStringTokenizerTokenHasNonLettersMask = 1UL << 4,
    kCFStringTokenizerTokenIsCJWordMask = 1UL << 5,
};
#include <stdlib.h>

struct __CFStringTokenizer {
    CFRuntimeBase base;
    CFStringRef string;
    CFRange range;
    CFOptionFlags options;
    CFLocaleRef locale;
    UniChar *chars;           /* the range's characters */
    UBreakIterator *iterator; /* NULL for paragraphs */
    CFRange token;            /* the current token, kCFNotFound for none */
};

static void
tokenizer_finalize(CFTypeRef cf)
{
    struct __CFStringTokenizer *t = (struct __CFStringTokenizer *)cf;
    if (t->iterator)
        ubrk_close(t->iterator);
    free(t->chars);
    if (t->string)
        CFRelease(t->string);
    if (t->locale)
        CFRelease(t->locale);
}

static const CFRuntimeClass tokenizer_class = {
    0, "CFStringTokenizer", NULL, NULL, tokenizer_finalize, NULL, NULL, NULL, NULL, NULL, NULL, 0,
};

CFTypeID
CFStringTokenizerGetTypeID(void)
{
    static CFTypeID type = _kCFRuntimeNotATypeID;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ type = _CFRuntimeRegisterClass(&tokenizer_class); });
    return type;
}

static CFIndex
unit(CFOptionFlags options)
{
    return (CFIndex)(options & 0xff);
}

static void
set_string(struct __CFStringTokenizer *t, CFStringRef string, CFRange range)
{
    if (t->iterator)
        ubrk_close(t->iterator);
    t->iterator = NULL;
    free(t->chars);
    t->chars = NULL;
    if (t->string)
        CFRelease(t->string);
    t->string = string ? CFStringCreateCopy(kCFAllocatorSystemDefault, string) : CFSTR("");
    CFIndex len = CFStringGetLength(t->string);
    if (range.location < 0 || range.location > len)
        range = CFRangeMake(0, 0);
    if (range.location + range.length > len)
        range.length = len - range.location;
    t->range = range;
    t->token = CFRangeMake(kCFNotFound, 0);
    t->chars = malloc((size_t)(range.length ? range.length : 1) * sizeof(UniChar));
    CFStringGetCharacters(t->string, range, t->chars);
    if (unit(t->options) == kCFStringTokenizerUnitParagraph)
        return;
    UBreakIteratorType kind = unit(t->options) == kCFStringTokenizerUnitSentence    ? UBRK_SENTENCE
                              : unit(t->options) == kCFStringTokenizerUnitLineBreak ? UBRK_LINE
                                                                                    : UBRK_WORD;
    char locale[64] = "";
    if (t->locale)
        CFStringGetCString(CFLocaleGetIdentifier(t->locale), locale, sizeof locale, kCFStringEncodingASCII);
    UErrorCode status = U_ZERO_ERROR;
    t->iterator = ubrk_open(kind, locale, (const UChar *)t->chars, (int32_t)range.length, &status);
    if (U_FAILURE(status))
        t->iterator = NULL;
}

CFStringTokenizerRef
CFStringTokenizerCreate(CFAllocatorRef alloc, CFStringRef string, CFRange range, CFOptionFlags options,
                        CFLocaleRef locale)
{
    struct __CFStringTokenizer *t = (struct __CFStringTokenizer *)_CFRuntimeCreateInstance(
        alloc, CFStringTokenizerGetTypeID(), sizeof(struct __CFStringTokenizer) - sizeof(CFRuntimeBase), NULL);
    if (!t)
        return NULL;
    t->options = options;
    t->locale = locale ? (CFLocaleRef)CFRetain(locale) : NULL;
    set_string(t, string, range);
    return t;
}

void
CFStringTokenizerSetString(CFStringTokenizerRef tokenizer, CFStringRef string, CFRange range)
{
    set_string((struct __CFStringTokenizer *)tokenizer, string, range);
}

static Boolean
is_paragraph_break(UniChar c)
{
    return c == '\n' || c == '\r' || c == 0x2029 || c == 0x85;
}

/*
 * The token type, as Apple's: only words and word boundaries carry flags. A token with digits
 * has numbers (and, as Apple's says, sub-tokens); one with neither letters nor digits is
 * non-letters; Chinese and Japanese ones are CJ words.
 */
static CFStringTokenizerTokenType
token_type(struct __CFStringTokenizer *t)
{
    CFStringTokenizerTokenType type = kCFStringTokenizerTokenNormal;
    CFIndex u = unit(t->options);
    if (u != kCFStringTokenizerUnitWord && u != kCFStringTokenizerUnitWordBoundary)
        return type;
    CFCharacterSetRef letters = CFCharacterSetGetPredefined(kCFCharacterSetLetter);
    Boolean digits = false, letter = false, cj = false;
    CFIndex start = t->token.location - t->range.location;
    for (CFIndex i = start; i < start + t->token.length; i++) {
        UniChar c = t->chars[i];
        if (c >= '0' && c <= '9')
            digits = true;
        else if (CFCharacterSetIsCharacterMember(letters, c))
            letter = true;
        if ((c >= 0x3040 && c <= 0x30ff) || (c >= 0x4e00 && c <= 0x9fff) || (c >= 0x3400 && c <= 0x4dbf))
            cj = true;
    }
    if (digits)
        type |= kCFStringTokenizerTokenHasHasNumbersMask | kCFStringTokenizerTokenHasSubTokensMask;
    if (!digits && !letter)
        type |= kCFStringTokenizerTokenHasNonLettersMask;
    if (cj)
        type |= kCFStringTokenizerTokenIsCJWordMask;
    return type;
}

/* Move to the token that starts at or after `from` (relative to the range); NO when there's none. */
static Boolean
find_from(struct __CFStringTokenizer *t, CFIndex from)
{
    CFIndex len = t->range.length;
    if (unit(t->options) == kCFStringTokenizerUnitParagraph) {
        if (from >= len)
            return false;
        CFIndex end = from;
        while (end < len && !is_paragraph_break(t->chars[end]))
            end++;
        if (end < len)
            end += (t->chars[end] == '\r' && end + 1 < len && t->chars[end + 1] == '\n') ? 2 : 1;
        t->token = CFRangeMake(t->range.location + from, end - from);
        return true;
    }
    if (!t->iterator)
        return false;
    int32_t start = from <= 0 ? ubrk_first(t->iterator) : ubrk_preceding(t->iterator, (int32_t)from + 1);
    if (start == UBRK_DONE)
        start = 0;
    if (start < from)
        start = ubrk_following(t->iterator, (int32_t)from - 1) == (int32_t)from ? (int32_t)from : start;
    ubrk_isBoundary(t->iterator, start);
    while (start != UBRK_DONE && start < len) {
        int32_t end = ubrk_next(t->iterator);
        if (end == UBRK_DONE)
            break;
        Boolean wordsOnly = unit(t->options) == kCFStringTokenizerUnitWord;
        if (!wordsOnly || ubrk_getRuleStatus(t->iterator) != UBRK_WORD_NONE) {
            if (start >= from || unit(t->options) != kCFStringTokenizerUnitWord) {
                t->token = CFRangeMake(t->range.location + start, end - start);
                return true;
            }
        }
        start = end;
    }
    return false;
}

CFStringTokenizerTokenType
CFStringTokenizerAdvanceToNextToken(CFStringTokenizerRef tokenizer)
{
    struct __CFStringTokenizer *t = (struct __CFStringTokenizer *)tokenizer;
    CFIndex from = t->token.location == kCFNotFound ? 0 : t->token.location - t->range.location + t->token.length;
    if (!find_from(t, from)) {
        t->token = CFRangeMake(kCFNotFound, 0);
        return kCFStringTokenizerTokenNone;
    }
    return token_type(t);
}

CFStringTokenizerTokenType
CFStringTokenizerGoToTokenAtIndex(CFStringTokenizerRef tokenizer, CFIndex index)
{
    struct __CFStringTokenizer *t = (struct __CFStringTokenizer *)tokenizer;
    CFIndex rel = index - t->range.location;
    t->token = CFRangeMake(kCFNotFound, 0);
    if (rel < 0 || rel >= t->range.length)
        return kCFStringTokenizerTokenNone;
    /* the token containing the index: scan from the start (tokens are short) */
    CFIndex from = 0;
    while (find_from(t, from)) {
        CFIndex s = t->token.location - t->range.location, e = s + t->token.length;
        if (rel >= s && rel < e)
            return token_type(t);
        if (s > rel || e <= from)
            break;
        from = e;
    }
    t->token = CFRangeMake(kCFNotFound, 0);
    return kCFStringTokenizerTokenNone;
}

CFRange
CFStringTokenizerGetCurrentTokenRange(CFStringTokenizerRef tokenizer)
{
    return ((struct __CFStringTokenizer *)tokenizer)->token;
}

CFTypeRef
CFStringTokenizerCopyCurrentTokenAttribute(CFStringTokenizerRef tokenizer, CFOptionFlags attribute)
{
    struct __CFStringTokenizer *t = (struct __CFStringTokenizer *)tokenizer;
    if (t->token.location == kCFNotFound)
        return NULL;
    if (attribute == kCFStringTokenizerAttributeLanguage && t->locale)
        return CFRetain(CFLocaleGetIdentifier(t->locale));
    return NULL;
}

CFIndex
CFStringTokenizerGetCurrentSubTokens(CFStringTokenizerRef tokenizer, CFRange *ranges, CFIndex maxRangeLength,
                                     CFMutableArrayRef derivedSubTokens)
{
    return 0;
}

CFStringRef
CFStringTokenizerCopyBestStringLanguage(CFStringRef string, CFRange range)
{
    CFArrayRef langs = CFLocaleCopyPreferredLanguages();
    CFStringRef best = NULL;
    if (langs && CFArrayGetCount(langs))
        best = CFRetain(CFArrayGetValueAtIndex(langs, 0));
    if (langs)
        CFRelease(langs);
    return best;
}
