#import "PHLOverlayUI.h"
#import "PHLMusicManager.h"
#import "PHLSyncManager.h"
#import "PHLVoiceDSP.hpp"

#import <QuartzCore/QuartzCore.h>

@interface PHLPassthroughWindow : UIWindow
@property (nonatomic, weak) UIView *floatingPillView;
@property (nonatomic, weak) UIView *panelCardView;
@property (nonatomic, assign) BOOL panelExpanded;
@end

@implementation PHLPassthroughWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (self.panelExpanded && self.panelCardView && !self.panelCardView.hidden) {
        CGPoint inCard = [self convertPoint:point toView:self.panelCardView];
        if ([self.panelCardView pointInside:inCard withEvent:event]) {
            return hit;
        }
    }
    if (self.floatingPillView && !self.floatingPillView.hidden) {
        CGPoint inPill = [self convertPoint:point toView:self.floatingPillView];
        if ([self.floatingPillView pointInside:inPill withEvent:event]) {
            return hit;
        }
    }
    return nil;
}
@end

@interface PHLOverlayRootViewController : UIViewController
@end

@implementation PHLOverlayRootViewController
- (BOOL)prefersStatusBarHidden {
    return YES;
}
- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskAll;
}
@end

@interface PHLOverlayUI () <UITableViewDataSource, UITableViewDelegate>

@property (nonatomic, strong, nullable) PHLPassthroughWindow *overlayWindow;
@property (nonatomic, strong, nullable) UIView *floatingPill;
@property (nonatomic, strong, nullable) UIView *pillStatusDot;
@property (nonatomic, strong, nullable) UILabel *pillLabel;

@property (nonatomic, strong, nullable) UIView *panelCard;
@property (nonatomic, strong, nullable) UILabel *headerBadgeLabel;
@property (nonatomic, strong, nullable) UISegmentedControl *tabSegment;

// Smooth Anti-Freeze Progress Banner
@property (nonatomic, strong, nullable) UIView *progressBanner;
@property (nonatomic, strong, nullable) NSLayoutConstraint *progressHeightConstraint;
@property (nonatomic, strong, nullable) UILabel *progressStepLabel;
@property (nonatomic, strong, nullable) UIView *progressTrackView;
@property (nonatomic, strong, nullable) UIView *progressFillView;
@property (nonatomic, strong, nullable) NSLayoutConstraint *progressFillWidthConstraint;

// Tab Containers
@property (nonatomic, strong, nullable) UIView *voiceTabContainer;
@property (nonatomic, strong, nullable) UIView *musicTabContainer;
@property (nonatomic, strong, nullable) UIScrollView *systemTabContainer;

// Tab 1: Voice UI
@property (nonatomic, strong, nullable) UISwitch *voiceEnableSwitch;
@property (nonatomic, strong, nullable) UILabel *voiceStatusLabel;
@property (nonatomic, strong, nullable) UIProgressView *micMeterBar;
@property (nonatomic, strong, nullable) UILabel *voiceAlertBanner;
@property (nonatomic, strong, nullable) UITableView *voiceTableView;
@property (nonatomic, strong, nullable) UILabel *voiceDspFooterLabel;

// Tab 2: Music UI
@property (nonatomic, strong, nullable) UILabel *musicTitleLabel;
@property (nonatomic, strong, nullable) UILabel *musicArtistLabel;
@property (nonatomic, strong, nullable) UILabel *musicTimeLabel;
@property (nonatomic, strong, nullable) UIProgressView *musicSeekBar;
@property (nonatomic, strong, nullable) UIButton *musicPlayPauseButton;
@property (nonatomic, strong, nullable) UISlider *musicVolumeSlider;
@property (nonatomic, strong, nullable) UILabel *musicVolumeLabel;
@property (nonatomic, strong, nullable) UITableView *musicTableView;

// Tab 3: System UI
@property (nonatomic, strong, nullable) UIButton *syncNowButton;
@property (nonatomic, strong, nullable) UILabel *systemInfoLabel;
@property (nonatomic, strong, nullable) UISwitch *autoTuckSwitch;

@property (nonatomic, assign, readwrite) BOOL isExpanded;

@end

@implementation PHLOverlayUI {
    BOOL _attached;
    BOOL _pillSnappedRight;
    BOOL _pillTucked;
    NSTimer *_idleTuckTimer;
    NSTimer *_liveMeterTimer;
    CADisplayLink *_progressDisplayLink;
    double _targetProgress;
    double _displayedProgress;
    BOOL _progressActive;
    NSTimeInterval _progressHideTimestamp;
}

+ (instancetype)sharedOverlay {
    static PHLOverlayUI *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[PHLOverlayUI alloc] initPrivate];
    });
    return instance;
}

- (instancetype)initPrivate {
    self = [super init];
    if (self) {
        NSNumber *savedTuck = [[NSUserDefaults standardUserDefaults] objectForKey:@"PHL_AutoEdgeTuck"];
        _autoEdgeTuckEnabled = savedTuck ? [savedTuck boolValue] : YES;
        _pillSnappedRight = YES;

        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        [nc addObserver:self selector:@selector(handleSyncStateChanged) name:PHLSyncDidUpdateStateNotification object:nil];
        [nc addObserver:self selector:@selector(handleMusicStateChanged) name:PHLMusicStateDidChangeNotification object:nil];
        [nc addObserver:self selector:@selector(handleProgressNotification:) name:PHLSyncProgressNotification object:nil];
        [nc addObserver:self selector:@selector(handleProgressNotification:) name:PHLMusicDownloadProgressNotification object:nil];
        [nc addObserver:self selector:@selector(handleOrientationChanged) name:UIDeviceOrientationDidChangeNotification object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_idleTuckTimer invalidate];
    [_liveMeterTimer invalidate];
    [_progressDisplayLink invalidate];
}

#pragma mark - Window Setup

- (nullable UIWindowScene *)activeWindowScene {
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]] &&
                scene.activationState == UISceneActivationStateForegroundActive) {
                return (UIWindowScene *)scene;
            }
        }
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                return (UIWindowScene *)scene;
            }
        }
    }
    return nil;
}

- (void)attachOverlayIfNeeded {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_attached && self.overlayWindow) {
            self.overlayWindow.hidden = NO;
            return;
        }

        PHLPassthroughWindow *win = nil;
        if (@available(iOS 13.0, *)) {
            UIWindowScene *scene = [self activeWindowScene];
            if (!scene) return;
            win = [[PHLPassthroughWindow alloc] initWithWindowScene:scene];
        } else {
            win = [[PHLPassthroughWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        }

        win.windowLevel = UIWindowLevelAlert + 25.0;
        win.backgroundColor = [UIColor clearColor];
        win.opaque = NO;

        PHLOverlayRootViewController *rootVC = [[PHLOverlayRootViewController alloc] init];
        rootVC.view.backgroundColor = [UIColor clearColor];
        win.rootViewController = rootVC;
        win.hidden = NO;

        self.overlayWindow = win;
        [self buildFloatingPillInView:rootVC.view];
        [self buildPanelCardInView:rootVC.view];

        win.floatingPillView = self.floatingPill;
        win.panelCardView = self.panelCard;
        win.panelExpanded = NO;

        self->_attached = YES;
        [self refreshAllUI];
        [self scheduleIdleEdgeTuck];
    });
}

#pragma mark - Build Floating Pill

- (void)buildFloatingPillInView:(UIView *)parent {
    CGRect bounds = parent.bounds;
    CGFloat pillW = 98.0;
    CGFloat pillH = 34.0;
    CGFloat startX = MAX(12.0, bounds.size.width - pillW - 10.0);
    CGFloat startY = MAX(64.0, bounds.size.height * 0.30);

    UIView *pill = [[UIView alloc] initWithFrame:CGRectMake(startX, startY, pillW, pillH)];
    pill.backgroundColor = [[UIColor colorWithRed:0.06 green:0.09 blue:0.16 alpha:0.90] colorWithAlphaComponent:0.92];
    pill.layer.cornerRadius = pillH * 0.5;
    pill.layer.borderWidth = 1.0;
    pill.layer.borderColor = [UIColor colorWithRed:0.22 green:0.74 blue:0.97 alpha:0.65].CGColor;
    pill.layer.shadowColor = [UIColor blackColor].CGColor;
    pill.layer.shadowOpacity = 0.45;
    pill.layer.shadowRadius = 6.0;
    pill.layer.shadowOffset = CGSizeMake(0, 3);

    UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(11, 12, 10, 10)];
    dot.layer.cornerRadius = 5.0;
    dot.backgroundColor = [UIColor systemGrayColor];
    [pill addSubview:dot];

    UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(26, 0, pillW - 32, pillH)];
    lbl.text = @"PHL MIC";
    lbl.textColor = [UIColor whiteColor];
    lbl.font = [UIFont systemFontOfSize:11.5 weight:UIFontWeightBold];
    lbl.textAlignment = NSTextAlignmentLeft;
    [pill addSubview:lbl];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handlePillTapped)];
    [pill addGestureRecognizer:tap];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePillPanned:)];
    [pill addGestureRecognizer:pan];

    [parent addSubview:pill];
    self.floatingPill = pill;
    self.pillStatusDot = dot;
    self.pillLabel = lbl;
}

- (void)handlePillTapped {
    if (_pillTucked) {
        [self wakePillAnimated];
        return;
    }
    if (self.isExpanded) {
        [self hidePanel];
    } else {
        [self showPanel];
    }
}

- (void)handlePillPanned:(UIPanGestureRecognizer *)pan {
    if (!self.floatingPill || !self.overlayWindow) return;
    [self wakePillAnimated];

    UIView *parent = self.overlayWindow.rootViewController.view;
    CGPoint translation = [pan translationInView:parent];
    CGPoint center = self.floatingPill.center;
    center.x += translation.x;
    center.y += translation.y;
    [pan setTranslation:CGPointZero inView:parent];

    UIEdgeInsets safe = UIEdgeInsetsZero;
    if (@available(iOS 11.0, *)) safe = parent.safeAreaInsets;

    CGFloat halfW = self.floatingPill.bounds.size.width * 0.5;
    CGFloat halfH = self.floatingPill.bounds.size.height * 0.5;
    center.x = MAX(safe.left + halfW + 4, MIN(parent.bounds.size.width - safe.right - halfW - 4, center.x));
    center.y = MAX(safe.top + halfH + 8, MIN(parent.bounds.size.height - safe.bottom - halfH - 8, center.y));
    self.floatingPill.center = center;

    if (pan.state == UIGestureRecognizerStateEnded || pan.state == UIGestureRecognizerStateCancelled) {
        [self snapPillToNearestEdge];
    }
}

- (void)snapPillToNearestEdge {
    if (!self.floatingPill || !self.overlayWindow) return;
    UIView *parent = self.overlayWindow.rootViewController.view;
    UIEdgeInsets safe = UIEdgeInsetsZero;
    if (@available(iOS 11.0, *)) safe = parent.safeAreaInsets;

    CGFloat w = parent.bounds.size.width;
    CGFloat pillW = self.floatingPill.bounds.size.width;
    _pillSnappedRight = (self.floatingPill.center.x >= w * 0.5);
    CGFloat targetCenterX = _pillSnappedRight
        ? (w - safe.right - pillW * 0.5 - 6.0)
        : (safe.left + pillW * 0.5 + 6.0);

    [UIView animateWithDuration:0.30
                          delay:0
         usingSpringWithDamping:0.78
          initialSpringVelocity:0.6
                        options:UIViewAnimationOptionAllowUserInteraction
                     animations:^{
        self.floatingPill.center = CGPointMake(targetCenterX, self.floatingPill.center.y);
    } completion:^(BOOL finished) {
        [self scheduleIdleEdgeTuck];
    }];
}

- (void)scheduleIdleEdgeTuck {
    [_idleTuckTimer invalidate];
    _idleTuckTimer = nil;
    if (!self.autoEdgeTuckEnabled || self.isExpanded) return;

    __weak typeof(self) weakSelf = self;
    _idleTuckTimer = [NSTimer scheduledTimerWithTimeInterval:3.6 repeats:NO block:^(NSTimer *timer) {
        [weakSelf performEdgeTuck];
    }];
}

- (void)performEdgeTuck {
    if (!self.autoEdgeTuckEnabled || self.isExpanded || !self.floatingPill || !self.overlayWindow) return;
    UIView *parent = self.overlayWindow.rootViewController.view;
    CGFloat w = parent.bounds.size.width;
    CGFloat pillW = self.floatingPill.bounds.size.width;
    CGFloat tuckedCenterX = _pillSnappedRight ? (w - pillW * 0.18) : (pillW * 0.18);

    _pillTucked = YES;
    [UIView animateWithDuration:0.35 animations:^{
        self.floatingPill.alpha = 0.45;
        self.floatingPill.center = CGPointMake(tuckedCenterX, self.floatingPill.center.y);
    }];
}

- (void)wakePillAnimated {
    [_idleTuckTimer invalidate];
    _pillTucked = NO;
    if (!self.floatingPill || !self.overlayWindow) return;

    UIView *parent = self.overlayWindow.rootViewController.view;
    UIEdgeInsets safe = UIEdgeInsetsZero;
    if (@available(iOS 11.0, *)) safe = parent.safeAreaInsets;
    CGFloat w = parent.bounds.size.width;
    CGFloat pillW = self.floatingPill.bounds.size.width;
    CGFloat wakeCenterX = _pillSnappedRight
        ? (w - safe.right - pillW * 0.5 - 6.0)
        : (safe.left + pillW * 0.5 + 6.0);

    [UIView animateWithDuration:0.22 animations:^{
        self.floatingPill.alpha = 1.0;
        self.floatingPill.center = CGPointMake(wakeCenterX, self.floatingPill.center.y);
    } completion:^(BOOL finished) {
        [self scheduleIdleEdgeTuck];
    }];
}

- (void)handleOrientationChanged {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self updatePanelDimensions];
        [self snapPillToNearestEdge];
    });
}

#pragma mark - Build Floating Menu Panel

- (void)buildPanelCardInView:(UIView *)parent {
    UIView *card = [[UIView alloc] init];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.backgroundColor = [UIColor colorWithRed:0.05 green:0.08 blue:0.14 alpha:0.95];
    card.layer.cornerRadius = 18.0;
    card.layer.borderWidth = 1.0;
    card.layer.borderColor = [UIColor colorWithRed:0.22 green:0.74 blue:0.97 alpha:0.40].CGColor;
    card.layer.shadowColor = [UIColor blackColor].CGColor;
    card.layer.shadowOpacity = 0.55;
    card.layer.shadowRadius = 18.0;
    card.layer.shadowOffset = CGSizeMake(0, 8);
    card.clipsToBounds = YES;
    card.hidden = YES;
    card.alpha = 0.0;
    [parent addSubview:card];
    self.panelCard = card;

    [NSLayoutConstraint activateConstraints:@[
        [card.centerXAnchor constraintEqualToAnchor:parent.centerXAnchor],
        [card.centerYAnchor constraintEqualToAnchor:parent.centerYAnchor]
    ]];
    [self updatePanelDimensions];

    // Header bar
    UIView *header = [[UIView alloc] init];
    header.translatesAutoresizingMaskIntoConstraints = NO;
    header.backgroundColor = [UIColor colorWithRed:0.09 green:0.14 blue:0.23 alpha:1.0];
    [card addSubview:header];

    UILabel *titleLbl = [[UILabel alloc] init];
    titleLbl.translatesAutoresizingMaskIntoConstraints = NO;
    titleLbl.text = @"PHL Voice & Music";
    titleLbl.textColor = [UIColor whiteColor];
    titleLbl.font = [UIFont systemFontOfSize:15 weight:UIFontWeightBold];
    [header addSubview:titleLbl];

    UILabel *badge = [[UILabel alloc] init];
    badge.translatesAutoresizingMaskIntoConstraints = NO;
    badge.text = @" v0 ";
    badge.textColor = [UIColor colorWithRed:0.22 green:0.74 blue:0.97 alpha:1.0];
    badge.backgroundColor = [UIColor colorWithRed:0.12 green:0.23 blue:0.36 alpha:1.0];
    badge.font = [UIFont monospacedDigitSystemFontOfSize:10.5 weight:UIFontWeightSemibold];
    badge.layer.cornerRadius = 6.0;
    badge.clipsToBounds = YES;
    [header addSubview:badge];
    self.headerBadgeLabel = badge;

    UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    closeBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [closeBtn setTitle:@"Thu gọn" forState:UIControlStateNormal];
    [closeBtn setTitleColor:[UIColor colorWithRed:0.80 green:0.86 blue:0.94 alpha:1.0] forState:UIControlStateNormal];
    closeBtn.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    closeBtn.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.08];
    closeBtn.layer.cornerRadius = 8.0;
    closeBtn.contentEdgeInsets = UIEdgeInsetsMake(4, 10, 4, 10);
    [closeBtn addTarget:self action:@selector(hidePanel) forControlEvents:UIControlEventTouchUpInside];
    [header addSubview:closeBtn];

    // Progress Banner (Anti-Freeze UX)
    UIView *pBanner = [[UIView alloc] init];
    pBanner.translatesAutoresizingMaskIntoConstraints = NO;
    pBanner.backgroundColor = [UIColor colorWithRed:0.07 green:0.18 blue:0.30 alpha:0.95];
    pBanner.clipsToBounds = YES;
    [card addSubview:pBanner];
    self.progressBanner = pBanner;

    UILabel *pLabel = [[UILabel alloc] init];
    pLabel.translatesAutoresizingMaskIntoConstraints = NO;
    pLabel.text = @"Đang kết nối GitHub...";
    pLabel.textColor = [UIColor colorWithRed:0.75 green:0.92 blue:1.0 alpha:1.0];
    pLabel.font = [UIFont systemFontOfSize:11.5 weight:UIFontWeightMedium];
    [pBanner addSubview:pLabel];
    self.progressStepLabel = pLabel;

    UIView *pTrack = [[UIView alloc] init];
    pTrack.translatesAutoresizingMaskIntoConstraints = NO;
    pTrack.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.12];
    pTrack.layer.cornerRadius = 2.5;
    pTrack.clipsToBounds = YES;
    [pBanner addSubview:pTrack];
    self.progressTrackView = pTrack;

    UIView *pFill = [[UIView alloc] init];
    pFill.translatesAutoresizingMaskIntoConstraints = NO;
    pFill.backgroundColor = [UIColor colorWithRed:0.22 green:0.74 blue:0.97 alpha:1.0];
    pFill.layer.cornerRadius = 2.5;
    [pTrack addSubview:pFill];
    self.progressFillView = pFill;

    self.progressHeightConstraint = [pBanner.heightAnchor constraintEqualToConstant:0.0];
    self.progressFillWidthConstraint = [pFill.widthAnchor constraintEqualToConstant:0.0];

    [NSLayoutConstraint activateConstraints:@[
        [pLabel.topAnchor constraintEqualToAnchor:pBanner.topAnchor constant:6.0],
        [pLabel.leadingAnchor constraintEqualToAnchor:pBanner.leadingAnchor constant:12.0],
        [pLabel.trailingAnchor constraintEqualToAnchor:pBanner.trailingAnchor constant:-12.0],
        [pTrack.topAnchor constraintEqualToAnchor:pLabel.bottomAnchor constant:5.0],
        [pTrack.leadingAnchor constraintEqualToAnchor:pBanner.leadingAnchor constant:12.0],
        [pTrack.trailingAnchor constraintEqualToAnchor:pBanner.trailingAnchor constant:-12.0],
        [pTrack.heightAnchor constraintEqualToConstant:5.0],
        [pFill.topAnchor constraintEqualToAnchor:pTrack.topAnchor],
        [pFill.bottomAnchor constraintEqualToAnchor:pTrack.bottomAnchor],
        [pFill.leadingAnchor constraintEqualToAnchor:pTrack.leadingAnchor],
        self.progressFillWidthConstraint
    ]];

    // Segmented Tabs
    UISegmentedControl *seg = [[UISegmentedControl alloc] initWithItems:@[@"Đổi Giọng", @"Nhạc", @"Hệ Thống"]];
    seg.translatesAutoresizingMaskIntoConstraints = NO;
    seg.selectedSegmentIndex = 0;
    if (@available(iOS 13.0, *)) {
        seg.selectedSegmentTintColor = [UIColor colorWithRed:0.15 green:0.45 blue:0.85 alpha:1.0];
        seg.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.08];
    }
    [seg setTitleTextAttributes:@{NSForegroundColorAttributeName: [UIColor colorWithWhite:0.78 alpha:1.0], NSFontAttributeName: [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold]} forState:UIControlStateNormal];
    [seg setTitleTextAttributes:@{NSForegroundColorAttributeName: [UIColor whiteColor], NSFontAttributeName: [UIFont systemFontOfSize:12 weight:UIFontWeightBold]} forState:UIControlStateSelected];
    [seg addTarget:self action:@selector(handleTabChanged:) forControlEvents:UIControlEventValueChanged];
    [card addSubview:seg];
    self.tabSegment = seg;

    // Content Area
    UIView *contentHolder = [[UIView alloc] init];
    contentHolder.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:contentHolder];

    [NSLayoutConstraint activateConstraints:@[
        [header.topAnchor constraintEqualToAnchor:card.topAnchor],
        [header.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
        [header.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
        [header.heightAnchor constraintEqualToConstant:44.0],

        [titleLbl.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:14.0],
        [titleLbl.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
        [badge.leadingAnchor constraintEqualToAnchor:titleLbl.trailingAnchor constant:8.0],
        [badge.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
        [closeBtn.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-10.0],
        [closeBtn.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],

        [pBanner.topAnchor constraintEqualToAnchor:header.bottomAnchor],
        [pBanner.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
        [pBanner.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
        self.progressHeightConstraint,

        [seg.topAnchor constraintEqualToAnchor:pBanner.bottomAnchor constant:8.0],
        [seg.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:12.0],
        [seg.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-12.0],
        [seg.heightAnchor constraintEqualToConstant:30.0],

        [contentHolder.topAnchor constraintEqualToAnchor:seg.bottomAnchor constant:8.0],
        [contentHolder.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
        [contentHolder.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
        [contentHolder.bottomAnchor constraintEqualToAnchor:card.bottomAnchor]
    ]];

    [self buildVoiceTabInContainer:contentHolder];
    [self buildMusicTabInContainer:contentHolder];
    [self buildSystemTabInContainer:contentHolder];
    [self switchToTabIndex:0];
}

- (void)updatePanelDimensions {
    if (!self.panelCard || !self.overlayWindow) return;
    CGSize screen = self.overlayWindow.bounds.size;
    CGFloat w = MIN(356.0, MAX(280.0, screen.width - 28.0));
    CGFloat h = MIN(452.0, MAX(270.0, screen.height - 44.0));
    for (NSLayoutConstraint *c in self.panelCard.constraints) {
        if (c.firstAttribute == NSLayoutAttributeWidth || c.firstAttribute == NSLayoutAttributeHeight) {
            c.active = NO;
        }
    }
    [NSLayoutConstraint activateConstraints:@[
        [self.panelCard.widthAnchor constraintEqualToConstant:w],
        [self.panelCard.heightAnchor constraintEqualToConstant:h]
    ]];
}

#pragma mark - Tab 1: Voice UI

- (void)buildVoiceTabInContainer:(UIView *)holder {
    UIView *container = [[UIView alloc] init];
    container.translatesAutoresizingMaskIntoConstraints = NO;
    [holder addSubview:container];
    self.voiceTabContainer = container;
    [self pinFull:container to:holder];

    UIView *masterBox = [[UIView alloc] init];
    masterBox.translatesAutoresizingMaskIntoConstraints = NO;
    masterBox.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.06];
    masterBox.layer.cornerRadius = 12.0;
    [container addSubview:masterBox];

    UILabel *swLabel = [[UILabel alloc] init];
    swLabel.translatesAutoresizingMaskIntoConstraints = NO;
    swLabel.text = @"Bật Đổi Giọng Micro";
    swLabel.textColor = [UIColor whiteColor];
    swLabel.font = [UIFont systemFontOfSize:13.5 weight:UIFontWeightSemibold];
    [masterBox addSubview:swLabel];

    UILabel *statusSub = [[UILabel alloc] init];
    statusSub.translatesAutoresizingMaskIntoConstraints = NO;
    statusSub.text = @"Giọng gốc (Passthrough)";
    statusSub.textColor = [UIColor colorWithRed:0.65 green:0.75 blue:0.88 alpha:1.0];
    statusSub.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightRegular];
    [masterBox addSubview:statusSub];
    self.voiceStatusLabel = statusSub;

    UISwitch *sw = [[UISwitch alloc] init];
    sw.translatesAutoresizingMaskIntoConstraints = NO;
    sw.onTintColor = [UIColor colorWithRed:0.13 green:0.77 blue:0.37 alpha:1.0];
    [sw addTarget:self action:@selector(handleVoiceEnableToggled:) forControlEvents:UIControlEventValueChanged];
    [masterBox addSubview:sw];
    self.voiceEnableSwitch = sw;

    UIProgressView *meter = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    meter.translatesAutoresizingMaskIntoConstraints = NO;
    meter.trackTintColor = [UIColor colorWithWhite:1.0 alpha:0.12];
    meter.progressTintColor = [UIColor colorWithRed:0.13 green:0.77 blue:0.37 alpha:1.0];
    [masterBox addSubview:meter];
    self.micMeterBar = meter;

    UILabel *alertLbl = [[UILabel alloc] init];
    alertLbl.translatesAutoresizingMaskIntoConstraints = NO;
    alertLbl.numberOfLines = 2;
    alertLbl.textColor = [UIColor colorWithRed:1.0 green:0.75 blue:0.75 alpha:1.0];
    alertLbl.backgroundColor = [UIColor colorWithRed:0.55 green:0.10 blue:0.15 alpha:0.45];
    alertLbl.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightMedium];
    alertLbl.textAlignment = NSTextAlignmentCenter;
    alertLbl.layer.cornerRadius = 8.0;
    alertLbl.clipsToBounds = YES;
    alertLbl.hidden = YES;
    [container addSubview:alertLbl];
    self.voiceAlertBanner = alertLbl;

    UITableView *tv = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    tv.translatesAutoresizingMaskIntoConstraints = NO;
    tv.backgroundColor = [UIColor clearColor];
    tv.separatorStyle = UITableViewCellSeparatorStyleNone;
    tv.dataSource = self;
    tv.delegate = self;
    [container addSubview:tv];
    self.voiceTableView = tv;

    UILabel *footer = [[UILabel alloc] init];
    footer.translatesAutoresizingMaskIntoConstraints = NO;
    footer.text = @"DSP: Chưa chọn giọng";
    footer.textColor = [UIColor colorWithRed:0.60 green:0.70 blue:0.82 alpha:1.0];
    footer.font = [UIFont monospacedDigitSystemFontOfSize:10.5 weight:UIFontWeightMedium];
    footer.textAlignment = NSTextAlignmentCenter;
    [container addSubview:footer];
    self.voiceDspFooterLabel = footer;

    [NSLayoutConstraint activateConstraints:@[
        [masterBox.topAnchor constraintEqualToAnchor:container.topAnchor],
        [masterBox.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:12.0],
        [masterBox.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-12.0],

        [swLabel.topAnchor constraintEqualToAnchor:masterBox.topAnchor constant:10.0],
        [swLabel.leadingAnchor constraintEqualToAnchor:masterBox.leadingAnchor constant:12.0],
        [statusSub.topAnchor constraintEqualToAnchor:swLabel.bottomAnchor constant:2.0],
        [statusSub.leadingAnchor constraintEqualToAnchor:swLabel.leadingAnchor],
        [statusSub.trailingAnchor constraintEqualToAnchor:sw.leadingAnchor constant:-8.0],
        [sw.trailingAnchor constraintEqualToAnchor:masterBox.trailingAnchor constant:-12.0],
        [sw.centerYAnchor constraintEqualToAnchor:masterBox.centerYAnchor constant:-6.0],

        [meter.topAnchor constraintEqualToAnchor:statusSub.bottomAnchor constant:8.0],
        [meter.leadingAnchor constraintEqualToAnchor:masterBox.leadingAnchor constant:12.0],
        [meter.trailingAnchor constraintEqualToAnchor:masterBox.trailingAnchor constant:-12.0],
        [meter.bottomAnchor constraintEqualToAnchor:masterBox.bottomAnchor constant:-8.0],

        [alertLbl.topAnchor constraintEqualToAnchor:masterBox.bottomAnchor constant:6.0],
        [alertLbl.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:12.0],
        [alertLbl.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-12.0],

        [tv.topAnchor constraintEqualToAnchor:alertLbl.bottomAnchor constant:6.0],
        [tv.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:8.0],
        [tv.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-8.0],

        [footer.topAnchor constraintEqualToAnchor:tv.bottomAnchor constant:4.0],
        [footer.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:12.0],
        [footer.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-12.0],
        [footer.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-8.0]
    ]];
}

#pragma mark - Tab 2: Music UI (Completely Separate)

- (void)buildMusicTabInContainer:(UIView *)holder {
    UIView *container = [[UIView alloc] init];
    container.translatesAutoresizingMaskIntoConstraints = NO;
    [holder addSubview:container];
    self.musicTabContainer = container;
    [self pinFull:container to:holder];

    UIView *playerCard = [[UIView alloc] init];
    playerCard.translatesAutoresizingMaskIntoConstraints = NO;
    playerCard.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.06];
    playerCard.layer.cornerRadius = 12.0;
    [container addSubview:playerCard];

    UILabel *titleLbl = [[UILabel alloc] init];
    titleLbl.translatesAutoresizingMaskIntoConstraints = NO;
    titleLbl.text = @"Chưa phát bài nhạc nào";
    titleLbl.textColor = [UIColor whiteColor];
    titleLbl.font = [UIFont systemFontOfSize:13.5 weight:UIFontWeightBold];
    [playerCard addSubview:titleLbl];
    self.musicTitleLabel = titleLbl;

    UILabel *artistLbl = [[UILabel alloc] init];
    artistLbl.translatesAutoresizingMaskIntoConstraints = NO;
    artistLbl.text = @"Kho nhạc: phl-music-data (Tách biệt micro)";
    artistLbl.textColor = [UIColor colorWithRed:0.65 green:0.75 blue:0.88 alpha:1.0];
    artistLbl.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightRegular];
    [playerCard addSubview:artistLbl];
    self.musicArtistLabel = artistLbl;

    UILabel *timeLbl = [[UILabel alloc] init];
    timeLbl.translatesAutoresizingMaskIntoConstraints = NO;
    timeLbl.text = @"00:00 / 00:00";
    timeLbl.textColor = [UIColor colorWithWhite:0.78 alpha:1.0];
    timeLbl.font = [UIFont monospacedDigitSystemFontOfSize:10.5 weight:UIFontWeightMedium];
    timeLbl.textAlignment = NSTextAlignmentRight;
    [playerCard addSubview:timeLbl];
    self.musicTimeLabel = timeLbl;

    UIProgressView *seek = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    seek.translatesAutoresizingMaskIntoConstraints = NO;
    seek.trackTintColor = [UIColor colorWithWhite:1.0 alpha:0.14];
    seek.progressTintColor = [UIColor colorWithRed:0.22 green:0.74 blue:0.97 alpha:1.0];
    [playerCard addSubview:seek];
    self.musicSeekBar = seek;

    UIButton *prevBtn = [self makeControlButton:@"|<" action:@selector(handleMusicPrev)];
    UIButton *playBtn = [self makeControlButton:@"Phát" action:@selector(handleMusicPlayPause)];
    playBtn.backgroundColor = [UIColor colorWithRed:0.15 green:0.45 blue:0.85 alpha:1.0];
    self.musicPlayPauseButton = playBtn;
    UIButton *stopBtn = [self makeControlButton:@"Dừng" action:@selector(handleMusicStop)];
    UIButton *nextBtn = [self makeControlButton:@">|" action:@selector(handleMusicNext)];

    UIStackView *ctrlRow = [[UIStackView alloc] initWithArrangedSubviews:@[prevBtn, playBtn, stopBtn, nextBtn]];
    ctrlRow.translatesAutoresizingMaskIntoConstraints = NO;
    ctrlRow.axis = UILayoutConstraintAxisHorizontal;
    ctrlRow.spacing = 8.0;
    ctrlRow.distribution = UIStackViewDistributionFillEqually;
    [playerCard addSubview:ctrlRow];

    UILabel *volTitle = [[UILabel alloc] init];
    volTitle.translatesAutoresizingMaskIntoConstraints = NO;
    volTitle.text = @"Âm lượng";
    volTitle.textColor = [UIColor colorWithWhite:0.82 alpha:1.0];
    volTitle.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightMedium];
    [playerCard addSubview:volTitle];

    UISlider *volSlider = [[UISlider alloc] init];
    volSlider.translatesAutoresizingMaskIntoConstraints = NO;
    volSlider.minimumValue = 0.0f;
    volSlider.maximumValue = 1.0f;
    volSlider.value = [PHLMusicManager sharedManager].volume;
    volSlider.minimumTrackTintColor = [UIColor colorWithRed:0.22 green:0.74 blue:0.97 alpha:1.0];
    [volSlider addTarget:self action:@selector(handleMusicVolumeChanged:) forControlEvents:UIControlEventValueChanged];
    [playerCard addSubview:volSlider];
    self.musicVolumeSlider = volSlider;

    UILabel *volVal = [[UILabel alloc] init];
    volVal.translatesAutoresizingMaskIntoConstraints = NO;
    volVal.text = [NSString stringWithFormat:@"%d%%", (int)roundf(volSlider.value * 100.0f)];
    volVal.textColor = [UIColor whiteColor];
    volVal.font = [UIFont monospacedDigitSystemFontOfSize:11.0 weight:UIFontWeightSemibold];
    volVal.textAlignment = NSTextAlignmentRight;
    [playerCard addSubview:volVal];
    self.musicVolumeLabel = volVal;

    UITableView *tv = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    tv.translatesAutoresizingMaskIntoConstraints = NO;
    tv.backgroundColor = [UIColor clearColor];
    tv.separatorStyle = UITableViewCellSeparatorStyleNone;
    tv.dataSource = self;
    tv.delegate = self;
    [container addSubview:tv];
    self.musicTableView = tv;

    [NSLayoutConstraint activateConstraints:@[
        [playerCard.topAnchor constraintEqualToAnchor:container.topAnchor],
        [playerCard.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:12.0],
        [playerCard.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-12.0],

        [titleLbl.topAnchor constraintEqualToAnchor:playerCard.topAnchor constant:10.0],
        [titleLbl.leadingAnchor constraintEqualToAnchor:playerCard.leadingAnchor constant:12.0],
        [titleLbl.trailingAnchor constraintEqualToAnchor:timeLbl.leadingAnchor constant:-6.0],

        [timeLbl.centerYAnchor constraintEqualToAnchor:titleLbl.centerYAnchor],
        [timeLbl.trailingAnchor constraintEqualToAnchor:playerCard.trailingAnchor constant:-12.0],
        [timeLbl.widthAnchor constraintGreaterThanOrEqualToConstant:72.0],

        [artistLbl.topAnchor constraintEqualToAnchor:titleLbl.bottomAnchor constant:2.0],
        [artistLbl.leadingAnchor constraintEqualToAnchor:titleLbl.leadingAnchor],
        [artistLbl.trailingAnchor constraintEqualToAnchor:playerCard.trailingAnchor constant:-12.0],

        [seek.topAnchor constraintEqualToAnchor:artistLbl.bottomAnchor constant:8.0],
        [seek.leadingAnchor constraintEqualToAnchor:playerCard.leadingAnchor constant:12.0],
        [seek.trailingAnchor constraintEqualToAnchor:playerCard.trailingAnchor constant:-12.0],

        [ctrlRow.topAnchor constraintEqualToAnchor:seek.bottomAnchor constant:8.0],
        [ctrlRow.leadingAnchor constraintEqualToAnchor:playerCard.leadingAnchor constant:12.0],
        [ctrlRow.trailingAnchor constraintEqualToAnchor:playerCard.trailingAnchor constant:-12.0],
        [ctrlRow.heightAnchor constraintEqualToConstant:30.0],

        [volTitle.topAnchor constraintEqualToAnchor:ctrlRow.bottomAnchor constant:8.0],
        [volTitle.leadingAnchor constraintEqualToAnchor:playerCard.leadingAnchor constant:12.0],
        [volSlider.centerYAnchor constraintEqualToAnchor:volTitle.centerYAnchor],
        [volSlider.leadingAnchor constraintEqualToAnchor:volTitle.trailingAnchor constant:8.0],
        [volVal.centerYAnchor constraintEqualToAnchor:volTitle.centerYAnchor],
        [volVal.leadingAnchor constraintEqualToAnchor:volSlider.trailingAnchor constant:8.0],
        [volVal.trailingAnchor constraintEqualToAnchor:playerCard.trailingAnchor constant:-12.0],
        [volVal.widthAnchor constraintEqualToConstant:38.0],
        [volTitle.bottomAnchor constraintEqualToAnchor:playerCard.bottomAnchor constant:-10.0],

        [tv.topAnchor constraintEqualToAnchor:playerCard.bottomAnchor constant:8.0],
        [tv.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:8.0],
        [tv.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-8.0],
        [tv.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-8.0]
    ]];
}

- (UIButton *)makeControlButton:(NSString *)title action:(SEL)sel {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightSemibold];
    b.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.10];
    b.layer.cornerRadius = 8.0;
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    return b;
}

#pragma mark - Tab 3: System & Sync UI

- (void)buildSystemTabInContainer:(UIView *)holder {
    UIScrollView *scroll = [[UIScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [holder addSubview:scroll];
    self.systemTabContainer = scroll;
    [self pinFull:scroll to:holder];

    UIView *content = [[UIView alloc] init];
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:content];

    UIButton *syncBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    syncBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [syncBtn setTitle:@"Đồng bộ ngay từ GitHub" forState:UIControlStateNormal];
    [syncBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    syncBtn.titleLabel.font = [UIFont systemFontOfSize:13.5 weight:UIFontWeightBold];
    syncBtn.backgroundColor = [UIColor colorWithRed:0.15 green:0.45 blue:0.88 alpha:1.0];
    syncBtn.layer.cornerRadius = 10.0;
    [syncBtn addTarget:self action:@selector(handleSyncNowTapped) forControlEvents:UIControlEventTouchUpInside];
    [content addSubview:syncBtn];
    self.syncNowButton = syncBtn;

    UIView *tuckBox = [[UIView alloc] init];
    tuckBox.translatesAutoresizingMaskIntoConstraints = NO;
    tuckBox.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.06];
    tuckBox.layer.cornerRadius = 10.0;
    [content addSubview:tuckBox];

    UILabel *tuckLbl = [[UILabel alloc] init];
    tuckLbl.translatesAutoresizingMaskIntoConstraints = NO;
    tuckLbl.text = @"Tự thu gọn sát mép màn hình";
    tuckLbl.textColor = [UIColor whiteColor];
    tuckLbl.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightMedium];
    [tuckBox addSubview:tuckLbl];

    UISwitch *tuckSw = [[UISwitch alloc] init];
    tuckSw.translatesAutoresizingMaskIntoConstraints = NO;
    tuckSw.on = self.autoEdgeTuckEnabled;
    [tuckSw addTarget:self action:@selector(handleAutoTuckToggled:) forControlEvents:UIControlEventValueChanged];
    [tuckBox addSubview:tuckSw];
    self.autoTuckSwitch = tuckSw;

    UIView *infoCard = [[UIView alloc] init];
    infoCard.translatesAutoresizingMaskIntoConstraints = NO;
    infoCard.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.05];
    infoCard.layer.cornerRadius = 10.0;
    [content addSubview:infoCard];

    UILabel *infoLbl = [[UILabel alloc] init];
    infoLbl.translatesAutoresizingMaskIntoConstraints = NO;
    infoLbl.numberOfLines = 0;
    infoLbl.textColor = [UIColor colorWithRed:0.84 green:0.90 blue:0.96 alpha:1.0];
    infoLbl.font = [UIFont monospacedSystemFontOfSize:11.0 weight:UIFontWeightRegular];
    [infoCard addSubview:infoLbl];
    self.systemInfoLabel = infoLbl;

    [NSLayoutConstraint activateConstraints:@[
        [content.topAnchor constraintEqualToAnchor:scroll.topAnchor],
        [content.leadingAnchor constraintEqualToAnchor:scroll.leadingAnchor],
        [content.trailingAnchor constraintEqualToAnchor:scroll.trailingAnchor],
        [content.bottomAnchor constraintEqualToAnchor:scroll.bottomAnchor],
        [content.widthAnchor constraintEqualToAnchor:scroll.widthAnchor],

        [syncBtn.topAnchor constraintEqualToAnchor:content.topAnchor constant:2.0],
        [syncBtn.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:12.0],
        [syncBtn.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-12.0],
        [syncBtn.heightAnchor constraintEqualToConstant:38.0],

        [tuckBox.topAnchor constraintEqualToAnchor:syncBtn.bottomAnchor constant:8.0],
        [tuckBox.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:12.0],
        [tuckBox.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-12.0],
        [tuckBox.heightAnchor constraintEqualToConstant:44.0],

        [tuckLbl.leadingAnchor constraintEqualToAnchor:tuckBox.leadingAnchor constant:12.0],
        [tuckLbl.centerYAnchor constraintEqualToAnchor:tuckBox.centerYAnchor],
        [tuckSw.trailingAnchor constraintEqualToAnchor:tuckBox.trailingAnchor constant:-12.0],
        [tuckSw.centerYAnchor constraintEqualToAnchor:tuckBox.centerYAnchor],

        [infoCard.topAnchor constraintEqualToAnchor:tuckBox.bottomAnchor constant:8.0],
        [infoCard.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:12.0],
        [infoCard.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-12.0],
        [infoCard.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-12.0],

        [infoLbl.topAnchor constraintEqualToAnchor:infoCard.topAnchor constant:10.0],
        [infoLbl.leadingAnchor constraintEqualToAnchor:infoCard.leadingAnchor constant:10.0],
        [infoLbl.trailingAnchor constraintEqualToAnchor:infoCard.trailingAnchor constant:-10.0],
        [infoLbl.bottomAnchor constraintEqualToAnchor:infoCard.bottomAnchor constant:-10.0]
    ]];
}

- (void)pinFull:(UIView *)child to:(UIView *)parent {
    [NSLayoutConstraint activateConstraints:@[
        [child.topAnchor constraintEqualToAnchor:parent.topAnchor],
        [child.leadingAnchor constraintEqualToAnchor:parent.leadingAnchor],
        [child.trailingAnchor constraintEqualToAnchor:parent.trailingAnchor],
        [child.bottomAnchor constraintEqualToAnchor:parent.bottomAnchor]
    ]];
}

#pragma mark - Show / Hide Panel & Timers

- (void)showPanel {
    [self wakePillAnimated];
    self.isExpanded = YES;
    self.overlayWindow.panelExpanded = YES;
    self.panelCard.hidden = NO;
    [self refreshAllUI];

    [UIView animateWithDuration:0.22 animations:^{
        self.panelCard.alpha = 1.0;
    }];

    [_liveMeterTimer invalidate];
    __weak typeof(self) weakSelf = self;
    _liveMeterTimer = [NSTimer scheduledTimerWithTimeInterval:0.12 repeats:YES block:^(NSTimer *timer) {
        [weakSelf updateLiveTelemetryUI];
    }];
}

- (void)hidePanel {
    self.isExpanded = NO;
    self.overlayWindow.panelExpanded = NO;
    [_liveMeterTimer invalidate];
    _liveMeterTimer = nil;

    [UIView animateWithDuration:0.18 animations:^{
        self.panelCard.alpha = 0.0;
    } completion:^(BOOL finished) {
        self.panelCard.hidden = YES;
        [self scheduleIdleEdgeTuck];
    }];
}

#pragma mark - Smooth Animated Progress Bar (Anti-Freeze UX)

- (void)handleProgressNotification:(NSNotification *)note {
    NSDictionary *info = note.userInfo;
    double prog = [info[@"progress"] doubleValue];
    NSString *step = info[@"step"] ?: @"";
    BOOL active = [info[@"active"] boolValue];

    dispatch_async(dispatch_get_main_queue(), ^{
        self->_targetProgress = MAX(0.03, MIN(1.0, prog));
        self->_progressActive = active;
        self.progressStepLabel.text = step;

        if (!active && prog >= 0.99) {
            self->_progressHideTimestamp = CACurrentMediaTime() + 1.1;
        } else {
            self->_progressHideTimestamp = 0.0;
        }

        if (self.progressHeightConstraint.constant < 1.0) {
            self.progressHeightConstraint.constant = 40.0;
            [UIView animateWithDuration:0.20 animations:^{
                [self.panelCard layoutIfNeeded];
            }];
        }

        [self ensureProgressDisplayLinkRunning];
        [self updatePillIndicator];
    });
}

- (void)ensureProgressDisplayLinkRunning {
    if (_progressDisplayLink) return;
    _progressDisplayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(tickProgressAnimation)];
    [_progressDisplayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

- (void)tickProgressAnimation {
    _displayedProgress += (_targetProgress - _displayedProgress) * 0.22;
    if (fabs(_targetProgress - _displayedProgress) < 0.004) {
        _displayedProgress = _targetProgress;
    }

    CGFloat trackW = self.progressTrackView.bounds.size.width;
    if (trackW > 0.0) {
        self.progressFillWidthConstraint.constant = trackW * (CGFloat)_displayedProgress;
    }

    if (!_progressActive && _progressHideTimestamp > 0.0 && CACurrentMediaTime() >= _progressHideTimestamp) {
        [_progressDisplayLink invalidate];
        _progressDisplayLink = nil;
        _displayedProgress = 0.0;
        self.progressHeightConstraint.constant = 0.0;
        [UIView animateWithDuration:0.25 animations:^{
            [self.panelCard layoutIfNeeded];
        }];
        [self updatePillIndicator];
    }
}

#pragma mark - UI Actions

- (void)handleTabChanged:(UISegmentedControl *)seg {
    [self switchToTabIndex:seg.selectedSegmentIndex];
}

- (void)switchToTabIndex:(NSInteger)idx {
    self.voiceTabContainer.hidden = (idx != 0);
    self.musicTabContainer.hidden = (idx != 1);
    self.systemTabContainer.hidden = (idx != 2);
}

- (void)handleVoiceEnableToggled:(UISwitch *)sw {
    [[PHLSyncManager sharedManager] setVoiceChangeEnabled:sw.isOn];
    [self refreshVoiceUI];
    [self updatePillIndicator];
}

- (void)handleMusicPrev {
    [[PHLMusicManager sharedManager] playPrevious];
}

- (void)handleMusicPlayPause {
    [[PHLMusicManager sharedManager] togglePlayPause];
}

- (void)handleMusicStop {
    [[PHLMusicManager sharedManager] stop];
}

- (void)handleMusicNext {
    [[PHLMusicManager sharedManager] playNext];
}

- (void)handleMusicVolumeChanged:(UISlider *)slider {
    [PHLMusicManager sharedManager].volume = slider.value;
    self.musicVolumeLabel.text = [NSString stringWithFormat:@"%d%%", (int)roundf(slider.value * 100.0f)];
}

- (void)handleSyncNowTapped {
    [[PHLSyncManager sharedManager] syncNowWithCompletion:nil];
}

- (void)handleAutoTuckToggled:(UISwitch *)sw {
    self.autoEdgeTuckEnabled = sw.isOn;
    [[NSUserDefaults standardUserDefaults] setBool:sw.isOn forKey:@"PHL_AutoEdgeTuck"];
}

#pragma mark - Refresh UI State

- (void)handleSyncStateChanged {
    [self refreshAllUI];
}

- (void)handleMusicStateChanged {
    [self refreshMusicUI];
}

- (void)refreshAllUI {
    [self updatePillIndicator];
    [self refreshHeaderBadge];
    [self refreshVoiceUI];
    [self refreshMusicUI];
    [self updateLiveTelemetryUI];
}

- (void)updatePillIndicator {
    PHLSyncManager *sync = [PHLSyncManager sharedManager];
    UIColor *dotColor = [UIColor systemGrayColor];
    if (_progressActive) {
        dotColor = [UIColor colorWithRed:0.96 green:0.62 blue:0.04 alpha:1.0];
    } else if (sync.tamperDetected || sync.maintenanceEnabled || sync.globalLock) {
        dotColor = [UIColor colorWithRed:0.94 green:0.27 blue:0.27 alpha:1.0];
    } else if (sync.voiceChangeEnabled && ![sync isCurrentVoiceEffectiveLocked]) {
        dotColor = [UIColor colorWithRed:0.13 green:0.77 blue:0.37 alpha:1.0];
    }
    self.pillStatusDot.backgroundColor = dotColor;
}

- (void)refreshHeaderBadge {
    PHLSyncManager *sync = [PHLSyncManager sharedManager];
    if (sync.tamperDetected) {
        self.headerBadgeLabel.text = @" CẢNH BÁO ";
        self.headerBadgeLabel.textColor = [UIColor colorWithRed:1.0 green:0.65 blue:0.65 alpha:1.0];
    } else if (sync.maintenanceEnabled) {
        self.headerBadgeLabel.text = @" BẢO TRÌ ";
        self.headerBadgeLabel.textColor = [UIColor colorWithRed:1.0 green:0.78 blue:0.35 alpha:1.0];
    } else if (sync.globalLock) {
        self.headerBadgeLabel.text = @" ĐANG KHÓA ";
        self.headerBadgeLabel.textColor = [UIColor colorWithRed:1.0 green:0.65 blue:0.65 alpha:1.0];
    } else {
        self.headerBadgeLabel.text = [NSString stringWithFormat:@" v%ld ", (long)sync.manifestVersion];
        self.headerBadgeLabel.textColor = [UIColor colorWithRed:0.22 green:0.74 blue:0.97 alpha:1.0];
    }
}

- (void)refreshVoiceUI {
    PHLSyncManager *sync = [PHLSyncManager sharedManager];
    self.voiceEnableSwitch.on = sync.voiceChangeEnabled;

    if (sync.tamperDetected) {
        self.voiceAlertBanner.hidden = NO;
        self.voiceAlertBanner.text = @"Phát hiện sửa đổi dữ liệu cục bộ — Đã giữ khóa an toàn!";
    } else if (sync.maintenanceEnabled) {
        self.voiceAlertBanner.hidden = NO;
        self.voiceAlertBanner.text = sync.maintenanceMessage;
    } else if (sync.globalLock) {
        self.voiceAlertBanner.hidden = NO;
        self.voiceAlertBanner.text = @"Admin đang bật Khóa Toàn Bộ giọng nói.";
    } else {
        self.voiceAlertBanner.hidden = YES;
        self.voiceAlertBanner.text = @"";
    }

    PHLVoiceItem *sel = [sync voiceItemForId:sync.selectedVoiceId];
    BOOL effLocked = [sync isCurrentVoiceEffectiveLocked];
    if (sync.voiceChangeEnabled && sel && !effLocked && sync.activeVoicePack) {
        self.voiceStatusLabel.text = [NSString stringWithFormat:@"Đang đổi giọng: %@", sel.name];
        self.voiceStatusLabel.textColor = [UIColor colorWithRed:0.29 green:0.87 blue:0.50 alpha:1.0];
    } else if (sync.voiceChangeEnabled && effLocked) {
        self.voiceStatusLabel.text = @"Đang khóa — Tự động giữ giọng gốc (Passthrough)";
        self.voiceStatusLabel.textColor = [UIColor colorWithRed:0.98 green:0.75 blue:0.25 alpha:1.0];
    } else {
        self.voiceStatusLabel.text = @"Tắt — Đang dùng giọng gốc (Passthrough)";
        self.voiceStatusLabel.textColor = [UIColor colorWithRed:0.65 green:0.75 blue:0.88 alpha:1.0];
    }

    PHLVoicePack *pack = sync.activeVoicePack;
    if (pack && !effLocked) {
        NSString *modeTag = pack.adaptivePitch ? [NSString stringWithFormat:@"F0 %.0fHz", pack.targetF0Hz] : [NSString stringWithFormat:@"%+.1f st", pack.pitchSemitones];
        self.voiceDspFooterLabel.text = [NSString stringWithFormat:@"Mục tiêu: %@  •  Formant: %.2fx  •  Gate: %.0f dB  •  Tự nhiên: %.0f%%",
                                         modeTag,
                                         pack.formantShift,
                                         pack.noiseGateDb,
                                         pack.naturalness * 100.0f];
    } else {
        self.voiceDspFooterLabel.text = @"DSP: Chế độ giọng gốc an toàn (Bypass)";
    }

    [self.voiceTableView reloadData];
}

- (void)refreshMusicUI {
    PHLMusicManager *mm = [PHLMusicManager sharedManager];
    PHLMusicTrack *t = mm.currentTrack;
    if (t) {
        self.musicTitleLabel.text = t.title;
        self.musicArtistLabel.text = t.artist;
    } else {
        self.musicTitleLabel.text = @"Chưa chọn bài nhạc";
        self.musicArtistLabel.text = @"Kho nhạc: phl-music-data (Độc lập với mic)";
    }
    [self.musicPlayPauseButton setTitle:(mm.isPlaying ? @"Tạm dừng" : @"Phát") forState:UIControlStateNormal];
    [self.musicTableView reloadData];
}

- (void)updateLiveTelemetryUI {
    if (!self.isExpanded) return;

    phl::dsp::TelemetrySnapshot tel = phl::dsp::VoiceDSPProcessor::shared().telemetry();
    float norm = MAX(0.0f, MIN(1.0f, (tel.input_db + 60.0f) / 60.0f));
    self.micMeterBar.progress = norm;
    self.micMeterBar.progressTintColor = tel.is_processing_active
        ? [UIColor colorWithRed:0.13 green:0.77 blue:0.37 alpha:1.0]
        : [UIColor colorWithRed:0.58 green:0.64 blue:0.72 alpha:1.0];

    PHLMusicManager *mm = [PHLMusicManager sharedManager];
    NSTimeInterval cur = mm.currentTime;
    NSTimeInterval dur = mm.duration;
    self.musicTimeLabel.text = [NSString stringWithFormat:@"%02d:%02d / %02d:%02d",
                                (int)cur / 60, (int)cur % 60,
                                (int)dur / 60, (int)dur % 60];
    self.musicSeekBar.progress = (dur > 0.1) ? (float)MAX(0.0, MIN(1.0, cur / dur)) : 0.0f;

    PHLSyncManager *sync = [PHLSyncManager sharedManager];
    PHLAudioHookStats hooks = PHLGetAudioHookStats();
    NSString *secMode = sync.signatureStrictlyVerified
        ? @"HMAC-SHA256 Chuẩn + Keychain Seal"
        : @"SHA-256 + Keychain Anti-Tamper Seal";

    self.systemInfoLabel.text = [NSString stringWithFormat:
        @"• Trạng thái: %@\n"
        @"• Đồng bộ gần nhất: %@\n"
        @"• Phiên bản Manifest: v%ld (%@)\n"
        @"• Phiên bản Nhạc: v%ld (%lu bài)\n"
        @"• Bảo trì: %@ | Khóa toàn cục: %@\n"
        @"• Bảo mật: %@\n"
        @"• Cảnh báo giả mạo: %@\n"
        @"• Hook Micro:\n"
        @"  - AVAudioInputNode: %@ (%llu)\n"
        @"  - AudioUnitRender:  %@ (%llu)\n"
        @"  - AudioQueueInput:  %@ (%llu)\n"
        @"• Mic: %.0f Hz | F0 nói: %.0f Hz | Shift: %+.1f st | Frame: %llu",
        sync.statusSummaryText,
        sync.lastSyncTimeFormatted,
        (long)sync.manifestVersion, sync.manifestUpdatedAt,
        (long)sync.playlistVersion, (unsigned long)sync.tracks.count,
        sync.maintenanceEnabled ? @"BẬT" : @"Tắt",
        sync.globalLock ? @"KHÓA" : @"Mở",
        secMode,
        sync.tamperDetected ? @"PHÁT HIỆN SỬA CACHE" : @"An toàn",
        hooks.avAudioInputHooked ? @"OK" : @"Chờ", (unsigned long long)hooks.avAudioTapCallbacks,
        hooks.audioUnitRenderHooked ? @"OK" : @"Chờ", (unsigned long long)hooks.audioUnitRenderCallbacks,
        hooks.audioQueueHooked ? @"OK" : @"Chờ", (unsigned long long)hooks.audioQueueCallbacks,
        tel.sample_rate, tel.detected_speaker_f0_hz, tel.effective_pitch_semitones, (unsigned long long)tel.processed_frames
    ];
}

#pragma mark - UITableViewDataSource / Delegate

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (tableView == self.voiceTableView) {
        return (NSInteger)[PHLSyncManager sharedManager].voices.count;
    }
    return (NSInteger)[PHLSyncManager sharedManager].tracks.count;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return (tableView == self.voiceTableView) ? 58.0 : 52.0;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (tableView == self.voiceTableView) {
        static NSString *const kVoiceCellId = @"PHLVoiceCell";
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kVoiceCellId];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:kVoiceCellId];
            cell.backgroundColor = [UIColor clearColor];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            cell.textLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold];
            cell.detailTextLabel.font = [UIFont systemFontOfSize:10.5 weight:UIFontWeightRegular];
        }
        PHLSyncManager *sync = [PHLSyncManager sharedManager];
        PHLVoiceItem *v = sync.voices[(NSUInteger)indexPath.row];
        BOOL isSelected = [v.voiceId isEqualToString:sync.selectedVoiceId];

        cell.textLabel.text = [NSString stringWithFormat:@"[%@] %@", v.category, v.name];
        cell.textLabel.textColor = v.effectiveLocked ? [UIColor colorWithWhite:0.55 alpha:1.0] : [UIColor whiteColor];
        cell.detailTextLabel.text = v.effectiveLocked
            ? @"Đã khóa bởi Admin — Nhấn sẽ giữ giọng gốc"
            : (v.voiceDescription.length > 0 ? v.voiceDescription : @"Sẵn sàng áp dụng");
        cell.detailTextLabel.textColor = v.effectiveLocked
            ? [UIColor colorWithRed:0.95 green:0.52 blue:0.52 alpha:1.0]
            : [UIColor colorWithRed:0.64 green:0.74 blue:0.86 alpha:1.0];

        cell.contentView.backgroundColor = isSelected
            ? [UIColor colorWithRed:0.15 green:0.45 blue:0.85 alpha:0.28]
            : [UIColor colorWithWhite:1.0 alpha:0.04];
        cell.contentView.layer.cornerRadius = 10.0;
        cell.contentView.layer.borderWidth = isSelected ? 1.0 : 0.0;
        cell.contentView.layer.borderColor = [UIColor colorWithRed:0.22 green:0.74 blue:0.97 alpha:0.8].CGColor;
        return cell;
    }

    static NSString *const kMusicCellId = @"PHLMusicCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kMusicCellId];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:kMusicCellId];
        cell.backgroundColor = [UIColor clearColor];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.textLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold];
        cell.detailTextLabel.font = [UIFont systemFontOfSize:10.5 weight:UIFontWeightRegular];
    }

    PHLMusicTrack *t = [PHLSyncManager sharedManager].tracks[(NSUInteger)indexPath.row];
    PHLMusicManager *mm = [PHLMusicManager sharedManager];
    BOOL isCurrent = [mm.currentTrack.trackId isEqualToString:t.trackId];
    BOOL cached = [mm isTrackCached:t];

    cell.textLabel.text = t.title;
    cell.textLabel.textColor = t.effectiveLocked ? [UIColor colorWithWhite:0.55 alpha:1.0] : [UIColor whiteColor];
    NSString *durStr = (t.durationSec > 0) ? [NSString stringWithFormat:@"%02ld:%02ld", (long)(t.durationSec / 60), (long)(t.durationSec % 60)] : @"--:--";
    cell.detailTextLabel.text = t.effectiveLocked
        ? @"Đã khóa bởi Admin"
        : [NSString stringWithFormat:@"%@ • %@ • %@", t.artist, durStr, (cached ? @"Đã lưu" : @"GitHub")];
    cell.detailTextLabel.textColor = t.effectiveLocked
        ? [UIColor colorWithRed:0.95 green:0.52 blue:0.52 alpha:1.0]
        : [UIColor colorWithRed:0.64 green:0.74 blue:0.86 alpha:1.0];

    cell.contentView.backgroundColor = isCurrent
        ? [UIColor colorWithRed:0.13 green:0.77 blue:0.37 alpha:0.22]
        : [UIColor colorWithWhite:1.0 alpha:0.04];
    cell.contentView.layer.cornerRadius = 10.0;
    cell.contentView.layer.borderWidth = isCurrent ? 1.0 : 0.0;
    cell.contentView.layer.borderColor = [UIColor colorWithRed:0.13 green:0.77 blue:0.37 alpha:0.8].CGColor;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (tableView == self.voiceTableView) {
        PHLVoiceItem *v = [PHLSyncManager sharedManager].voices[(NSUInteger)indexPath.row];
        [[PHLSyncManager sharedManager] selectVoiceWithId:v.voiceId completion:^(BOOL success, PHLVoicePack *pack, NSString *message) {
            if (success && ![PHLSyncManager sharedManager].voiceChangeEnabled) {
                [[PHLSyncManager sharedManager] setVoiceChangeEnabled:YES];
            }
            [self refreshAllUI];
        }];
        return;
    }

    PHLMusicTrack *t = [PHLSyncManager sharedManager].tracks[(NSUInteger)indexPath.row];
    [[PHLMusicManager sharedManager] playTrack:t];
}

@end
