//
//  AttractMode.m
//  MAME4iOS
//
//  Plays a random game when the user goes idle in the ROM browser, like a real
//  cabinet running its demo loop. Any input takes you back to browsing.
//

#import "AttractMode.h"
#import "ChooseGameController.h"
#import "EmulatorController.h"
#import "Options.h"

#if !__has_feature(objc_arc)
#error("This file assumes ARC")
#endif

#define DebugLog 0
#if DebugLog == 0
#define NSLog(...) (void)0
#endif

// how long the user has to sit still in the ROM browser before we take over
#define ATTRACT_IDLE_DELAY      10.0
// how long the chrome stays at full strength before fading back to let the game show
#define ATTRACT_DIM_DELAY       4.0
#define ATTRACT_DIM_ALPHA       0.6
// a game that dies this fast never really started, blame the ROM and move on
#define ATTRACT_MIN_RUN_TIME    5.0
// give up on Attract Mode after this many duds in a row
#define ATTRACT_MAX_FAILURES    5

// categories (from Category.ini) that make for a lousy demo
#define ATTRACT_SKIP_CATEGORIES @[@"Electromechanical", @"Mechanical", @"Utilities", @"Casino"]

#define OVERLAY_INSET           16.0
#define OVERLAY_CORNER_RADIUS   14.0
#define PROGRESS_HEIGHT         (TARGET_OS_IOS ? 3.0 : 6.0)

// seconds per entry of Options.arrayAttractDuration - keep these in step
static const NSTimeInterval kAttractDurations[] = { 30.0, 60.0, 120.0, 300.0 };

int g_attract_mode = 0;

// NOTE uses NSLogv, which is a real function and so survives the NSLog macro above
// (and the identical one in EmulatorController.m / ChooseGameController.m)
void AttractLog(NSString* format, ...)
{
    va_list args;
    va_start(args, format);
    NSLogv([@"ATTRACT: " stringByAppendingString:format], args);
    va_end(args);
}

#pragma mark - overlay view

@interface AttractModeOverlayView : UIView
@property (nonatomic, strong) UIView* chromeView;       // everything that dims
@property (nonatomic, strong) UILabel* titleLabel;
@property (nonatomic, strong) UILabel* detailLabel;
@property (nonatomic, strong) UIButton* playButton;
@property (nonatomic, strong) UIButton* nextButton;
- (void)startProgress:(NSTimeInterval)duration;
@end

@implementation AttractModeOverlayView
{
    UIView* _progressFill;
    NSLayoutConstraint* _progressWidth;
}

- (instancetype)initWithFrame:(CGRect)frame
{
    self = [super initWithFrame:frame];
    if (self == nil)
        return nil;

    self.backgroundColor = UIColor.clearColor;
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    // on tvOS we must not take part in focus at all, input arrives via the game controller
#if TARGET_OS_TV
    self.userInteractionEnabled = NO;
#endif

    [self buildProgressBar];
    [self buildChrome];

    return self;
}

// a thin line across the very top counting down this game's turn. it lives outside
// the chrome so it stays readable after everything else fades back.
- (void)buildProgressBar
{
    UIView* track = [[UIView alloc] init];
    track.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.15];
    track.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:track];

    _progressFill = [[UIView alloc] init];
    _progressFill.backgroundColor = self.tintColor;
    _progressFill.translatesAutoresizingMaskIntoConstraints = NO;
    [track addSubview:_progressFill];

    _progressWidth = [_progressFill.widthAnchor constraintEqualToConstant:0.0];

    [NSLayoutConstraint activateConstraints:@[
        [track.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [track.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [track.topAnchor constraintEqualToAnchor:self.topAnchor],
        [track.heightAnchor constraintEqualToConstant:PROGRESS_HEIGHT],

        [_progressFill.leadingAnchor constraintEqualToAnchor:track.leadingAnchor],
        [_progressFill.topAnchor constraintEqualToAnchor:track.topAnchor],
        [_progressFill.bottomAnchor constraintEqualToAnchor:track.bottomAnchor],
        _progressWidth,
    ]];
}

- (void)buildChrome
{
    _chromeView = [[UIView alloc] init];
    _chromeView.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_chromeView];

    // ATTRACT MODE badge, top leading
    UILabel* badge = [[UILabel alloc] init];
    badge.text = NSLocalizedString(@"◉ ATTRACT MODE", @"Attract Mode badge");
    badge.font = [UIFont boldSystemFontOfSize:TARGET_OS_IOS ? 13.0 : 22.0];
    badge.textColor = UIColor.whiteColor;

    UIView* badgeBox = [self makeBoxWithContent:badge insets:UIEdgeInsetsMake(6, 12, 6, 12)];

    // how to get out of here, under the badge
    UILabel* hint = [[UILabel alloc] init];
#if TARGET_OS_IOS
    hint.text = NSLocalizedString(@"Tap anywhere to browse ROMs", @"Attract Mode dismiss hint");
#else
    hint.text = NSLocalizedString(@"Ⓐ play · Ⓧ next · any other button to browse ROMs", @"Attract Mode dismiss hint");
#endif
    hint.font = [UIFont systemFontOfSize:TARGET_OS_IOS ? 12.0 : 20.0];
    hint.textColor = [UIColor colorWithWhite:1.0 alpha:0.65];

    UIStackView* topStack = [[UIStackView alloc] initWithArrangedSubviews:@[badgeBox, hint]];
    topStack.axis = UILayoutConstraintAxisVertical;
    topStack.alignment = UIStackViewAlignmentLeading;
    topStack.spacing = 6.0;
    topStack.translatesAutoresizingMaskIntoConstraints = NO;
    [_chromeView addSubview:topStack];

    // game info card, bottom leading
    _titleLabel = [[UILabel alloc] init];
    _titleLabel.font = [UIFont boldSystemFontOfSize:TARGET_OS_IOS ? 20.0 : 32.0];
    _titleLabel.textColor = UIColor.whiteColor;
    _titleLabel.numberOfLines = 2;

    _detailLabel = [[UILabel alloc] init];
    _detailLabel.font = [UIFont systemFontOfSize:TARGET_OS_IOS ? 13.0 : 22.0];
    _detailLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.7];
    _detailLabel.numberOfLines = 1;

    UIStackView* cardStack = [[UIStackView alloc] initWithArrangedSubviews:@[_titleLabel, _detailLabel]];
    cardStack.axis = UILayoutConstraintAxisVertical;
    cardStack.alignment = UIStackViewAlignmentLeading;
    cardStack.spacing = 2.0;

    UIView* card = [self makeBoxWithContent:cardStack insets:UIEdgeInsetsMake(10, 14, 10, 14)];

    // the two things that are not "stop the demo"
    _nextButton = [self makePillButton:NSLocalizedString(@"⏭ Next", @"Attract Mode next game button")
                            background:[UIColor colorWithWhite:1.0 alpha:0.2]];
    _playButton = [self makePillButton:NSLocalizedString(@"▶ Play This Game", @"Attract Mode keep playing button")
                            background:self.tintColor];

    UIStackView* bottomStack = [[UIStackView alloc] initWithArrangedSubviews:@[card, _nextButton, _playButton]];
    bottomStack.axis = UILayoutConstraintAxisHorizontal;
    bottomStack.alignment = UIStackViewAlignmentCenter;
    bottomStack.spacing = 10.0;
    bottomStack.translatesAutoresizingMaskIntoConstraints = NO;
    [_chromeView addSubview:bottomStack];

    UILayoutGuide* safe = self.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [_chromeView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [_chromeView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [_chromeView.topAnchor constraintEqualToAnchor:self.topAnchor],
        [_chromeView.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],

        [topStack.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:OVERLAY_INSET],
        [topStack.topAnchor constraintEqualToAnchor:safe.topAnchor constant:OVERLAY_INSET],
        [topStack.trailingAnchor constraintLessThanOrEqualToAnchor:safe.trailingAnchor constant:-OVERLAY_INSET],

        [bottomStack.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:OVERLAY_INSET],
        [bottomStack.trailingAnchor constraintLessThanOrEqualToAnchor:safe.trailingAnchor constant:-OVERLAY_INSET],
        [bottomStack.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-OVERLAY_INSET],
    ]];
}

- (UIButton*)makePillButton:(NSString*)title background:(UIColor*)color
{
    UIButton* button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont boldSystemFontOfSize:TARGET_OS_IOS ? 15.0 : 24.0];
    button.backgroundColor = color;
    #pragma clang diagnostic push
    #pragma clang diagnostic ignored "-Wdeprecated"
    button.contentEdgeInsets = UIEdgeInsetsMake(10, 18, 10, 18);
    #pragma clang diagnostic pop
    button.layer.cornerRadius = OVERLAY_CORNER_RADIUS;
    button.layer.masksToBounds = YES;
    [button setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    return button;
}

// a translucent dark rounded box wrapping some content
- (UIView*)makeBoxWithContent:(UIView*)content insets:(UIEdgeInsets)insets
{
    UIVisualEffectView* box = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleDark]];
    box.layer.cornerRadius = OVERLAY_CORNER_RADIUS;
    box.layer.masksToBounds = YES;

    content.translatesAutoresizingMaskIntoConstraints = NO;
    [box.contentView addSubview:content];
    [NSLayoutConstraint activateConstraints:@[
        [content.leadingAnchor constraintEqualToAnchor:box.contentView.leadingAnchor constant:insets.left],
        [content.trailingAnchor constraintEqualToAnchor:box.contentView.trailingAnchor constant:-insets.right],
        [content.topAnchor constraintEqualToAnchor:box.contentView.topAnchor constant:insets.top],
        [content.bottomAnchor constraintEqualToAnchor:box.contentView.bottomAnchor constant:-insets.bottom],
    ]];
    return box;
}

// run the countdown line from empty to full over this game's turn
- (void)startProgress:(NSTimeInterval)duration
{
    [_progressFill.layer removeAllAnimations];

    _progressWidth.constant = 0.0;
    [self layoutIfNeeded];

    _progressWidth.constant = self.bounds.size.width;
    [UIView animateWithDuration:duration delay:0.0
                        options:UIViewAnimationOptionCurveLinear | UIViewAnimationOptionBeginFromCurrentState
                     animations:^{ [self layoutIfNeeded]; }
                     completion:nil];
}

#if TARGET_OS_IOS
// swallow every touch except the ones landing on our buttons, so a tap anywhere
// else on screen means "stop the demo, let me browse"
- (UIView*)hitTest:(CGPoint)point withEvent:(UIEvent*)event
{
    UIView* view = [super hitTest:point withEvent:event];

    for (UIButton* button in @[_playButton, _nextButton]) {
        if (view == button || [view isDescendantOfView:button])
            return view;
    }

    return self;
}

- (void)touchesBegan:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event
{
    [AttractMode.shared stop];
}
#endif

@end

#pragma mark - idle gesture recognizer

@implementation AttractIdleGestureRecognizer

- (instancetype)init
{
    self = [super initWithTarget:nil action:NULL];
    self.cancelsTouchesInView = NO;
    self.delaysTouchesBegan = NO;
    self.delaysTouchesEnded = NO;
    return self;
}

- (void)touchesBegan:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event
{
    [AttractMode.shared noteUserActivity];
    self.state = UIGestureRecognizerStateFailed;
}

@end

#pragma mark - AttractMode

@implementation AttractMode
{
    NSArray<GameInfo*>* _gameList;
    NSSet<NSString*>* _notWorkingGames;     // flagged NOT_WORKING by MAME
    NSMutableArray<GameInfo*>* _bag;        // shuffled games not shown yet this cycle
    NSMutableSet<NSString*>* _badGames;     // games that refused to start
    GameInfo* _currentGame;
    NSTimer* _idleTimer;
    NSTimer* _gameTimer;
    NSTimer* _dimTimer;
    AttractModeOverlayView* _overlay;
    BOOL _browserVisible;
    NSTimeInterval _gameStartTime;
    NSInteger _failureCount;
}

+ (AttractMode*)shared
{
    static AttractMode* shared = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [[AttractMode alloc] init];
    });
    return shared;
}

- (instancetype)init
{
    self = [super init];
    if (self == nil)
        return nil;

    _bag = [[NSMutableArray alloc] init];
    _badGames = [[NSMutableSet alloc] init];
    _notWorkingGames = [NSSet set];
    _enabled = [NSUserDefaults.standardUserDefaults boolForKey:ATTRACT_MODE_KEY];

    return self;
}

#pragma mark enabled

- (void)setEnabled:(BOOL)enabled
{
    if (_enabled == enabled)
        return;

    _enabled = enabled;
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:ATTRACT_MODE_KEY];

    // turning it on is itself the "go" signal - dont make the user sit through the
    // idle countdown they just deliberately armed
    if (enabled)
        [self start];
    else
        [self stop];
}

#pragma mark game list

- (void)setGameList:(NSArray<GameInfo*>*)games
{
    _gameList = [games copy];
    [_bag removeAllObjects];
}

// MAME knows which drivers are NOT_WORKING, but that flag does not survive into GameInfo,
// so EmulatorController hands us the names directly. these are the ones that greet you
// with a red error screen, never show them unattended.
- (void)setNotWorkingGameNames:(NSSet<NSString*>*)names
{
    _notWorkingGames = [names copy] ?: [NSSet set];
    [_bag removeAllObjects];
}

- (BOOL)isMechanical:(GameInfo*)game
{
    NSString* category = game.gameCategory;
    if (category.length == 0)
        return NO;

    for (NSString* skip in ATTRACT_SKIP_CATEGORIES) {
        if ([category rangeOfString:skip options:NSCaseInsensitiveSearch].location != NSNotFound)
            return YES;
    }
    return NO;
}

// anything that will actually put a picture on screen unattended - arcade machines,
// consoles and computers running software, the lot. we only rule out things that
// cannot run on their own or make a bad demo.
- (BOOL)isAttractCandidate:(GameInfo*)game
{
    if (game.gameName.length == 0)
        return NO;

    // the MAME menu pseudo-game, and snapshots which are pictures, not games
    if (game.gameIsMame || game.gameIsSnapshot)
        return NO;

    // a BIOS root is an empty system board, there is nothing to watch
    if ([game.gameType isEqualToString:kGameInfoTypeBIOS])
        return NO;

    // a bare console with no software loaded just sits there. this is the same rule
    // the ROM browser uses for its `hideConsoles` filter.
    if (game.gameIsConsole && game.gameSystem.length == 0)
        return NO;

    // software with no system or media assigned cannot just be launched - the ROM
    // browser has to ask the user which system to run it on, see -play: in
    // ChooseGameController. we go straight to EmulatorController, so skip these.
    if (game.gameIsSoftware && (game.gameSystem.length == 0 || game.gameMediaType.length == 0))
        return NO;

    // clones are near duplicates of a parent that is already in the pool
    if (game.gameIsClone)
        return NO;

    if ([_notWorkingGames containsObject:game.gameName])
        return NO;
    if ([_badGames containsObject:game.gameName])
        return NO;
    if ([self isMechanical:game])
        return NO;

    return YES;
}

// pull from a shuffled bag so every game gets a turn before any repeats
- (GameInfo*)nextGameInfo
{
    if (_bag.count == 0) {
        for (GameInfo* game in _gameList) {
            if ([self isAttractCandidate:game])
                [_bag addObject:game];
        }
        for (NSInteger i = (NSInteger)_bag.count - 1; i > 0; i--)
            [_bag exchangeObjectAtIndex:i withObjectAtIndex:arc4random_uniform((uint32_t)(i + 1))];
    }

    GameInfo* game = _bag.lastObject;
    if (game != nil)
        [_bag removeLastObject];

    return game;
}

// how long each game gets, from the Attract Mode section of Settings
- (NSTimeInterval)gameDuration
{
    int index = [[Options alloc] init].attractDuration;

    if (index < 0 || index >= (int)(sizeof(kAttractDurations) / sizeof(kAttractDurations[0])))
        index = 0;

    return kAttractDurations[index];
}

#pragma mark browser lifecycle

- (void)browserDidAppear
{
    _browserVisible = YES;
    [self restartIdleTimer];
}

- (void)browserWillDisappear
{
    _browserVisible = NO;
    [_idleTimer invalidate];
    _idleTimer = nil;
}

- (void)restartIdleTimer
{
    [_idleTimer invalidate];
    _idleTimer = nil;

    if (!_enabled || _running || !_browserVisible)
        return;

    __weak AttractMode* _self = self;
    _idleTimer = [NSTimer scheduledTimerWithTimeInterval:ATTRACT_IDLE_DELAY repeats:NO block:^(NSTimer* timer) {
        [_self start];
    }];
}

// the user launched a game on their own - turn Attract Mode off so it does not
// hijack the screen again the moment they come back to the browser and pause.
// NOTE this deliberately does not go through -setEnabled:, which would call -stop
// and exit the game the user just started.
- (void)userDidStartGame
{
    if (!_enabled && !_running)
        return;

    AttractLog(@"USER STARTED A GAME, TURNING ATTRACT MODE OFF");

    _enabled = NO;
    [NSUserDefaults.standardUserDefaults setBool:NO forKey:ATTRACT_MODE_KEY];
    [self endAttractSession];
}

- (void)noteUserActivity
{
    if (_running)
        [self stop];
    else
        [self restartIdleTimer];
}

#pragma mark start / next / stop

// the ROM browser stays "visible" while Settings, Add ROMs, game info or an alert is
// presented over it, and EmulatorController refuses to run a game in that state. so
// check we are really frontmost before taking over, or we end up flagged as running
// with no game behind the overlay.
- (BOOL)isBrowserFrontmost
{
    UIViewController* presented = EmulatorController.sharedInstance.presentedViewController;
    return presented != nil && presented.presentedViewController == nil;
}

- (void)start
{
    if (_running || !_enabled || !_browserVisible)
        return;

    if (![self isBrowserFrontmost]) {
        AttractLog(@"NOT STARTING - something is presented over the ROM browser");
        return [self restartIdleTimer];     // check back in another idle period
    }

    GameInfo* game = [self nextGameInfo];
    if (game == nil) {
        AttractLog(@"NO GAMES TO SHOW");
        return;
    }

    AttractLog(@"START %@ (\"%@\")", game.gameName, game.gameTitle);

    _running = YES;
    _failureCount = 0;
    g_attract_mode = 1;

    [self showOverlayForGame:game];
    [self playGame:game];
}

- (void)skipToNextGame
{
    if (!_running)
        return;

    GameInfo* game = [self nextGameInfo];
    if (game == nil)
        return [self stop];

    AttractLog(@"NEXT %@ (\"%@\") - %d left in bag", game.gameName, game.gameTitle, (int)_bag.count);

    _failureCount = 0;
    [self updateOverlayForGame:game];
    [self playGame:game];
}

- (void)playGame:(GameInfo*)game
{
    _currentGame = game;
    _gameStartTime = NSDate.timeIntervalSinceReferenceDate;

    [_gameTimer invalidate];
    __weak AttractMode* _self = self;
    _gameTimer = [NSTimer scheduledTimerWithTimeInterval:self.gameDuration repeats:NO block:^(NSTimer* timer) {
        [_self skipToNextGame];
    }];

    AttractLog(@"REQUEST PLAY %@", game.gameName);

    // when the ROM browser is up this routes through its selectGameCallback, which
    // dismisses the browser (saving scroll position) and then boots the game.
    [EmulatorController.sharedInstance playGame:game];
}

// MAME got the machine up - if it turned out to be a broken one, dont sit on it
- (void)attractGameDidStart:(NSString*)name broken:(BOOL)broken
{
    if (!_running)
        return;

    // MAME started something other than what we asked for, so the overlay is now
    // lying about what is on screen. dont sit on it for 30 seconds.
    if (![name isEqualToString:_currentGame.gameName]) {
        AttractLog(@"DESYNC - asked for %@ but MAME started %@, moving on", _currentGame.gameName, name);
        return [self skipToNextGame];
    }

    if (!broken)
        return;

    AttractLog(@"%@ FLAGGED NOT_WORKING BY MAME, SKIPPING", name);
    [_badGames addObject:name];
    [self skipToNextGame];
}

// the attract game exited on its own, or MAME refused to run it
- (void)attractGameDidEnd
{
    if (!_running)
        return;

    AttractLog(@"GAME ENDED after %.1fsec (current=%@)",
               NSDate.timeIntervalSinceReferenceDate - _gameStartTime, _currentGame.gameName);

    BOOL failed = (NSDate.timeIntervalSinceReferenceDate - _gameStartTime) < ATTRACT_MIN_RUN_TIME;

    if (failed) {
        AttractLog(@"%@ ONLY RAN %.1fsec, TREATING AS FAILED (failure %d of %d)", _currentGame.gameName,
                   NSDate.timeIntervalSinceReferenceDate - _gameStartTime, (int)_failureCount + 1, ATTRACT_MAX_FAILURES);
        if (_currentGame.gameName.length != 0)
            [_badGames addObject:_currentGame.gameName];

        if (++_failureCount >= ATTRACT_MAX_FAILURES) {
            AttractLog(@"TOO MANY FAILURES, GIVING UP");
            return [self stop];
        }

        // dont reset the failure counter the way skipToNextGame would
        GameInfo* game = [self nextGameInfo];
        if (game == nil)
            return [self stop];
        [self updateOverlayForGame:game];
        return [self playGame:game];
    }

    [self skipToNextGame];
}

- (void)stop
{
    if (!_running)
        return;

    AttractLog(@"STOP");

    // clear the flag first, so the ROM browser comes back up normally
    [self endAttractSession];
    [EmulatorController.sharedInstance runExit:NO];
}

- (void)keepPlaying
{
    if (!_running)
        return;

    AttractLog(@"KEEP PLAYING %@", _currentGame.gameName);

    GameInfo* game = _currentGame;
    [self endAttractSession];

    // the user chose this one for real, so it belongs in Recently Played
    [ChooseGameController addRecentGame:game];

    // bring back the touch controls and HUD we suppressed while attracting
    [EmulatorController.sharedInstance changeUI];
}

- (void)endAttractSession
{
    _running = NO;
    g_attract_mode = 0;
    _currentGame = nil;

    [_gameTimer invalidate];
    _gameTimer = nil;
    [_idleTimer invalidate];
    _idleTimer = nil;

    [self hideOverlay];
}

#pragma mark overlay

- (void)showOverlayForGame:(GameInfo*)game
{
    UIView* parent = EmulatorController.sharedInstance.view;
    if (parent == nil)
        return;

    if (_overlay == nil) {
        _overlay = [[AttractModeOverlayView alloc] initWithFrame:parent.bounds];
        [_overlay.playButton addTarget:self action:@selector(playButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
        [_overlay.nextButton addTarget:self action:@selector(nextButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
    }

    _overlay.alpha = 0.0;
    [parent addSubview:_overlay];
    [self updateOverlayForGame:game];

    [UIView animateWithDuration:0.3 animations:^{
        self->_overlay.alpha = 1.0;
    }];
}

- (void)updateOverlayForGame:(GameInfo*)game
{
    _overlay.titleLabel.text = game.gameTitle.length != 0 ? game.gameTitle : game.gameDescription;

    NSMutableArray* parts = [[NSMutableArray alloc] init];
    if (game.gameYear.length != 0)
        [parts addObject:game.gameYear];
    if (game.gameManufacturer.length != 0)
        [parts addObject:game.gameManufacturer];
    _overlay.detailLabel.text = [parts componentsJoinedByString:@" · "];

    [_overlay startProgress:self.gameDuration];

    // come back to full strength for the new game, then fade back out of the way
    [_dimTimer invalidate];
    [UIView animateWithDuration:0.3 animations:^{
        self->_overlay.chromeView.alpha = 1.0;
    }];

    __weak AttractMode* _self = self;
    _dimTimer = [NSTimer scheduledTimerWithTimeInterval:ATTRACT_DIM_DELAY repeats:NO block:^(NSTimer* timer) {
        [_self dimOverlay];
    }];
}

- (void)dimOverlay
{
    [UIView animateWithDuration:0.6 animations:^{
        self->_overlay.chromeView.alpha = ATTRACT_DIM_ALPHA;
    }];
}

- (void)hideOverlay
{
    [_dimTimer invalidate];
    _dimTimer = nil;

    AttractModeOverlayView* overlay = _overlay;
    _overlay = nil;
    [UIView animateWithDuration:0.2 animations:^{
        overlay.alpha = 0.0;
    } completion:^(BOOL finished) {
        [overlay removeFromSuperview];
    }];
}

- (void)playButtonTapped:(id)sender
{
    [self keepPlaying];
}

- (void)nextButtonTapped:(id)sender
{
    [self skipToNextGame];
}

// changeUI rebuilds the emulator view hierarchy on every new game, so re-raise the overlay
- (void)didChangeUI
{
    if (_running && _overlay.superview != nil)
        [_overlay.superview bringSubviewToFront:_overlay];
}

@end
