/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-cftokenizer-test: CFStringTokenizer by words, sentences, paragraphs, word
 * boundaries and line breaks, with token types and GoToTokenAtIndex. Run it against
 * Apple's CoreFoundation and Finch's and diff all but the first line. (Chinese and
 * Japanese words are left out: Apple's segmenter is its own, Finch's is ICU's.)
 */
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <stdio.h>
static void run(const char *label, CFStringRef s, CFOptionFlags unit) {
  CFStringTokenizerRef t = CFStringTokenizerCreate(NULL, s, CFRangeMake(0, CFStringGetLength(s)), unit, NULL);
  printf("%s:", label);
  CFStringTokenizerTokenType ty;
  while ((ty = CFStringTokenizerAdvanceToNextToken(t)) != kCFStringTokenizerTokenNone) {
    CFRange r = CFStringTokenizerGetCurrentTokenRange(t);
    CFStringRef sub = CFStringCreateWithSubstring(NULL, s, r); char b[200]; CFStringGetCString(sub, b, sizeof b, kCFStringEncodingUTF8); CFRelease(sub);
    printf(" [%ld,%ld %s t%lu]", (long)r.location, (long)r.length, b, (unsigned long)ty);
  }
  printf("\n");
  CFStringTokenizerTokenType g = CFStringTokenizerGoToTokenAtIndex(t, 7); CFRange r = CFStringTokenizerGetCurrentTokenRange(t);
  printf("  at 7: t%lu [%ld,%ld]\n", (unsigned long)g, (long)r.location, (long)r.length);
  CFRelease(t);
}
int main(void) {
  Dl_info dl;
  dladdr((void *)CFStringTokenizerCreate, &dl);
  printf("%s\n", dl.dli_fname);
  CFStringRef s = CFSTR("Hello, world! It's 2026, isn't it? \nSecond paragraph here.\n");
  run("word", s, kCFStringTokenizerUnitWord);
  run("sentence", s, kCFStringTokenizerUnitSentence);
  run("paragraph", s, kCFStringTokenizerUnitParagraph);
  run("wordboundary", CFSTR("a b, c"), kCFStringTokenizerUnitWordBoundary);
  run("linebreak", CFSTR("one two-three four"), kCFStringTokenizerUnitLineBreak);
  return 0;
}
