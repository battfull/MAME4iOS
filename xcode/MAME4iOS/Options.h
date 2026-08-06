//
//  Options.h
//  MAME4iOS
//
//  Created by Yoshi Sugawara on 1/12/19.
//  Copyright © 2019 Seleuco. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface Options : NSObject

- (void)loadOptions;
- (void)saveOptions;
+ (void)resetOptions;
+ (void)setOption:(id)value forKey:(NSString*)key;

// compare two Options, but only the specified keys
- (BOOL)isEqualToOptions:(Options*)other withKeys:(NSArray<NSString*>*)keys;

@property (class, readonly, strong) NSString* optionsFile;

@property (class, readonly, strong) NSArray* arrayEmuSpeed;
@property (class, readonly, strong) NSArray* arrayAttractDuration;
// Random followed by every list, rebuilt each time since lists come and go
@property (class, readonly, strong) NSArray* arrayAttractSource;
#define ATTRACT_SOURCE_RANDOM   @"Random"
@property (class, readonly, strong) NSArray* arrayControlType;
@property (class, readonly, strong) NSArray* arraySoundValue;
@property (class, readonly, strong) NSArray* arraySkin;
@property (class, readonly, strong) NSArray* arrayFilter;
@property (class, readonly, strong) NSArray* arrayScreenShader;
@property (class, readonly, strong) NSArray* arrayLineShader;

@property (readwrite,assign) int keepAspectRatio;

@property (readwrite,strong) NSString *filter;
@property (readwrite,strong) NSString *skin;
@property (readwrite,strong) NSString *screenShader;
@property (readwrite,strong) NSString *lineShader;

@property (readwrite,assign) int integerScalingOnly;

@property (readwrite,assign) int showFPS;
@property (readwrite,assign) int showHUD;
@property (readwrite,assign) int animatedButtons;
@property (readwrite,assign) int fullscreenLandscape;
@property (readwrite,assign) int fullscreenPortrait;
@property (readwrite,assign) int fullscreenJoystick;

@property (readwrite,assign) int touchtype;
@property (readwrite,assign) int analogDeadZoneValue;

@property (readwrite,assign) int controltype;
@property (readwrite,assign) int showINFO;

@property (readwrite,assign) int soundValue;

@property (readwrite,assign) int sticktype;
@property (readwrite,assign) int numbuttons;
@property (readwrite,assign) int aplusb;
@property (readwrite,assign) int cheats;

@property (readwrite,assign) int forcepxa;
@property (readwrite,assign) int p1aspx;

@property (readwrite,assign) int filterClones;
@property (readwrite,assign) int filterNotWorking;
@property (readwrite,assign) int filterBIOS;

@property (readwrite,assign) int autofire;
@property (readwrite,assign) int hiscore;

@property (readwrite,assign) int buttonSize;
@property (readwrite,assign) int stickSize;
@property (readwrite,assign) int nintendoBAYX;

@property (readwrite,assign) int vbean2x;
@property (readwrite,assign) int vflicker;

@property (readwrite,assign) int emuspeed;

@property (readwrite,assign) int lightgunBottomScreenReload;
@property (readwrite,assign) int lightgunEnabled;

@property (readwrite,assign) int turboXEnabled;
@property (readwrite,assign) int turboYEnabled;
@property (readwrite,assign) int turboAEnabled;
@property (readwrite,assign) int turboBEnabled;
@property (readwrite,assign) int turboLEnabled;
@property (readwrite,assign) int turboREnabled;

@property (readwrite,assign) int touchAnalogEnabled;
@property (readwrite,assign) CGFloat touchAnalogSensitivity;
@property (readwrite,assign) int touchAnalogHideTouchDirectionalPad;
@property (readwrite,assign) int touchAnalogHideTouchButtons;

@property (readwrite,assign) int touchDirectionalEnabled;

@property (readwrite,assign) CGFloat touchControlsOpacity;

@property (readwrite,assign) int hapticButtonFeedback;

@property (readwrite,assign) int useDRC;

@property (readwrite,assign) int hideTestROMs;

// Attract Mode: on/off, where it draws games from (index into arrayAttractSource),
// and how long each game plays (index into arrayAttractDuration)
@property (readwrite,assign) int attractMode;
// where Attract Mode draws games from - ATTRACT_SOURCE_RANDOM or a GameList name
@property (readwrite,strong) NSString* attractSource;
@property (readwrite,assign) int attractDuration;

// skip games in the Adult category when Attract Mode picks at random
@property (readwrite,assign) int attractHideAdult;

// keep the Attract Mode preview stuck to the top of the ROM browser
@property (readwrite,assign) int attractPinned;

@end

@interface NSArray (optionAtIndex)
// a "safe" version of objectAtIndex
- (id)objectAtIndex:(NSUInteger)index withDefault:(nullable id)defaultObject;
// return the option at index, or default to the first one
- (NSString*)optionAtIndex:(NSUInteger)index;
// find and return option name given a string, default to first if not found
- (NSString*)optionFind:(NSString*)string;
// return a localized display name for the option at index (for UI display only)
- (NSString*)localizedOptionAtIndex:(NSUInteger)index;
// return a localized display name for a specific option string (for UI display only)
- (NSString*)localizedNameForOption:(NSString*)option;
@end


NS_ASSUME_NONNULL_END
