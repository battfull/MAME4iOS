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
#import "MAME4iOS-Swift.h"

#if !__has_feature(objc_arc)
#error("This file assumes ARC")
#endif

#define DebugLog 0
#if DebugLog == 0
#define NSLog(...) (void)0
#endif

// how long to wait before retrying a start that was blocked (eg Settings was up)
#define ATTRACT_RETRY_DELAY     2.0
// how long to let a machine finish booting before we skip away from it, see -skipSoon
#define ATTRACT_SKIP_DELAY      1.5
// how long the chrome stays at full strength before fading back to let the game show
#define ATTRACT_DIM_DELAY       4.0
#define ATTRACT_DIM_ALPHA       0.6
// a game that dies this fast never really started, blame the ROM and move on
#define ATTRACT_MIN_RUN_TIME    5.0
// give up on Attract Mode after this many duds in a row
#define ATTRACT_MAX_FAILURES    5

// categories (from Category.ini) that make for a lousy demo
#define ATTRACT_SKIP_CATEGORIES @[@"Electromechanical", @"Mechanical", @"Utilities", @"Casino"]
// Category.ini files this app ships put grown up games (a lot of mahjong) under [Adult]
#define ATTRACT_ADULT_CATEGORY  @"Adult"

#define OVERLAY_INSET           16.0
#define OVERLAY_CORNER_RADIUS   14.0
#define PROGRESS_HEIGHT         (TARGET_OS_IOS ? 3.0 : 6.0)

// the preview cell sits among the game cells, so match their look. these mirror the
// CELL_* macros in ChooseGameController.m, which are private to that file.
#define ATTRACT_CELL_CORNER_RADIUS  16.0
#define ATTRACT_CELL_TITLE_COLOR    [UIColor whiteColor]
#define ATTRACT_CELL_DETAIL_COLOR   [UIColor colorWithWhite:1.0 alpha:0.6]
#if (TARGET_OS_IOS && !TARGET_OS_MACCATALYST)
#define ATTRACT_CELL_TITLE_FONT     [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline]
#define ATTRACT_CELL_DETAIL_FONT    [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote]
#else
#define ATTRACT_CELL_TITLE_FONT     [UIFont boldSystemFontOfSize:20.0]
#define ATTRACT_CELL_DETAIL_FONT    [UIFont systemFontOfSize:20.0]
#endif

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

#pragma mark - inline cell

@implementation AttractModeCell
{
    UIButton* _pinButton;
    CGSize _lastScreenSize;
    UILabel* _titleLabel;
    UILabel* _detailLabel;
    UIView* _progressTrack;
    UIView* _progressFill;
    NSLayoutConstraint* _progressWidth;
}

- (instancetype)initWithFrame:(CGRect)frame
{
    self = [super initWithFrame:frame];
    if (self == nil)
        return nil;

    self.backgroundColor = UIColor.clearColor;

    // the emulator renders in here. black so letterboxing looks deliberate.
    _screenContainer = [[UIView alloc] init];
    _screenContainer.backgroundColor = UIColor.blackColor;
    _screenContainer.layer.cornerRadius = ATTRACT_CELL_CORNER_RADIUS;
    _screenContainer.layer.masksToBounds = YES;
    _screenContainer.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:_screenContainer];

    // countdown line across the bottom of the preview
    _progressTrack = [[UIView alloc] init];
    _progressTrack.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.15];
    _progressTrack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:_progressTrack];

    _progressFill = [[UIView alloc] init];
    _progressFill.backgroundColor = self.tintColor;
    _progressFill.translatesAutoresizingMaskIntoConstraints = NO;
    [_progressTrack addSubview:_progressFill];
    _progressWidth = [_progressFill.widthAnchor constraintEqualToConstant:0.0];

    _titleLabel = [[UILabel alloc] init];
    _titleLabel.font = ATTRACT_CELL_TITLE_FONT;
    _titleLabel.textColor = ATTRACT_CELL_TITLE_COLOR;
    _titleLabel.numberOfLines = 1;

    _detailLabel = [[UILabel alloc] init];
    _detailLabel.font = ATTRACT_CELL_DETAIL_FONT;
    _detailLabel.textColor = ATTRACT_CELL_DETAIL_COLOR;
    _detailLabel.numberOfLines = 1;

    UIStackView* text = [[UIStackView alloc] initWithArrangedSubviews:@[_titleLabel, _detailLabel]];
    text.axis = UILayoutConstraintAxisVertical;
    text.alignment = UIStackViewAlignmentLeading;

    UIButton* next = [self makeButton:NSLocalizedString(@"⏭ Next", @"Attract Mode next game button")
                               symbol:nil action:@selector(nextTapped)];
    _pinButton = [self makeButton:nil symbol:@"pin" action:@selector(pinTapped)];
    UIButton* expand = [self makeButton:nil symbol:@"arrow.up.left.and.arrow.down.right" action:@selector(expandTapped)];

    _pinButton.accessibilityLabel = NSLocalizedString(@"Pin Attract Mode", @"Attract Mode pin button");
    expand.accessibilityLabel = NSLocalizedString(@"Full Screen", @"Attract Mode expand button");

    UIStackView* row = [[UIStackView alloc] initWithArrangedSubviews:@[text, next, _pinButton, expand]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentCenter;
    row.spacing = 8.0;
    row.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:row];

    [text setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];

    UIView* content = self.contentView;
    [NSLayoutConstraint activateConstraints:@[
        [_screenContainer.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [_screenContainer.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [_screenContainer.topAnchor constraintEqualToAnchor:content.topAnchor],

        [_progressTrack.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [_progressTrack.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [_progressTrack.topAnchor constraintEqualToAnchor:_screenContainer.bottomAnchor],
        [_progressTrack.heightAnchor constraintEqualToConstant:3.0],

        [_progressFill.leadingAnchor constraintEqualToAnchor:_progressTrack.leadingAnchor],
        [_progressFill.topAnchor constraintEqualToAnchor:_progressTrack.topAnchor],
        [_progressFill.bottomAnchor constraintEqualToAnchor:_progressTrack.bottomAnchor],
        _progressWidth,

        [row.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:4.0],
        [row.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-4.0],
        [row.topAnchor constraintEqualToAnchor:_progressTrack.bottomAnchor constant:6.0],
        [row.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-4.0],
    ]];

    [self updatePinButton];

    return self;
}

- (UIButton*)makeButton:(NSString*)title symbol:(NSString*)symbol action:(SEL)action
{
    UIButton* button = [UIButton buttonWithType:UIButtonTypeSystem];

    if (symbol != nil) {
        UIImageSymbolConfiguration* config = [UIImageSymbolConfiguration configurationWithPointSize:TARGET_OS_IOS ? 15.0 : 22.0];
        [button setImage:[UIImage systemImageNamed:symbol withConfiguration:config] forState:UIControlStateNormal];
        button.tintColor = UIColor.whiteColor;
    }

    [button setTitle:title forState:UIControlStateNormal];
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont boldSystemFontOfSize:TARGET_OS_IOS ? 13.0 : 20.0];
    button.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.2];
    #pragma clang diagnostic push
    #pragma clang diagnostic ignored "-Wdeprecated"
    button.contentEdgeInsets = UIEdgeInsetsMake(6, 12, 6, 12);
    #pragma clang diagnostic pop
    button.layer.cornerRadius = 10.0;
    button.layer.masksToBounds = YES;
    [button setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (void)setGameTitle:(NSString*)title detail:(NSString*)detail
{
    _titleLabel.text = title ?: @"";
    _detailLabel.text = detail ?: @"";
    [self updatePinButton];
}

- (void)startProgress:(NSTimeInterval)duration
{
    [_progressFill.layer removeAllAnimations];

    _progressWidth.constant = 0.0;
    [self layoutIfNeeded];

    _progressWidth.constant = _progressTrack.bounds.size.width;
    [UIView animateWithDuration:duration delay:0.0
                        options:UIViewAnimationOptionCurveLinear | UIViewAnimationOptionBeginFromCurrentState
                     animations:^{ [self layoutIfNeeded]; }
                     completion:nil];
}

- (void)nextTapped   { [AttractMode.shared skipToNextGame]; }
- (void)expandTapped { [AttractMode.shared expandToFullScreen]; }
- (void)pinTapped    { [AttractMode.shared togglePinned]; }

// the emulator fits itself to screenContainer.bounds, so it has to be told whenever
// that changes - rotation, or the pinned panel being rebuilt at a new size
- (void)layoutSubviews
{
    [super layoutSubviews];

    CGSize size = self.screenContainer.bounds.size;

    if (size.width > 0.0 && size.height > 0.0 && !CGSizeEqualToSize(size, _lastScreenSize)) {
        _lastScreenSize = size;
        [AttractMode.shared previewContainerDidResize:self];
    }
}

// filled pin means "pinned, tap to unpin"
- (void)updatePinButton
{
    BOOL pinned = [AttractMode isPinned];

    // no room to pin in landscape on a phone
    _pinButton.hidden = ![AttractMode.shared isPinningAvailable];
    UIImageSymbolConfiguration* config = [UIImageSymbolConfiguration configurationWithPointSize:TARGET_OS_IOS ? 15.0 : 22.0];

    [_pinButton setImage:[UIImage systemImageNamed:(pinned ? @"pin.fill" : @"pin") withConfiguration:config] forState:UIControlStateNormal];
    _pinButton.accessibilityLabel = pinned ? NSLocalizedString(@"Unpin Attract Mode", @"Attract Mode unpin button")
                                           : NSLocalizedString(@"Pin Attract Mode", @"Attract Mode pin button");
}

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

#pragma mark - custom list table

@implementation AttractModeListController
{
    NSMutableArray<GameInfo*>* _games;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = NSLocalizedString(@"My Attract Mode List", @"Attract Mode custom list screen");
#if TARGET_OS_IOS
    self.navigationItem.rightBarButtonItem = self.editButtonItem;
#endif
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    _games = [[AttractMode customList] mutableCopy];
    [self.tableView reloadData];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return MAX(_games.count, 1);    // one row of explanatory text when empty
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell* cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];

    if (_games.count == 0) {
        cell.textLabel.text = NSLocalizedString(@"No games yet", @"Attract Mode empty list");
        cell.detailTextLabel.text = NSLocalizedString(@"Long press a game in the ROM list and choose Add to Attract Mode.", @"Attract Mode empty list hint");
        cell.detailTextLabel.numberOfLines = 0;
        cell.textLabel.textColor = UIColor.grayColor;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }

    GameInfo* game = _games[indexPath.row];
    cell.textLabel.text = game.gameTitle.length != 0 ? game.gameTitle : game.gameDescription;
    cell.detailTextLabel.text = game.gameManufacturer;
    return cell;
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath
{
    return _games.count != 0;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)style forRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (style != UITableViewCellEditingStyleDelete || indexPath.row >= _games.count)
        return;

    [self removeGameAtIndex:indexPath.row];

    // the empty-state row takes the place of the last real one, so reload rather
    // than delete when we just emptied the list
    if (_games.count == 0)
        [tableView reloadData];
    else
        [tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

#if TARGET_OS_TV
    // no swipe to delete on tvOS, so selecting a row removes it
    if (indexPath.row < _games.count) {
        [self removeGameAtIndex:indexPath.row];
        [tableView reloadData];
    }
#endif
}

- (void)removeGameAtIndex:(NSUInteger)index
{
    GameInfo* game = _games[index];
    [_games removeObjectAtIndex:index];
    [AttractMode setGame:game inCustomList:NO];
    AttractLog(@"REMOVED %@ FROM LIST", game.gameName);
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
    AttractModeCell* _inlineCell;   // the browser cell we are previewing into, or nil
    BOOL _fullScreen;               // TRUE once we have taken over the whole screen
    BOOL _paused;                   // TRUE while the preview is scrolled out of view
    NSTimeInterval _pausedRemaining;// seconds left in this game's turn when we paused
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
    _pinningAvailable = YES;    // until a browser tells us otherwise
    _notWorkingGames = [NSSet set];

    return self;
}

#pragma mark enabled

// read straight from Options every time. the switch lives in Settings, which is
// presented as a page sheet over the ROM browser, and a new ChooseGameController is
// built every time MAME returns to the menu - a cached copy goes stale in too many
// places to keep track of.
- (BOOL)isEnabled
{
    return [[Options alloc] init].attractMode != 0;
}

- (void)setEnabled:(BOOL)enabled
{
    if (self.isEnabled == enabled)
        return;

    Options* options = [[Options alloc] init];
    options.attractMode = enabled ? 1 : 0;
    [options saveOptions];

    // turning it on makes the ROM browser insert its preview section, and the cell
    // attaching is what actually starts the demo - see -attachInlineCell:
    if (!enabled)
        [self stop];
}

// called when Settings is dismissed, in case the switch was turned off
- (void)reloadOptions
{
    if (!self.isEnabled)
        [self stop];
}

#pragma mark game list

+ (NSArray<GameInfo*>*)customList
{
    NSArray* saved = [NSUserDefaults.standardUserDefaults arrayForKey:ATTRACT_LIST_KEY] ?: @[];

    NSMutableArray* games = [[NSMutableArray alloc] init];
    for (NSDictionary* dict in saved) {
        if ([dict isKindOfClass:[NSDictionary class]])
            [games addObject:[[GameInfo alloc] initWithDictionary:dict]];
    }
    return games;
}

+ (BOOL)isPinned
{
    return [[Options alloc] init].attractPinned != 0;
}

- (void)setPinningAvailable:(BOOL)available
{
    if (_pinningAvailable == available)
        return;

    _pinningAvailable = available;
    [_inlineCell updatePinButton];
}

- (void)previewContainerDidResize:(AttractModeCell*)cell
{
    if (_inlineCell != cell || _fullScreen || !_running)
        return;

    AttractLog(@"PREVIEW RESIZED, REFITTING");
    [EmulatorController.sharedInstance changeUI];
}

- (void)togglePinned
{
    BOOL pinned = ![AttractMode isPinned];
    AttractLog(@"%@", pinned ? @"PINNED" : @"UNPINNED");

    Options* options = [[Options alloc] init];
    options.attractPinned = pinned ? 1 : 0;
    [options saveOptions];

    // the browser has to move the preview between its collection view and the pinned
    // panel at the top - it owns both, so let it rebuild
    [self.browser reloadAttractSection];
}

// the ROM browser, if it is the thing currently on screen
- (ChooseGameController*)browser
{
    UIViewController* top = EmulatorController.sharedInstance.topViewController;

    if ([top isKindOfClass:[UINavigationController class]])
        top = [(UINavigationController*)top topViewController];

    return [top isKindOfClass:[ChooseGameController class]] ? (ChooseGameController*)top : nil;
}

+ (BOOL)isInCustomList:(GameInfo*)game
{
    NSArray* saved = [NSUserDefaults.standardUserDefaults arrayForKey:ATTRACT_LIST_KEY] ?: @[];
    return [saved containsObject:game.gameDictionary];
}

+ (void)setGame:(GameInfo*)game inCustomList:(BOOL)flag
{
    if (game == nil || game.gameName.length == 0)
        return;

    NSMutableArray* saved = [([NSUserDefaults.standardUserDefaults arrayForKey:ATTRACT_LIST_KEY] ?: @[]) mutableCopy];

    [saved removeObject:game.gameDictionary];
    if (flag)
        [saved addObject:game.gameDictionary];

    [NSUserDefaults.standardUserDefaults setObject:saved forKey:ATTRACT_LIST_KEY];

    // the pool changed, build a fresh bag next time round
    [AttractMode.shared invalidateBag];
}

- (void)setGameList:(NSArray<GameInfo*>*)games
{
    _gameList = [games copy];
    [_bag removeAllObjects];
}

- (void)invalidateBag
{
    [_bag removeAllObjects];
}

// TRUE when Settings says to play the user's own list instead of a random draw
- (BOOL)useCustomList
{
    return [[Options alloc] init].attractSource != 0;
}

// MAME knows which drivers are NOT_WORKING, but that flag does not survive into GameInfo,
// so EmulatorController hands us the names directly. these are the ones that greet you
// with a red error screen, never show them unattended.
- (void)setNotWorkingGameNames:(NSSet<NSString*>*)names
{
    _notWorkingGames = [names copy] ?: [NSSet set];
    [_bag removeAllObjects];
}

// only consulted for the random pool - a game the user put in their own list is their
// business. NOTE find_category can join several categories with commas, hence contains.
- (BOOL)isAdult:(GameInfo*)game
{
    if ([[Options alloc] init].attractHideAdult == 0)
        return NO;

    return [game.gameCategory rangeOfString:ATTRACT_ADULT_CATEGORY options:NSCaseInsensitiveSearch].location != NSNotFound;
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
    if ([self isAdult:game])
        return NO;

    return YES;
}

// pull from a shuffled bag so every game gets a turn before any repeats
- (GameInfo*)nextGameInfo
{
    if (_bag.count == 0) {
        // the user's own list, if they picked one and it is not empty. these were
        // chosen deliberately, so only the "it will not run" checks apply.
        if (self.useCustomList) {
            for (GameInfo* game in [AttractMode customList]) {
                if (game.gameName.length != 0 && ![_badGames containsObject:game.gameName])
                    [_bag addObject:game];
            }
            if (_bag.count == 0)
                AttractLog(@"MY LIST IS EMPTY, FALLING BACK TO RANDOM");
        }

        for (GameInfo* game in (_bag.count == 0 ? _gameList : @[])) {
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

    // willDisplayCell can run before viewDidAppear, in which case -start bailed out
    // because the browser was not marked visible yet. pick it up now.
    if (_inlineCell != nil && !_running)
        [self start];
}

- (void)browserWillDisappear
{
    _browserVisible = NO;
    [_idleTimer invalidate];
    _idleTimer = nil;
}

// the preview plays inline in its own browser section and stays there. going full
// screen is a deliberate act - the Full Screen button - never something that happens
// to the user while they are reading the list.
//
// this timer only exists to retry a start that could not happen yet, eg because
// Settings was presented over the browser.
- (void)retryStartLater
{
    [_idleTimer invalidate];
    _idleTimer = nil;

    if (!self.isEnabled || _running || _fullScreen || !_browserVisible)
        return;

    __weak AttractMode* _self = self;
    _idleTimer = [NSTimer scheduledTimerWithTimeInterval:ATTRACT_RETRY_DELAY repeats:NO block:^(NSTimer* timer) {
        [_self start];
    }];
}

// the user launched a game on their own - end our session and hand the screen back.
// NOTE this leaves the Attract Mode setting alone. it used to switch it off, which
// made sense when Attract Mode meant a full screen takeover, but now that it is a
// section in the ROM browser turning it off would delete the section every time the
// user played anything.
// NOTE also this deliberately does not go through -setEnabled:, which calls -stop and
// would exit the game the user just started.
- (void)userDidStartGame
{
    if (!_running && EmulatorController.sharedInstance.embeddedView == nil)
        return;

    AttractLog(@"USER STARTED A GAME, STANDING DOWN");
    [self endAttractSession];
}

- (void)noteUserActivity
{
    // scrolling the ROM browser is not a reason to stop the inline preview, but any
    // input during a full screen takeover means "let me browse"
    if (_fullScreen)
        [self stop];
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

// the preview cell scrolled into view - render into it and start the demo
- (void)attachInlineCell:(AttractModeCell*)cell
{
    if (cell == nil || _fullScreen)
        return;

    _inlineCell = cell;
    EmulatorController.sharedInstance.embeddedView = cell.screenContainer;

    if (!_running)
        [self start];
    else if (_paused)
        [self resumePreview];
    else
        [self updateChromeForGame:_currentGame duration:self.remainingGameTime];
}

// the preview cell scrolled away - stop emulating into a view nobody can see
- (void)detachInlineCell:(AttractModeCell*)cell
{
    if (_inlineCell != cell || _fullScreen)
        return;

    _inlineCell = nil;
    [self pausePreview];
}

// scrolled out of view - freeze the game and its clock rather than throwing it away,
// so scrolling back picks up exactly where it left off with no reload.
// NOTE embeddedView is deliberately left pointing at the cell. it is not being drawn
// while paused, and -attachInlineCell: sets it again when the cell comes back.
- (void)pausePreview
{
    if (!_running || _paused || _fullScreen)
        return;

    _paused = YES;
    _pausedRemaining = self.remainingGameTime;

    [_gameTimer invalidate];
    _gameTimer = nil;

    AttractLog(@"PAUSE - preview off screen, %.0fsec left of %@", _pausedRemaining, _currentGame.gameName);
    [EmulatorController.sharedInstance setEmulationPaused:YES];
}

- (void)resumePreview
{
    if (!_paused)
        return;

    _paused = NO;
    AttractLog(@"RESUME - %.0fsec left of %@", _pausedRemaining, _currentGame.gameName);

    [EmulatorController.sharedInstance setEmulationPaused:NO];

    // put the clock back where we left it, so remainingGameTime stays honest
    _gameStartTime = NSDate.timeIntervalSinceReferenceDate - (self.gameDuration - _pausedRemaining);
    [self scheduleGameTimer:_pausedRemaining];
    [self updateChromeForGame:_currentGame duration:_pausedRemaining];
}

- (void)start
{
    if (_running || !self.isEnabled || !_browserVisible)
        return;

    if (![self isBrowserFrontmost]) {
        AttractLog(@"NOT STARTING - something is presented over the ROM browser");
        return [self retryStartLater];
    }

    GameInfo* game = [self nextGameInfo];
    if (game == nil) {
        AttractLog(@"NO GAMES TO SHOW");
        return;
    }

    AttractLog(@"START %@ (\"%@\")%@", game.gameName, game.gameTitle, _fullScreen ? @" FULL SCREEN" : @" INLINE");

    _running = YES;
    _failureCount = 0;
    g_attract_mode = 1;

    if (_fullScreen)
        [self showOverlayForGame:game];

    [self playGame:game];
}

// blow the inline preview up to the whole screen. the game keeps running - changing
// embeddedView just re-parents the screen view, no restart.
- (void)expandToFullScreen
{
    if (_fullScreen)
        return;

    AttractLog(@"EXPAND TO FULL SCREEN");

    if (_paused)
        [self resumePreview];

    _fullScreen = YES;
    _inlineCell = nil;
    [_idleTimer invalidate];
    _idleTimer = nil;

    EmulatorController* emu = EmulatorController.sharedInstance;
    GameInfo* game = _currentGame;
    NSTimeInterval remaining = self.remainingGameTime;

    // if nothing was playing inline (cell offscreen, or just enabled) start one now
    if (!_running) {
        [emu dismissViewControllerAnimated:YES completion:^{
            emu.embeddedView = nil;
            [self start];
        }];
        return;
    }

    [emu dismissViewControllerAnimated:YES completion:^{
        emu.embeddedView = nil;
        [self showOverlayForGame:game];
        [self updateChromeForGame:game duration:remaining];
    }];
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
    [self updateChromeForGame:game duration:self.gameDuration];
    [self playGame:game];
}

- (void)playGame:(GameInfo*)game
{
    _currentGame = game;
    _gameStartTime = NSDate.timeIntervalSinceReferenceDate;

    [self scheduleGameTimer:self.gameDuration];

    AttractLog(@"REQUEST PLAY %@ (%@)", game.gameName, _fullScreen ? @"full screen" : @"inline");

    if (_fullScreen) {
        // routes through the browser's selectGameCallback if it is still up, which
        // dismisses it (saving scroll position) and then boots the game. that callback
        // runs synchronously from here, so the flag covers it.
        _launchingGame = YES;
        [EmulatorController.sharedInstance playGame:game];
        _launchingGame = NO;
    }
    else {
        // leave the ROM browser alone, we are playing into its preview cell
        [EmulatorController.sharedInstance playGameEmbedded:game];
    }
}

// we are being told to move on from inside MAME's own startup, where setting
// myosd_exitGame just gets lost - the emulator is not yet in a state to act on it.
// let the machine finish coming up, then skip.
- (void)skipSoon
{
    [self scheduleGameTimer:ATTRACT_SKIP_DELAY];
}

- (void)scheduleGameTimer:(NSTimeInterval)duration
{
    [_gameTimer invalidate];

    __weak AttractMode* _self = self;
    _gameTimer = [NSTimer scheduledTimerWithTimeInterval:duration repeats:NO block:^(NSTimer* timer) {
        [_self skipToNextGame];
    }];
}

// how much of this game's turn is left, used when moving between inline and full screen
- (NSTimeInterval)remainingGameTime
{
    if (!_running)
        return self.gameDuration;

    NSTimeInterval elapsed = NSDate.timeIntervalSinceReferenceDate - _gameStartTime;
    return MAX(0.5, self.gameDuration - elapsed);
}

// MAME got the machine up - if it turned out to be a broken one, dont sit on it
- (void)attractGameDidStart:(NSString*)name broken:(BOOL)broken
{
    if (!_running)
        return;

    // MAME reports the machine it booted. for software that is the *system* it runs
    // on, not the software itself - dhilchl reports as apple2gs - so either matches.
    BOOL expected = [name isEqualToString:_currentGame.gameName] ||
                    (_currentGame.gameSystem.length != 0 && [name isEqualToString:_currentGame.gameSystem]);

    if (!expected) {
        AttractLog(@"DESYNC - asked for %@ but MAME started %@, moving on", _currentGame.gameName, name);
        return [self skipSoon];
    }

    if (!broken)
        return;

    AttractLog(@"%@ FLAGGED NOT_WORKING BY MAME, SKIPPING", name);
    [_badGames addObject:name];
    [self skipSoon];
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
        [self updateChromeForGame:game duration:self.gameDuration];
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
    BOOL wasFullScreen = _fullScreen;
    [self endAttractSession];

    // coming out of a takeover the browser has to be re-presented, which runExit does
    // by way of MAME returning to the menu. inline, the browser is already up and
    // chooseGame: will just bail, leaving MAME idling in the menu as usual.
    #pragma unused(wasFullScreen)
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
    // MAME cannot see myosd_exitGame while its thread is blocked, so unpause first or
    // -stop would hang waiting for an exit that never gets processed.
    if (_paused) {
        _paused = NO;
        [EmulatorController.sharedInstance setEmulationPaused:NO];
    }

    _running = NO;
    _fullScreen = NO;
    g_attract_mode = 0;
    _currentGame = nil;

    _inlineCell = nil;
    EmulatorController.sharedInstance.embeddedView = nil;

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
    [self updateOverlayForGame:game duration:self.remainingGameTime];

    [UIView animateWithDuration:0.3 animations:^{
        self->_overlay.alpha = 1.0;
    }];
}

// send the current game to whichever chrome is on screen
- (void)updateChromeForGame:(GameInfo*)game duration:(NSTimeInterval)duration
{
    if (game == nil)
        return;

    NSString* title = game.gameTitle.length != 0 ? game.gameTitle : game.gameDescription;

    NSMutableArray* parts = [[NSMutableArray alloc] init];
    if (game.gameYear.length != 0)
        [parts addObject:game.gameYear];
    if (game.gameManufacturer.length != 0)
        [parts addObject:game.gameManufacturer];
    NSString* detail = [parts componentsJoinedByString:@" · "];

    if (_inlineCell != nil) {
        [_inlineCell setGameTitle:title detail:detail];
        [_inlineCell startProgress:duration];
    }

    if (_overlay != nil)
        [self updateOverlayForGame:game duration:duration];
}

- (void)updateOverlayForGame:(GameInfo*)game duration:(NSTimeInterval)duration
{
    _overlay.titleLabel.text = game.gameTitle.length != 0 ? game.gameTitle : game.gameDescription;

    NSMutableArray* parts = [[NSMutableArray alloc] init];
    if (game.gameYear.length != 0)
        [parts addObject:game.gameYear];
    if (game.gameManufacturer.length != 0)
        [parts addObject:game.gameManufacturer];
    _overlay.detailLabel.text = [parts componentsJoinedByString:@" · "];

    [_overlay startProgress:duration];

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
