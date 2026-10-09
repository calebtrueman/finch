/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSUserActivity belongs to Foundation; LaunchServices also re-exports it.
 * An activity
 * keeps what the app tells it. Finch has no Handoff, Spotlight or Siri
 * suggestions to give it to: becoming current makes it the process's
 * current activity and nothing more.
 */
#import <Foundation/Foundation.h>

NSString *const NSUserActivityTypeBrowsingWeb = @"NSUserActivityTypeBrowsingWeb";

@implementation NSUserActivity {
    NSString *_activityType, *_title, *_persistentIdentifier, *_targetContentIdentifier;
    NSDictionary *_userInfo;
    NSSet *_requiredUserInfoKeys, *_keywords;
    NSURL *_webpageURL, *_referrerURL;
    NSDate *_expirationDate;
    id _delegate;
    BOOL _needsSave, _supportsContinuationStreams, _eligibleForHandoff, _eligibleForSearch, _eligibleForPublicIndexing,
        _eligibleForPrediction, _invalidated;
}

static NSUserActivity *current;

- (instancetype)initWithActivityType:(NSString *)activityType
{
    if ((self = [super init])) {
        _activityType = [activityType copy];
        _eligibleForHandoff = YES;
    }
    return self;
}

- (instancetype)init
{
    NSString *type = [[[NSBundle mainBundle] infoDictionary][@"NSUserActivityTypes"] firstObject];
    return [self initWithActivityType:[type isKindOfClass:[NSString class]] ? type : @""];
}

- (void)dealloc
{
    [_activityType release];
    [_title release];
    [_persistentIdentifier release];
    [_targetContentIdentifier release];
    [_userInfo release];
    [_requiredUserInfoKeys release];
    [_keywords release];
    [_webpageURL release];
    [_referrerURL release];
    [_expirationDate release];
    [super dealloc];
}

- (NSString *)activityType { return _activityType; }
- (NSString *)title { return _title; }
- (void)setTitle:(NSString *)title { [_title autorelease]; _title = [title copy]; }
- (NSDictionary *)userInfo { return _userInfo; }
- (void)setUserInfo:(NSDictionary *)userInfo { [_userInfo autorelease]; _userInfo = [userInfo copy]; }

- (void)addUserInfoEntriesFromDictionary:(NSDictionary *)otherDictionary
{
    NSMutableDictionary *d = [[_userInfo mutableCopy] autorelease] ?: [NSMutableDictionary dictionary];
    [d addEntriesFromDictionary:otherDictionary];
    self.userInfo = d;
}

- (NSSet *)requiredUserInfoKeys { return _requiredUserInfoKeys; }
- (void)setRequiredUserInfoKeys:(NSSet *)keys { [_requiredUserInfoKeys autorelease]; _requiredUserInfoKeys = [keys copy]; }
- (NSSet *)keywords { return _keywords ?: [NSSet set]; }
- (void)setKeywords:(NSSet *)keywords { [_keywords autorelease]; _keywords = [keywords copy]; }
- (NSURL *)webpageURL { return _webpageURL; }
- (void)setWebpageURL:(NSURL *)url { [_webpageURL autorelease]; _webpageURL = [url copy]; }
- (NSURL *)referrerURL { return _referrerURL; }
- (void)setReferrerURL:(NSURL *)url { [_referrerURL autorelease]; _referrerURL = [url copy]; }
- (NSDate *)expirationDate { return _expirationDate; }
- (void)setExpirationDate:(NSDate *)date { [_expirationDate autorelease]; _expirationDate = [date copy]; }
- (NSString *)persistentIdentifier { return _persistentIdentifier; }
- (void)setPersistentIdentifier:(NSString *)p { [_persistentIdentifier autorelease]; _persistentIdentifier = [p copy]; }
- (NSString *)targetContentIdentifier { return _targetContentIdentifier; }
- (void)setTargetContentIdentifier:(NSString *)t { [_targetContentIdentifier autorelease]; _targetContentIdentifier = [t copy]; }
- (id)delegate { return _delegate; }
- (void)setDelegate:(id)delegate { _delegate = delegate; }
- (BOOL)needsSave { return _needsSave; }
- (void)setNeedsSave:(BOOL)v { _needsSave = v; }
- (BOOL)supportsContinuationStreams { return _supportsContinuationStreams; }
- (void)setSupportsContinuationStreams:(BOOL)v { _supportsContinuationStreams = v; }
- (BOOL)isEligibleForHandoff { return _eligibleForHandoff; }
- (void)setEligibleForHandoff:(BOOL)v { _eligibleForHandoff = v; }
- (BOOL)isEligibleForSearch { return _eligibleForSearch; }
- (void)setEligibleForSearch:(BOOL)v { _eligibleForSearch = v; }
- (BOOL)isEligibleForPublicIndexing { return _eligibleForPublicIndexing; }
- (void)setEligibleForPublicIndexing:(BOOL)v { _eligibleForPublicIndexing = v; }
- (BOOL)isEligibleForPrediction { return _eligibleForPrediction; }
- (void)setEligibleForPrediction:(BOOL)v { _eligibleForPrediction = v; }

- (void)becomeCurrent
{
    if (_invalidated)
        return;
    @synchronized([NSUserActivity class]) {
        if (current != self) {
            [current release];
            current = [self retain];
        }
    }
}

- (void)resignCurrent
{
    @synchronized([NSUserActivity class]) {
        if (current == self) {
            [current autorelease];
            current = nil;
        }
    }
}

- (void)invalidate
{
    [self resignCurrent];
    _invalidated = YES;
}

- (void)getContinuationStreamsWithCompletionHandler:(void (^)(NSInputStream *, NSOutputStream *, NSError *))handler
{
    if (handler)
        handler(nil, nil, [NSError errorWithDomain:NSCocoaErrorDomain code:NSUserActivityConnectionUnavailableError userInfo:nil]);
}

+ (void)deleteSavedUserActivitiesWithPersistentIdentifiers:(NSArray *)identifiers completionHandler:(void (^)(void))handler
{
    if (handler)
        handler();
}

+ (void)deleteAllSavedUserActivitiesWithCompletionHandler:(void (^)(void))handler
{
    if (handler)
        handler();
}

@end
