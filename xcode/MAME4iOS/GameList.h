//
//  GameList.h
//  MAME4iOS
//
//  A named list of games. Favorites is a built in list that cannot be deleted or
//  renamed - it is backed by the same NSUserDefaults key it always was, so existing
//  favorites survive. Everything else is a user made list.
//
//  Lists can be shown as sections in the ROM browser, and Attract Mode can play from
//  one instead of picking at random.
//

#import <UIKit/UIKit.h>
#import "GameInfo.h"

NS_ASSUME_NONNULL_BEGIN

// user made lists live here, an array of {name, games, showInBrowser}
#define GAME_LISTS_KEY              @"GameLists"
// whether the built in Favorites list is shown in the ROM browser
#define FAVORITE_GAMES_SHOW_KEY     @"FavoriteGamesShowInBrowser"

@interface GameList : NSObject

@property (nonatomic, strong, readonly) NSString* name;

// Favorites cannot be deleted or renamed, and stores into FAVORITE_GAMES_KEY
@property (nonatomic, readonly) BOOL isFavorites;

// show this list as a section in the ROM browser
@property (nonatomic, assign) BOOL showInBrowser;

// the games in the list, in the order they were added (newest first for Favorites,
// matching how Favorites has always behaved)
@property (nonatomic, strong, readonly) NSArray<GameInfo*>* games;
@property (nonatomic, readonly) NSUInteger count;

// Favorites first, then user lists in creation order
+ (NSArray<GameList*>*)allLists;
+ (GameList*)favorites;
+ (nullable GameList*)listNamed:(NSString*)name;

// creates the list if the name is free, otherwise returns the existing one. names are
// trimmed, and an empty or duplicate-of-Favorites name is rejected (returns nil).
+ (nullable GameList*)createListNamed:(NSString*)name;
+ (void)deleteList:(GameList*)list;

// rename, unless this is Favorites. returns NO if the name is empty, is taken, or
// collides with the built in Favorites list.
- (BOOL)renameTo:(NSString*)name;

- (BOOL)containsGame:(GameInfo*)game;
- (void)addGame:(GameInfo*)game;
- (void)removeGame:(GameInfo*)game;
- (void)removeGameAtIndex:(NSUInteger)index;

@end

// the Lists screen in Settings - every list with its count, plus New List
@interface GameListsController : UITableViewController
@end

// one list: its games (swipe to delete), a Show in ROM Browser switch, and Delete
// List for everything except Favorites
@interface GameListController : UITableViewController
- (instancetype)initWithList:(GameList*)list;
@end

NS_ASSUME_NONNULL_END
