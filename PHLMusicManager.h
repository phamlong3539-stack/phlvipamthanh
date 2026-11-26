#import <Foundation/Foundation.h>
#import "PHLSyncManager.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSNotificationName const PHLMusicStateDidChangeNotification;
FOUNDATION_EXPORT NSNotificationName const PHLMusicDownloadProgressNotification;

@interface PHLMusicManager : NSObject

+ (instancetype)sharedManager;

@property (nonatomic, strong, readonly, nullable) PHLMusicTrack *currentTrack;
@property (nonatomic, assign, readonly) BOOL isPlaying;
@property (nonatomic, assign, readonly) BOOL isDownloading;
@property (nonatomic, assign, readonly) NSTimeInterval currentTime;
@property (nonatomic, assign, readonly) NSTimeInterval duration;
@property (nonatomic, assign) float volume;

- (void)playTrack:(PHLMusicTrack *)track;
- (void)togglePlayPause;
- (void)stop;
- (void)playNext;
- (void)playPrevious;
- (BOOL)isTrackCached:(PHLMusicTrack *)track;

@end

NS_ASSUME_NONNULL_END
