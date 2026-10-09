/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSSpellChecker: Finch has no dictionaries or grammar checking yet, so it
 * finds nothing to correct: every word is spelled right, there are no
 * guesses or completions, and checking returns no results. The document
 * tags, learned and ignored words, and the settings behave as Apple's, so
 * text views and apps using them run unchanged.
 */
#import "NSView_Finch.h"

__attribute__((visibility("default"))) NSString *const NSSpellCheckerDidChangeAutomaticCapitalizationNotification = @"NSSpellCheckerDidChangeAutomaticCapitalizationNotification";
__attribute__((visibility("default"))) NSString *const NSSpellCheckerDidChangeAutomaticDashSubstitutionNotification = @"NSSpellCheckerDidChangeAutomaticDashSubstitutionNotification";
__attribute__((visibility("default"))) NSString *const NSSpellCheckerDidChangeAutomaticInlinePredictionNotification = @"NSSpellCheckerDidChangeAutomaticInlinePredictionNotification";
__attribute__((visibility("default"))) NSString *const NSSpellCheckerDidChangeAutomaticPeriodSubstitutionNotification = @"NSSpellCheckerDidChangeAutomaticPeriodSubstitutionNotification";
__attribute__((visibility("default"))) NSString *const NSSpellCheckerDidChangeAutomaticQuoteSubstitutionNotification = @"NSSpellCheckerDidChangeAutomaticQuoteSubstitutionNotification";
__attribute__((visibility("default"))) NSString *const NSSpellCheckerDidChangeAutomaticSpellingCorrectionNotification = @"NSSpellCheckerDidChangeAutomaticSpellingCorrectionNotification";
__attribute__((visibility("default"))) NSString *const NSSpellCheckerDidChangeAutomaticTextCompletionNotification = @"NSSpellCheckerDidChangeAutomaticTextCompletionNotification";
__attribute__((visibility("default"))) NSString *const NSSpellCheckerDidChangeAutomaticTextReplacementNotification = @"NSSpellCheckerDidChangeAutomaticTextReplacementNotification";
__attribute__((visibility("default"))) NSString *NSTextCheckingGenerateInlinePredictionsKey = @"GenerateInlinePredictions";
__attribute__((visibility("default"))) NSString *NSTextCheckingRegularExpressionsKey = @"RegularExpressions";

@implementation NSSpellChecker {
    NSString *_language;
    NSMutableDictionary<NSNumber *, NSMutableSet *> *_ignored;
    NSMutableSet *_learned;
    BOOL _automaticallyIdentifiesLanguages;
}

static NSSpellChecker *shared_checker;
static NSInteger next_tag = 1;

+ (NSSpellChecker *)sharedSpellChecker
{
    if (!shared_checker)
        shared_checker = [[NSSpellChecker alloc] init];
    return shared_checker;
}

+ (BOOL)sharedSpellCheckerExists { return shared_checker != nil; }
+ (NSInteger)uniqueSpellDocumentTag { return next_tag++; }
+ (BOOL)isAutomaticTextReplacementEnabled { return NO; }
+ (BOOL)isAutomaticSpellingCorrectionEnabled { return NO; }
+ (BOOL)isAutomaticQuoteSubstitutionEnabled { return NO; }
+ (BOOL)isAutomaticDashSubstitutionEnabled { return NO; }
+ (BOOL)isAutomaticCapitalizationEnabled { return NO; }
+ (BOOL)isAutomaticPeriodSubstitutionEnabled { return NO; }
+ (BOOL)isAutomaticTextCompletionEnabled { return NO; }
+ (BOOL)isAutomaticInlinePredictionEnabled { return NO; }

- (instancetype)init
{
    self = [super init];
    if (self) {
        _language = [@"en" retain];
        _ignored = [[NSMutableDictionary alloc] init];
        _learned = [[NSMutableSet alloc] init];
        _automaticallyIdentifiesLanguages = YES;
    }
    return self;
}

- (void)dealloc
{
    [_language release];
    [_ignored release];
    [_learned release];
    [super dealloc];
}

- (NSArray<NSString *> *)availableLanguages { return @[ @"en" ]; }
- (NSArray<NSString *> *)userPreferredLanguages { return @[ @"en" ]; }
- (NSString *)language { return _language; }
- (BOOL)setLanguage:(NSString *)language
{
    [_language autorelease];
    _language = [language copy];
    return YES;
}
- (BOOL)automaticallyIdentifiesLanguages { return _automaticallyIdentifiesLanguages; }
- (void)setAutomaticallyIdentifiesLanguages:(BOOL)flag { _automaticallyIdentifiesLanguages = flag; }

- (NSRange)checkSpellingOfString:(NSString *)stringToCheck startingAt:(NSInteger)startingOffset
{
    return NSMakeRange(NSNotFound, 0);
}

- (NSRange)checkSpellingOfString:(NSString *)stringToCheck startingAt:(NSInteger)startingOffset
                        language:(NSString *)language wrap:(BOOL)wrapFlag
          inSpellDocumentWithTag:(NSInteger)tag wordCount:(NSInteger *)wordCount
{
    if (wordCount)
        *wordCount = [self countWordsInString:stringToCheck language:language];
    return NSMakeRange(NSNotFound, 0);
}

- (NSRange)checkGrammarOfString:(NSString *)stringToCheck startingAt:(NSInteger)startingOffset
                       language:(NSString *)language wrap:(BOOL)wrapFlag
         inSpellDocumentWithTag:(NSInteger)tag details:(NSArray<NSDictionary<NSString *, id> *> **)details
{
    if (details)
        *details = @[];
    return NSMakeRange(NSNotFound, 0);
}

- (NSArray<NSTextCheckingResult *> *)checkString:(NSString *)stringToCheck range:(NSRange)range
                                           types:(NSTextCheckingTypes)checkingTypes
                                         options:(NSDictionary<NSTextCheckingOptionKey, id> *)options
                          inSpellDocumentWithTag:(NSInteger)tag
                                     orthography:(NSOrthography **)orthography
                                       wordCount:(NSInteger *)wordCount
{
    if (orthography)
        *orthography = nil;
    if (wordCount)
        *wordCount = [self countWordsInString:[stringToCheck substringWithRange:range] language:nil];
    return @[];
}

- (NSInteger)requestCheckingOfString:(NSString *)stringToCheck range:(NSRange)range
                               types:(NSTextCheckingTypes)checkingTypes
                             options:(NSDictionary<NSTextCheckingOptionKey, id> *)options
              inSpellDocumentWithTag:(NSInteger)tag
                   completionHandler:(void (^)(NSInteger, NSArray<NSTextCheckingResult *> *, NSOrthography *,
                                               NSInteger))completionHandler
{
    NSInteger sequence = next_tag++;
    NSInteger words = [self countWordsInString:[stringToCheck substringWithRange:range] language:nil];
    if (completionHandler)
        completionHandler(sequence, @[], nil, words);
    return sequence;
}

- (NSInteger)countWordsInString:(NSString *)stringToCount language:(NSString *)language
{
    __block NSInteger n = 0;
    [stringToCount enumerateSubstringsInRange:NSMakeRange(0, [stringToCount length])
                                      options:NSStringEnumerationByWords | NSStringEnumerationSubstringNotRequired
                                   usingBlock:^(NSString *s, NSRange r, NSRange e, BOOL *stop) {
                                       n++;
                                   }];
    return n;
}

- (NSArray<NSString *> *)guessesForWordRange:(NSRange)range inString:(NSString *)string language:(NSString *)language
                      inSpellDocumentWithTag:(NSInteger)tag
{
    return @[];
}

- (NSString *)correctionForWordRange:(NSRange)range inString:(NSString *)string language:(NSString *)language
              inSpellDocumentWithTag:(NSInteger)tag
{
    return nil;
}

- (NSArray<NSString *> *)completionsForPartialWordRange:(NSRange)range inString:(NSString *)string
                                               language:(NSString *)language
                                 inSpellDocumentWithTag:(NSInteger)tag
{
    return @[];
}

- (void)ignoreWord:(NSString *)wordToIgnore inSpellDocumentWithTag:(NSInteger)tag
{
    NSMutableSet *set = _ignored[@(tag)];
    if (!set)
        _ignored[@(tag)] = set = [NSMutableSet set];
    [set addObject:wordToIgnore];
}

- (NSArray<NSString *> *)ignoredWordsInSpellDocumentWithTag:(NSInteger)tag
{
    return [_ignored[@(tag)] allObjects];
}

- (void)setIgnoredWords:(NSArray<NSString *> *)words inSpellDocumentWithTag:(NSInteger)tag
{
    _ignored[@(tag)] = [NSMutableSet setWithArray:words];
}

- (void)closeSpellDocumentWithTag:(NSInteger)tag
{
    [_ignored removeObjectForKey:@(tag)];
}

- (void)learnWord:(NSString *)word { [_learned addObject:word]; }
- (BOOL)hasLearnedWord:(NSString *)word { return [_learned containsObject:word]; }
- (void)unlearnWord:(NSString *)word { [_learned removeObject:word]; }
- (NSArray<NSString *> *)userQuotesArrayForLanguage:(NSString *)language
{
    return @[ @"“", @"”", @"‘", @"’" ];
}
- (NSDictionary<NSString *, NSString *> *)userReplacementsDictionary { return @{}; }
- (void)updateSpellingPanelWithMisspelledWord:(NSString *)word {}
- (void)updateSpellingPanelWithGrammarString:(NSString *)string detail:(NSDictionary *)detail {}
- (NSPanel *)spellingPanel { return nil; }
- (NSView *)accessoryView { return nil; }
- (void)setAccessoryView:(NSView *)view {}
- (NSPanel *)substitutionsPanel { return nil; }
- (NSViewController *)substitutionsPanelAccessoryViewController { return nil; }
- (void)setSubstitutionsPanelAccessoryViewController:(NSViewController *)c {}
- (void)updatePanels {}
- (NSMenu *)menuForResult:(NSTextCheckingResult *)result string:(NSString *)checkedString
                  options:(NSDictionary<NSTextCheckingOptionKey, id> *)options atLocation:(NSPoint)location
                   inView:(NSView *)view
{
    return nil;
}
- (BOOL)hasLearnedWord:(NSString *)word language:(NSString *)language { return [self hasLearnedWord:word]; }
- (void)dismissCorrectionIndicatorForView:(NSView *)view {}
- (NSString *)languageForWordRange:(NSRange)range inString:(NSString *)string orthography:(NSOrthography *)o
{
    return _language;
}
- (BOOL)preventsAutocorrectionBeforeString:(NSString *)string language:(NSString *)language { return NO; }
- (void)recordResponse:(NSCorrectionResponse)response toCorrection:(NSString *)correction forWord:(NSString *)word
              language:(NSString *)language inSpellDocumentWithTag:(NSInteger)tag
{
}

@end
