#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSNotificationName const PHLSyncDidUpdateStateNotification;
FOUNDATION_EXPORT NSNotificationName const PHLSyncProgressNotification;

@interface PHLVoiceItem : NSObject
@property (nonatomic, copy, readonly) NSString *voiceId;
@property (nonatomic, copy, readonly) NSString *name;
@property (nonatomic, copy, readonly) NSString *voiceDescription;
@property (nonatomic, copy, readonly) NSString *category;
@property (nonatomic, assign, readonly) BOOL locked;
@property (nonatomic, assign, readonly) BOOL effectiveLocked;
@property (nonatomic, copy, readonly) NSString *packPath;
@property (nonatomic, copy, readonly) NSString *packSha256;
@end

@interface PHLVoicePack : NSObject
@property (nonatomic, copy, readonly) NSString *voiceId;
@property (nonatomic, assign, readonly) float pitchSemitones;
@property (nonatomic, assign, readonly) float formantShift;
@property (nonatomic, assign, readonly) float eqLowDb;
@property (nonatomic, assign, readonly) float eqMidDb;
@property (nonatomic, assign, readonly) float eqHighDb;
@property (nonatomic, assign, readonly) float noiseGateDb;
@property (nonatomic, assign, readonly) float compressorThresholdDb;
@property (nonatomic, assign, readonly) float compressorRatio;
@property (nonatomic, assign, readonly) float limiterCeilingDb;
@property (nonatomic, assign, readonly) float naturalness;
@property (nonatomic, assign, readonly) float targetF0Hz;
@property (nonatomic, assign, readonly) BOOL adaptivePitch;
@property (nonatomic, assign, readonly) double detectedF0Hz;
@end

@interface PHLMusicTrack : NSObject
@property (nonatomic, copy, readonly) NSString *trackId;
@property (nonatomic, copy, readonly) NSString *title;
@property (nonatomic, copy, readonly) NSString *artist;
@property (nonatomic, assign, readonly) NSInteger durationSec;
@property (nonatomic, copy, readonly) NSString *filePath;
@property (nonatomic, assign, readonly) int64_t fileSizeBytes;
@property (nonatomic, copy, readonly) NSString *sha256Hex;
@property (nonatomic, assign, readonly) BOOL locked;
@property (nonatomic, assign, readonly) BOOL effectiveLocked;
@property (nonatomic, assign, readonly) float defaultVolume;
@property (nonatomic, strong, readonly) NSURL *remoteURL;
@end

@interface PHLSyncManager : NSObject

+ (instancetype)sharedManager;

@property (atomic, assign, readonly) BOOL globalLock;
@property (atomic, assign, readonly) BOOL musicGlobalLock;
@property (atomic, assign, readonly) BOOL maintenanceEnabled;
@property (atomic, copy, readonly) NSString *maintenanceMessage;
@property (atomic, assign, readonly) NSInteger manifestVersion;
@property (atomic, copy, readonly) NSString *manifestUpdatedAt;
@property (atomic, assign, readonly) NSInteger playlistVersion;
@property (atomic, assign, readonly) BOOL tamperDetected;
@property (atomic, assign, readonly) BOOL usingOfflineCache;
@property (atomic, assign, readonly) BOOL signatureStrictlyVerified;
@property (atomic, copy, readonly) NSString *statusSummaryText;
@property (atomic, copy, readonly) NSString *lastSyncTimeFormatted;

@property (atomic, copy, readonly) NSArray<PHLVoiceItem *> *voices;
@property (atomic, copy, readonly) NSArray<PHLMusicTrack *> *tracks;
@property (atomic, copy, readonly, nullable) NSString *selectedVoiceId;
@property (atomic, strong, readonly, nullable) PHLVoicePack *activeVoicePack;
@property (atomic, assign) BOOL voiceChangeEnabled;

- (void)startAutoSync;
- (void)stopAutoSync;
- (void)syncNowWithCompletion:(void (^ _Nullable)(BOOL success, NSString *message))completion;
- (void)selectVoiceWithId:(NSString *)voiceId
               completion:(void (^ _Nullable)(BOOL success, PHLVoicePack * _Nullable pack, NSString *message))completion;
- (BOOL)isCurrentVoiceEffectiveLocked;
- (nullable PHLVoiceItem *)voiceItemForId:(NSString *)voiceId;
- (nullable PHLMusicTrack *)trackForId:(NSString *)trackId;

@end

NS_ASSUME_NONNULL_END
