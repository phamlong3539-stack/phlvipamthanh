#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef struct {
    BOOL avAudioInputHooked;
    BOOL audioUnitRenderHooked;
    BOOL audioQueueHooked;
    uint64_t avAudioTapCallbacks;
    uint64_t audioUnitRenderCallbacks;
    uint64_t audioQueueCallbacks;
} PHLAudioHookStats;

FOUNDATION_EXPORT PHLAudioHookStats PHLGetAudioHookStats(void);

@interface PHLOverlayUI : NSObject

+ (instancetype)sharedOverlay;

@property (nonatomic, assign) BOOL autoEdgeTuckEnabled;
@property (nonatomic, assign, readonly) BOOL isExpanded;

- (void)attachOverlayIfNeeded;
- (void)showPanel;
- (void)hidePanel;

@end

NS_ASSUME_NONNULL_END
