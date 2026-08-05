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

// NSUserDefaults key for the browser toggle
#define ATTRACT_MODE_KEY    @"AttractMode"

// always-on logging for Attract Mode. NOTE both EmulatorController.m and
// ChooseGameController.m #define NSLog away, so plain NSLog is a no-op there.
void AttractLog(NSString* format, ...) NS_FORMAT_FUNCTION(1,2);

@interface AttractMode : NSObject

@property (class, nonatomic, readonly) AttractMode* shared;

// user toggle, persisted in NSUserDefaults, off by default
@property (nonatomic, assign, getter=isEnabled) BOOL enabled;

// TRUE while we are playing a game unattended
@property (nonatomic, readonly, getter=isRunning) BOOL running;

// the pool of games to draw from, handed over by ChooseGameController
- (void)setGameList:(NSArray<GameInfo*>*)games;

// drivers MAME flagged NOT_WORKING - these greet you with a red error screen, so they
// never make it into Attract Mode even when the user is not filtering them out
- (void)setNotWorkingGameNames:(NSSet<NSString*>*)names;

// ROM browser lifecycle - the idle countdown only runs while the browser is up
- (void)browserDidAppear;
- (void)browserWillDisappear;

// any user input at all - restarts the idle countdown, or ends Attract Mode if running
- (void)noteUserActivity;

// the user launched a game themselves - turns Attract Mode off so it does not take
// over again when they return to the browser
- (void)userDidStartGame;

// move on to another random game right now, without waiting out the timer
- (void)skipToNextGame;

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
