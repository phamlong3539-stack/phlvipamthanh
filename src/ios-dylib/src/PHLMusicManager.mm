#import "PHLMusicManager.h"

#import <AVFoundation/AVFoundation.h>
#import <CommonCrypto/CommonCrypto.h>

NSNotificationName const PHLMusicStateDidChangeNotification = @"PHLMusicStateDidChangeNotification";
NSNotificationName const PHLMusicDownloadProgressNotification = @"PHLMusicDownloadProgressNotification";

static NSString *PHLFileSHA256Hex(NSString *filePath) {
    NSInputStream *stream = [NSInputStream inputStreamWithFileAtPath:filePath];
    if (!stream) return @"";
    [stream open];
    CC_SHA256_CTX ctx;
    CC_SHA256_Init(&ctx);
    uint8_t buf[16384];
    while ([stream hasBytesAvailable]) {
        NSInteger readLen = [stream read:buf maxLength:sizeof(buf)];
        if (readLen > 0) {
            CC_SHA256_Update(&ctx, buf, (CC_LONG)readLen);
        } else {
            break;
        }
    }
    [stream close];
    uint8_t digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &ctx);
    static const char hex[] = "0123456789abcdef";
    NSMutableString *out = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; ++i) {
        [out appendFormat:@"%c%c", hex[(digest[i] >> 4) & 0xF], hex[digest[i] & 0xF]];
    }
    return [out copy];
}

@interface PHLMusicManager () <AVAudioPlayerDelegate, NSURLSessionDownloadDelegate>
@property (nonatomic, strong, readwrite, nullable) PHLMusicTrack *currentTrack;
@property (nonatomic, assign, readwrite) BOOL isPlaying;
@property (nonatomic, assign, readwrite) BOOL isDownloading;
@property (nonatomic, strong, nullable) AVAudioPlayer *audioPlayer;
@property (nonatomic, strong) NSURLSession *downloadSession;
@property (nonatomic, strong, nullable) NSURLSessionDownloadTask *activeDownloadTask;
@property (nonatomic, strong, nullable) PHLMusicTrack *pendingTrack;
@end

@implementation PHLMusicManager

+ (instancetype)sharedManager {
    static PHLMusicManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[PHLMusicManager alloc] initPrivate];
    });
    return instance;
}

- (instancetype)initPrivate {
    self = [super init];
    if (self) {
        NSNumber *savedVol = [[NSUserDefaults standardUserDefaults] objectForKey:@"PHL_MusicVolume"];
        _volume = savedVol ? MAX(0.0f, MIN(1.0f, [savedVol floatValue])) : 0.70f;

        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        cfg.URLCache = nil;
        cfg.timeoutIntervalForRequest = 15.0;
        cfg.timeoutIntervalForResource = 120.0;
        _downloadSession = [NSURLSession sessionWithConfiguration:cfg delegate:self delegateQueue:[NSOperationQueue mainQueue]];

        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(handleSyncUpdated)
                                                     name:PHLSyncDidUpdateStateNotification
                                                   object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_downloadSession invalidateAndCancel];
}

- (NSString *)musicCacheDirectory {
    NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    NSString *base = paths.firstObject ?: NSTemporaryDirectory();
    NSString *dir = [base stringByAppendingPathComponent:@"PHLMusicCache"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

- (NSString *)localCachePathForTrack:(PHLMusicTrack *)track {
    NSString *ext = track.filePath.pathExtension.length > 0 ? track.filePath.pathExtension : @"mp3";
    NSString *shaPrefix = track.sha256Hex.length >= 10 ? [track.sha256Hex substringToIndex:10] : @"v1";
    NSString *name = [NSString stringWithFormat:@"%@_%@.%@", track.trackId, shaPrefix, ext];
    return [[self musicCacheDirectory] stringByAppendingPathComponent:name];
}

- (BOOL)isTrackCached:(PHLMusicTrack *)track {
    if (!track) return NO;
    NSString *path = [self localCachePathForTrack:track];
    return [[NSFileManager defaultManager] isReadableFileAtPath:path];
}

- (NSTimeInterval)currentTime {
    return _audioPlayer ? _audioPlayer.currentTime : 0.0;
}

- (NSTimeInterval)duration {
    if (_audioPlayer && _audioPlayer.duration > 0.0) {
        return _audioPlayer.duration;
    }
    return (NSTimeInterval)(_currentTrack ? _currentTrack.durationSec : 0);
}

- (void)setVolume:(float)volume {
    _volume = MAX(0.0f, MIN(1.0f, volume));
    _audioPlayer.volume = _volume;
    [[NSUserDefaults standardUserDefaults] setFloat:_volume forKey:@"PHL_MusicVolume"];
}

- (void)handleSyncUpdated {
    if (!self.currentTrack) return;
    PHLMusicTrack *latest = [[PHLSyncManager sharedManager] trackForId:self.currentTrack.trackId];
    if (!latest || latest.effectiveLocked) {
        [self stop];
        [self postProgress:1.0 step:@"Bài nhạc hiện tại vừa bị khóa bởi Admin — Đã dừng phát" active:NO];
    } else {
        self.currentTrack = latest;
        [self notifyState];
    }
}

- (void)ensurePlaybackAudioSessionCompatibility {
    // Never break an active PlayAndRecord game microphone session.
    AVAudioSession *session = [AVAudioSession sharedInstance];
    AVAudioSessionCategory currentCat = session.category;
    if ([currentCat isEqualToString:AVAudioSessionCategoryAmbient] ||
        [currentCat isEqualToString:AVAudioSessionCategorySoloAmbient]) {
        [session setCategory:AVAudioSessionCategoryPlayback
                 withOptions:AVAudioSessionCategoryOptionMixWithOthers
                       error:nil];
        [session setActive:YES error:nil];
    }
}

- (void)playTrack:(PHLMusicTrack *)track {
    if (!track) return;
    if (track.effectiveLocked) {
        [self postProgress:1.0 step:@"Bài nhạc này đang bị khóa bởi Admin" active:NO];
        return;
    }

    if ([self.currentTrack.trackId isEqualToString:track.trackId] && _audioPlayer) {
        if (!_audioPlayer.isPlaying) {
            [_audioPlayer play];
            self.isPlaying = YES;
            [self notifyState];
        }
        return;
    }

    [_activeDownloadTask cancel];
    _activeDownloadTask = nil;
    _pendingTrack = track;

    NSString *localPath = [self localCachePathForTrack:track];
    if ([[NSFileManager defaultManager] isReadableFileAtPath:localPath]) {
        if (track.sha256Hex.length == 64) {
            NSString *actualSha = PHLFileSHA256Hex(localPath);
            if (![[actualSha lowercaseString] isEqualToString:[track.sha256Hex lowercaseString]]) {
                [[NSFileManager defaultManager] removeItemAtPath:localPath error:nil];
            } else {
                [self startLocalFilePlayback:localPath track:track];
                return;
            }
        } else {
            [self startLocalFilePlayback:localPath track:track];
            return;
        }
    }

    // Download from phl-music-data with smooth staged progress
    self.isDownloading = YES;
    self.currentTrack = track;
    self.isPlaying = NO;
    [self notifyState];
    [self postProgress:0.08 step:[NSString stringWithFormat:@"Đang kết nối phl-music-data: %@", track.title] active:YES];

    uint64_t ms = (uint64_t)([[NSDate date] timeIntervalSince1970] * 1000.0);
    NSString *urlStr = [NSString stringWithFormat:@"%@?cb=%llu", track.remoteURL.absoluteString, ms];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlStr]
                                                       cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                   timeoutInterval:20.0];
    [req setValue:@"no-cache" forHTTPHeaderField:@"Cache-Control"];

    _activeDownloadTask = [_downloadSession downloadTaskWithRequest:req];
    [_activeDownloadTask resume];
}

- (void)startLocalFilePlayback:(NSString *)localPath track:(PHLMusicTrack *)track {
    [self ensurePlaybackAudioSessionCompatibility];
    NSError *err = nil;
    AVAudioPlayer *player = [[AVAudioPlayer alloc] initWithContentsOfURL:[NSURL fileURLWithPath:localPath] error:&err];
    if (!player || err) {
        self.isDownloading = NO;
        self.isPlaying = NO;
        [self postProgress:1.0 step:@"Không giải mã được file nhạc" active:NO];
        [self notifyState];
        return;
    }

    player.delegate = self;
    player.volume = self.volume;
    [player prepareToPlay];
    BOOL started = [player play];

    _audioPlayer = player;
    self.currentTrack = track;
    self.isDownloading = NO;
    self.isPlaying = started;
    [self postProgress:1.0 step:[NSString stringWithFormat:@"Đang phát: %@", track.title] active:NO];
    [self notifyState];
}

- (void)togglePlayPause {
    if (!_audioPlayer) {
        PHLMusicTrack *target = self.currentTrack ?: [self firstUnlockedTrack];
        if (target) [self playTrack:target];
        return;
    }
    if (_audioPlayer.isPlaying) {
        [_audioPlayer pause];
        self.isPlaying = NO;
    } else {
        if (self.currentTrack.effectiveLocked) {
            [self stop];
            return;
        }
        [self ensurePlaybackAudioSessionCompatibility];
        [_audioPlayer play];
        self.isPlaying = YES;
    }
    [self notifyState];
}

- (void)stop {
    [_activeDownloadTask cancel];
    _activeDownloadTask = nil;
    [_audioPlayer stop];
    _audioPlayer = nil;
    self.isDownloading = NO;
    self.isPlaying = NO;
    [self notifyState];
}

- (void)playNext {
    NSArray<PHLMusicTrack *> *list = [self unlockedTracks];
    if (list.count == 0) return;
    NSUInteger idx = [self indexOfTrack:self.currentTrack inList:list];
    NSUInteger nextIdx = (idx == NSNotFound) ? 0 : ((idx + 1) % list.count);
    [self playTrack:list[nextIdx]];
}

- (void)playPrevious {
    NSArray<PHLMusicTrack *> *list = [self unlockedTracks];
    if (list.count == 0) return;
    NSUInteger idx = [self indexOfTrack:self.currentTrack inList:list];
    NSUInteger prevIdx = (idx == NSNotFound || idx == 0) ? (list.count - 1) : (idx - 1);
    [self playTrack:list[prevIdx]];
}

- (NSArray<PHLMusicTrack *> *)unlockedTracks {
    NSMutableArray<PHLMusicTrack *> *res = [NSMutableArray array];
    for (PHLMusicTrack *t in [PHLSyncManager sharedManager].tracks) {
        if (!t.effectiveLocked) [res addObject:t];
    }
    return res;
}

- (nullable PHLMusicTrack *)firstUnlockedTrack {
    return [self unlockedTracks].firstObject;
}

- (NSUInteger)indexOfTrack:(nullable PHLMusicTrack *)track inList:(NSArray<PHLMusicTrack *> *)list {
    if (!track) return NSNotFound;
    for (NSUInteger i = 0; i < list.count; ++i) {
        if ([list[i].trackId isEqualToString:track.trackId]) return i;
    }
    return NSNotFound;
}

#pragma mark - NSURLSessionDownloadDelegate

- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
      didWriteData:(int64_t)bytesWritten
 totalBytesWritten:(int64_t)totalBytesWritten
totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite {
    if (downloadTask != _activeDownloadTask) return;
    double ratio = (totalBytesExpectedToWrite > 0)
        ? (double)totalBytesWritten / (double)totalBytesExpectedToWrite
        : 0.45;
    double progress = 0.12 + 0.76 * MAX(0.0, MIN(1.0, ratio));
    NSString *title = _pendingTrack.title ?: @"nhạc";
    [self postProgress:progress step:[NSString stringWithFormat:@"Đang tải bài nhạc \"%@\" (%.0f%%)...", title, ratio * 100.0] active:YES];
}

- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
didFinishDownloadingToURL:(NSURL *)location {
    if (downloadTask != _activeDownloadTask || !_pendingTrack) return;
    PHLMusicTrack *track = _pendingTrack;
    NSString *destPath = [self localCachePathForTrack:track];

    [[NSFileManager defaultManager] removeItemAtPath:destPath error:nil];
    NSError *moveErr = nil;
    [[NSFileManager defaultManager] moveItemAtURL:location toURL:[NSURL fileURLWithPath:destPath] error:&moveErr];
    if (moveErr) {
        self.isDownloading = NO;
        [self postProgress:1.0 step:@"Lỗi lưu file nhạc tạm" active:NO];
        [self notifyState];
        return;
    }

    if (track.sha256Hex.length == 64) {
        NSString *actualSha = PHLFileSHA256Hex(destPath);
        if (![[actualSha lowercaseString] isEqualToString:[track.sha256Hex lowercaseString]]) {
            [[NSFileManager defaultManager] removeItemAtPath:destPath error:nil];
            self.isDownloading = NO;
            [self postProgress:1.0 step:@"File nhạc tải về không khớp chữ ký SHA-256" active:NO];
            [self notifyState];
            return;
        }
    }

    [self postProgress:0.94 step:@"Đang nạp trình phát nhạc..." active:YES];
    [self startLocalFilePlayback:destPath track:track];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if (task != _activeDownloadTask) return;
    if (error && error.code != NSURLErrorCancelled) {
        self.isDownloading = NO;
        self.isPlaying = NO;
        [self postProgress:1.0 step:@"Tải nhạc thất bại — Kiểm tra mạng" active:NO];
        [self notifyState];
    }
    _activeDownloadTask = nil;
}

#pragma mark - AVAudioPlayerDelegate

- (void)audioPlayerDidFinishPlaying:(AVAudioPlayer *)player successfully:(BOOL)flag {
    if (flag) {
        [self playNext];
    } else {
        self.isPlaying = NO;
        [self notifyState];
    }
}

#pragma mark - Notifications

- (void)postProgress:(double)progress step:(NSString *)step active:(BOOL)active {
    [[NSNotificationCenter defaultCenter] postNotificationName:PHLMusicDownloadProgressNotification
                                                        object:self
                                                      userInfo:@{
                                                          @"progress": @(progress),
                                                          @"step": step ?: @"",
                                                          @"active": @(active)
                                                      }];
}

- (void)notifyState {
    [[NSNotificationCenter defaultCenter] postNotificationName:PHLMusicStateDidChangeNotification
                                                        object:self];
}

@end
