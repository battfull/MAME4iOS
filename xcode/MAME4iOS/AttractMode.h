//
//  AttractMode.h
//  MAME4iOS
//
//  Plays a random game when the user goes idle in the ROM browser, like a real
//  cabinet running its demo loop. Any input takes you back to browsing.
//

#import <UIKit/UIKit.h>
#import "GameInfo.h"

NS_ASSUME_NONNULL_BEGIN

// TRUE while Attract Mode is driving the emulator, read from EmulatorController to
// force -skip_gameinfo, hide the touch controls and HUD, and swallow game errors.
extern int g_attract_mode;


// always-on logging for Attract Mode. NOTE both EmulatorController.m and
// ChooseGameController.m #define NSLog away, so plain NSLog is a no-op there.
void AttractLog(NSString* format, ...) NS_FORMAT_FUNCTION(1,2);

// the collection view cell that hosts the live preview in the ROM browser's
// "Attract Mode" section. `screenContainer` is what the emulator renders into.
@interface AttractModeCell : UICollectionViewCell
@property (nonatomic, readonly) UIView* screenContainer;
- (void)setGameTitle:(nullable NSString*)title detail:(nullable NSString*)detail;
- (void)startProgress:(NSTimeInterval)duration;
- (void)updatePinButton;
@end

// section title (and NSUserDefaults-visible name) for the inline preview
#define ATTRACT_SECTION_TITLE   @"Attract Mode"

// NSUserDefaults key for the user's hand picked Attract Mode games
#define ATTRACT_LIST_KEY        @"AttractModeGames"

// a table of the user's Attract Mode list, with delete. pushed from Settings.
@interface AttractModeListController : UITableViewController
@end

@interface AttractMode : NSObject

@property (class, nonatomic, readonly) AttractMode* shared;

// the Attract Mode switch in Settings. reads and writes Options.attractMode directly
// rather than caching, off by default.
@property (nonatomic, assign, getter=isEnabled) BOOL enabled;

// TRUE while we are playing a game unattended
@property (nonatomic, readonly, getter=isRunning) BOOL running;

// TRUE only for the instant Attract Mode is asking EmulatorController to start one of
// its own games. lets the ROM browser's selectGameCallback tell our launches apart
// from the user tapping a cell - g_attract_mode cannot, it is set the whole time the
// inline preview is playing, which is while the user is browsing.
@property (nonatomic, readonly, getter=isLaunchingGame) BOOL launchingGame;

// the pool of games to draw from, handed over by ChooseGameController
- (void)setGameList:(NSArray<GameInfo*>*)games;

// the user's hand picked list, used instead of a random draw when Settings says so.
// stored the same way as Favorites, an array of gameDictionary in NSUserDefaults.
+ (NSArray<GameInfo*>*)customList;
+ (BOOL)isInCustomList:(GameInfo*)game;
+ (void)setGame:(GameInfo*)game inCustomList:(BOOL)flag;

// pinned means the preview sits at the top of the ROM browser instead of scrolling
// with it, so it never scrolls out of view and never pauses
+ (BOOL)isPinned;
- (void)togglePinned;

// FALSE where a pinned panel would not leave room for the ROM list, ie landscape on a
// phone. the saved preference is kept, we just ignore it and hide the pin button.
@property (nonatomic, assign, getter=isPinningAvailable) BOOL pinningAvailable;

// the preview container changed size (rotation, or the pinned panel being rebuilt) so
// the emulator has to re-fit itself to it
- (void)previewContainerDidResize:(AttractModeCell*)cell;

// drivers MAME flagged NOT_WORKING - these greet you with a red error screen, so they
// never make it into Attract Mode even when the user is not filtering them out
- (void)setNotWorkingGameNames:(NSSet<NSString*>*)names;

// ROM browser lifecycle - the idle countdown only runs while the browser is up
- (void)browserDidAppear;
- (void)browserWillDisappear;

// any user input at all - ends a full screen takeover, leaves the inline preview be
- (void)noteUserActivity;

// re-read the Attract Mode switch from Settings
- (void)reloadOptions;

// the user launched a game themselves - turns Attract Mode off so it does not take
// over again when they return to the browser
- (void)userDidStartGame;

// move on to another random game right now, without waiting out the timer
- (void)skipToNextGame;

// the inline preview cell coming on and off screen. attaching starts the preview,
// detaching stops it so we are not emulating into a view nobody can see.
- (void)attachInlineCell:(AttractModeCell*)cell;
- (void)detachInlineCell:(AttractModeCell*)cell;

// blow the preview up to the whole screen, keeping the game that is already running
- (void)expandToFullScreen;

// end Attract Mode and go back to the ROM browser
- (void)stop;

// end Attract Mode but leave the current game running for the user to play
- (void)keepPlaying;

// called from EmulatorController when the attract game's machine comes up - a machine
// MAME flags as broken is skipped immediately instead of showing its red warning screen
- (void)attractGameDidStart:(NSString*)name broken:(BOOL)broken;

// called from EmulatorController when the attract game errored out or exited on its own
- (void)attractGameDidEnd;

// called from EmulatorController at the end of changeUI, so the overlay stays on top
- (void)didChangeUI;

@end

// a gesture recognizer that never recognizes anything - attach it to the ROM browser
// and it reports every touch to -noteUserActivity without getting in the way.
@interface AttractIdleGestureRecognizer : UIGestureRecognizer
@end

NS_ASSUME_NONNULL_END
