//
//  GameList.m
//  MAME4iOS
//

#import "GameList.h"
#import "Options.h"

#if !__has_feature(objc_arc)
#error("This file assumes ARC")
#endif

#define DebugLog 0
#if DebugLog == 0
#define NSLog(...) (void)0
#endif

// keys inside a stored user list
#define kListName           @"name"
#define kListGames          @"games"
#define kListShowInBrowser  @"showInBrowser"

// the Attract Mode list from before Lists existed, migrated once into a real list
#define LEGACY_ATTRACT_LIST_KEY @"AttractModeGames"
#define LEGACY_ATTRACT_LIST_NAME NSLocalizedString(@"My List", @"name given to the pre-Lists Attract Mode list")

@implementation GameList

- (instancetype)initWithName:(NSString*)name isFavorites:(BOOL)isFavorites
{
    self = [super init];
    if (self == nil)
        return nil;

    _name = [name copy];
    _isFavorites = isFavorites;

    return self;
}

#pragma mark - stored user lists

+ (NSArray<NSDictionary*>*)storedLists
{
    [self migrateLegacyAttractList];
    return [NSUserDefaults.standardUserDefaults arrayForKey:GAME_LISTS_KEY] ?: @[];
}

+ (void)setStoredLists:(NSArray<NSDictionary*>*)lists
{
    [NSUserDefaults.standardUserDefaults setObject:lists forKey:GAME_LISTS_KEY];
}

// Attract Mode used to keep a single unnamed list of its own. fold it into a real
// list the first time we look, so nobody loses what they picked.
+ (void)migrateLegacyAttractList
{
    NSArray* legacy = [NSUserDefaults.standardUserDefaults arrayForKey:LEGACY_ATTRACT_LIST_KEY];

    if (legacy.count == 0) {
        // nothing to move, but clear the key so we dont look again
        if (legacy != nil)
            [NSUserDefaults.standardUserDefaults removeObjectForKey:LEGACY_ATTRACT_LIST_KEY];
        return;
    }

    NSLog(@"MIGRATING %d GAMES FROM THE OLD ATTRACT MODE LIST", (int)legacy.count);

    NSMutableArray* lists = [([NSUserDefaults.standardUserDefaults arrayForKey:GAME_LISTS_KEY] ?: @[]) mutableCopy];
    [lists addObject:@{
        kListName: LEGACY_ATTRACT_LIST_NAME,
        kListGames: legacy,
        kListShowInBrowser: @NO,
    }];

    [NSUserDefaults.standardUserDefaults setObject:lists forKey:GAME_LISTS_KEY];
    [NSUserDefaults.standardUserDefaults removeObjectForKey:LEGACY_ATTRACT_LIST_KEY];
}

// index of this list in the stored array, or NSNotFound
- (NSUInteger)storedIndex
{
    NSArray* lists = [GameList storedLists];

    for (NSUInteger i = 0; i < lists.count; i++) {
        if ([lists[i][kListName] isEqualToString:_name])
            return i;
    }
    return NSNotFound;
}

#pragma mark - lookup

+ (GameList*)favorites
{
    return [[GameList alloc] initWithName:FAVORITE_GAMES_TITLE isFavorites:YES];
}

+ (NSArray<GameList*>*)allLists
{
    NSMutableArray* all = [[NSMutableArray alloc] initWithObjects:[self favorites], nil];

    for (NSDictionary* dict in [self storedLists]) {
        NSString* name = dict[kListName];
        if ([name isKindOfClass:[NSString class]] && name.length != 0)
            [all addObject:[[GameList alloc] initWithName:name isFavorites:NO]];
    }

    return all;
}

+ (GameList*)listNamed:(NSString*)name
{
    for (GameList* list in [self allLists]) {
        if ([list.name isEqualToString:name])
            return list;
    }
    return nil;
}

+ (GameList*)createListNamed:(NSString*)name
{
    name = [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];

    if (name.length == 0 || [name isEqualToString:FAVORITE_GAMES_TITLE])
        return nil;

    GameList* existing = [self listNamed:name];
    if (existing != nil)
        return existing;

    NSMutableArray* lists = [[self storedLists] mutableCopy];
    [lists addObject:@{ kListName: name, kListGames: @[], kListShowInBrowser: @NO }];
    [self setStoredLists:lists];

    return [[GameList alloc] initWithName:name isFavorites:NO];
}

+ (void)deleteList:(GameList*)list
{
    if (list == nil || list.isFavorites)
        return;

    NSUInteger index = [list storedIndex];
    if (index == NSNotFound)
        return;

    NSMutableArray* lists = [[self storedLists] mutableCopy];
    [lists removeObjectAtIndex:index];
    [self setStoredLists:lists];
}

- (BOOL)renameTo:(NSString*)name
{
    name = [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];

    if (_isFavorites || name.length == 0 || [name isEqualToString:FAVORITE_GAMES_TITLE])
        return NO;

    if ([name isEqualToString:_name])
        return YES;     // nothing to do, but not a failure

    if ([GameList listNamed:name] != nil)
        return NO;      // already taken

    NSUInteger index = [self storedIndex];
    if (index == NSNotFound)
        return NO;

    NSMutableArray* lists = [[GameList storedLists] mutableCopy];
    NSMutableDictionary* dict = [lists[index] mutableCopy];
    dict[kListName] = name;
    lists[index] = dict;
    [GameList setStoredLists:lists];

    // Attract Mode remembers its source by name, so carry it across or it would
    // quietly fall back to playing at random
    Options* options = [[Options alloc] init];
    if ([options.attractSource isEqualToString:_name]) {
        options.attractSource = name;
        [options saveOptions];
    }

    _name = [name copy];
    return YES;
}

#pragma mark - contents

// the raw gameDictionary array, however this list stores it
- (NSArray<NSDictionary*>*)gameDictionaries
{
    if (_isFavorites)
        return [NSUserDefaults.standardUserDefaults arrayForKey:FAVORITE_GAMES_KEY] ?: @[];

    NSUInteger index = [self storedIndex];
    if (index == NSNotFound)
        return @[];

    NSArray* games = [GameList storedLists][index][kListGames];
    return [games isKindOfClass:[NSArray class]] ? games : @[];
}

- (void)setGameDictionaries:(NSArray<NSDictionary*>*)games
{
    if (_isFavorites) {
        [NSUserDefaults.standardUserDefaults setObject:games forKey:FAVORITE_GAMES_KEY];
        return;
    }

    NSUInteger index = [self storedIndex];
    if (index == NSNotFound)
        return;

    NSMutableArray* lists = [[GameList storedLists] mutableCopy];
    NSMutableDictionary* dict = [lists[index] mutableCopy];
    dict[kListGames] = games;
    lists[index] = dict;
    [GameList setStoredLists:lists];
}

- (NSArray<GameInfo*>*)games
{
    NSMutableArray* games = [[NSMutableArray alloc] init];

    for (NSDictionary* dict in [self gameDictionaries]) {
        if ([dict isKindOfClass:[NSDictionary class]])
            [games addObject:[[GameInfo alloc] initWithDictionary:dict]];
    }

    return games;
}

- (NSUInteger)count
{
    return [self gameDictionaries].count;
}

- (BOOL)containsGame:(GameInfo*)game
{
    return game != nil && [[self gameDictionaries] containsObject:game.gameDictionary];
}

- (void)addGame:(GameInfo*)game
{
    if (game == nil || game.gameName.length == 0)
        return;

    NSMutableArray* games = [[self gameDictionaries] mutableCopy];
    [games removeObject:game.gameDictionary];

    // Favorites has always put the newest first, and the context menu offers "Make
    // First Favorite" on the back of that. user lists read better in the order built.
    if (_isFavorites)
        [games insertObject:game.gameDictionary atIndex:0];
    else
        [games addObject:game.gameDictionary];

    [self setGameDictionaries:games];
}

- (void)removeGame:(GameInfo*)game
{
    if (game == nil)
        return;

    NSMutableArray* games = [[self gameDictionaries] mutableCopy];
    [games removeObject:game.gameDictionary];
    [self setGameDictionaries:games];
}

- (void)removeGameAtIndex:(NSUInteger)index
{
    NSMutableArray* games = [[self gameDictionaries] mutableCopy];

    if (index >= games.count)
        return;

    [games removeObjectAtIndex:index];
    [self setGameDictionaries:games];
}

#pragma mark - browser visibility

- (BOOL)showInBrowser
{
    if (_isFavorites) {
        // Favorites has always had a section, keep it unless turned off
        NSNumber* value = [NSUserDefaults.standardUserDefaults objectForKey:FAVORITE_GAMES_SHOW_KEY];
        return value == nil || value.boolValue;
    }

    NSUInteger index = [self storedIndex];
    if (index == NSNotFound)
        return NO;

    return [[GameList storedLists][index][kListShowInBrowser] boolValue];
}

- (void)setShowInBrowser:(BOOL)show
{
    if (_isFavorites) {
        [NSUserDefaults.standardUserDefaults setBool:show forKey:FAVORITE_GAMES_SHOW_KEY];
        return;
    }

    NSUInteger index = [self storedIndex];
    if (index == NSNotFound)
        return;

    NSMutableArray* lists = [[GameList storedLists] mutableCopy];
    NSMutableDictionary* dict = [lists[index] mutableCopy];
    dict[kListShowInBrowser] = @(show);
    lists[index] = dict;
    [GameList setStoredLists:lists];
}

@end

#pragma mark - Lists screen

@implementation GameListsController
{
    NSArray<GameList*>* _lists;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = NSLocalizedString(@"Lists", @"Settings: the Lists screen");
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    _lists = [GameList allLists];
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return 2;   // the lists, then New List
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return section == 0 ? _lists.count : 1;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell* cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];

    if (indexPath.section == 1) {
        cell.textLabel.text = NSLocalizedString(@"New List…", @"Settings: create a list");
        cell.textLabel.textColor = self.view.tintColor;
        return cell;
    }

    GameList* list = _lists[indexPath.row];
    cell.textLabel.text = list.name;
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%d", (int)list.count];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (indexPath.section == 1)
        return [self promptForNewList];

    GameList* list = _lists[indexPath.row];
    [self.navigationController pushViewController:[[GameListController alloc] initWithList:list] animated:YES];
}

// Favorites is built in, the rest can be swiped away
- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath
{
    return indexPath.section == 0 && !_lists[indexPath.row].isFavorites;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)style forRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (style != UITableViewCellEditingStyleDelete || indexPath.section != 0)
        return;

    [GameList deleteList:_lists[indexPath.row]];
    _lists = [GameList allLists];
    [tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
}

- (void)promptForNewList
{
    UIAlertController* alert = [UIAlertController alertControllerWithTitle:NSLocalizedString(@"New List", @"")
                                                                  message:nil
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField* field) {
        field.placeholder = NSLocalizedString(@"List Name", @"");
    }];

    [alert addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Create", @"") style:UIAlertActionStyleDefault handler:^(UIAlertAction* action) {
        [GameList createListNamed:alert.textFields.firstObject.text ?: @""];
        self->_lists = [GameList allLists];
        [self.tableView reloadData];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Cancel", @"") style:UIAlertActionStyleCancel handler:nil]];

    [self presentViewController:alert animated:YES completion:nil];
}

@end

#pragma mark - one list

@implementation GameListController
{
    GameList* _list;
    NSArray<GameInfo*>* _games;
}

- (instancetype)initWithList:(GameList*)list
{
    self = [super initWithStyle:UITableViewStyleGrouped];
    _list = list;
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = _list.name;
#if TARGET_OS_IOS
    self.navigationItem.rightBarButtonItem = self.editButtonItem;
#endif
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    _games = _list.games;
    [self.tableView reloadData];
}

// 0 = options, 1 = the games, 2 = delete the list
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return _list.isFavorites ? 2 : 3;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    if (section == 0)
        return _list.isFavorites ? 1 : 2;   // Show in Browser, and Rename
    if (section == 1)
        return MAX(_games.count, 1);    // a hint row when empty
    return 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    return section == 1 ? NSLocalizedString(@"Games", @"") : @"";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell* cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];

    if (indexPath.section == 0 && indexPath.row == 1) {
        cell.textLabel.text = NSLocalizedString(@"Rename List…", @"Settings: rename a list");
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return cell;
    }

    if (indexPath.section == 0) {
        cell.textLabel.text = NSLocalizedString(@"Show in ROM Browser", @"Settings: show this list as a section");
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
#if TARGET_OS_IOS
        UISwitch* sw = [[UISwitch alloc] initWithFrame:CGRectZero];
        sw.on = _list.showInBrowser;
        [sw addTarget:self action:@selector(showInBrowserChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
#else
        cell.detailTextLabel.text = _list.showInBrowser ? NSLocalizedString(@"On", @"") : NSLocalizedString(@"Off", @"");
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
#endif
        return cell;
    }

    if (indexPath.section == 2) {
        cell.textLabel.text = NSLocalizedString(@"Delete List", @"");
        cell.textLabel.textColor = UIColor.systemRedColor;
        cell.textLabel.textAlignment = NSTextAlignmentCenter;
        return cell;
    }

    if (_games.count == 0) {
        cell.textLabel.text = NSLocalizedString(@"No games yet", @"");
        cell.textLabel.textColor = UIColor.grayColor;
        cell.detailTextLabel.text = NSLocalizedString(@"Long press a game in the ROM list to add it.", @"");
        cell.detailTextLabel.numberOfLines = 0;
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
    return indexPath.section == 1 && _games.count != 0;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)style forRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (style != UITableViewCellEditingStyleDelete || indexPath.section != 1 || indexPath.row >= _games.count)
        return;

    [_list removeGameAtIndex:indexPath.row];
    _games = _list.games;

    // the empty-state row takes the place of the last real one
    if (_games.count == 0)
        [tableView reloadData];
    else
        [tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (indexPath.section == 0) {
        if (indexPath.row == 1)
            return [self promptForRename];

        // tvOS has no switch, the row itself toggles
        if (TARGET_OS_TV) {
            _list.showInBrowser = !_list.showInBrowser;
            [tableView reloadData];
        }
        return;
    }

    if (indexPath.section == 2)
        return [self confirmDelete];

#if TARGET_OS_TV
    // no swipe to delete on tvOS, selecting a game removes it
    if (indexPath.row < _games.count) {
        [_list removeGameAtIndex:indexPath.row];
        _games = _list.games;
        [tableView reloadData];
    }
#endif
}

- (void)showInBrowserChanged:(UISwitch*)sender
{
    _list.showInBrowser = sender.isOn;
}

- (void)promptForRename
{
    UIAlertController* alert = [UIAlertController alertControllerWithTitle:NSLocalizedString(@"Rename List", @"")
                                                                  message:nil
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField* field) {
        field.text = self->_list.name;
        field.placeholder = NSLocalizedString(@"List Name", @"");
    }];

    [alert addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Rename", @"") style:UIAlertActionStyleDefault handler:^(UIAlertAction* action) {
        NSString* name = alert.textFields.firstObject.text ?: @"";

        if ([self->_list renameTo:name]) {
            self.title = self->_list.name;
            [self.tableView reloadData];
            return;
        }

        UIAlertController* failed = [UIAlertController alertControllerWithTitle:NSLocalizedString(@"Cannot Use That Name", @"")
                                                                       message:NSLocalizedString(@"Another list already has it, or it is empty.", @"")
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [failed addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Ok", @"") style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:failed animated:YES completion:nil];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Cancel", @"") style:UIAlertActionStyleCancel handler:nil]];

    [self presentViewController:alert animated:YES completion:nil];
}

- (void)confirmDelete
{
    NSString* title = [NSString stringWithFormat:NSLocalizedString(@"Delete “%@”?", @""), _list.name];

    UIAlertController* alert = [UIAlertController alertControllerWithTitle:title
                                                                  message:NSLocalizedString(@"The games themselves are not affected.", @"")
                                                           preferredStyle:UIAlertControllerStyleAlert];

    [alert addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Delete", @"") style:UIAlertActionStyleDestructive handler:^(UIAlertAction* action) {
        [GameList deleteList:self->_list];
        [self.navigationController popViewControllerAnimated:YES];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Cancel", @"") style:UIAlertActionStyleCancel handler:nil]];

    [self presentViewController:alert animated:YES completion:nil];
}

@end

#pragma mark - list picker

@implementation GameListPickerController
{
    GameInfo* _game;
    NSArray<GameList*>* _lists;
}

- (instancetype)initWithGame:(GameInfo*)game
{
    self = [super initWithStyle:UITableViewStyleGrouped];
    _game = game;
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];

    self.title = NSLocalizedString(@"Lists", @"");
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                                                          target:self
                                                                                          action:@selector(done)];
#if TARGET_OS_TV
    UITapGestureRecognizer* tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(done)];
    tap.allowedPressTypes = @[@(UIPressTypeMenu)];
    [self.view addGestureRecognizer:tap];
#endif
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self reload];
}

- (void)reload
{
    NSMutableArray* lists = [[NSMutableArray alloc] init];

    // Favorites has its own action in the game menu, with extras this does not need
    for (GameList* list in [GameList allLists]) {
        if (!list.isFavorites)
            [lists addObject:list];
    }

    _lists = lists;
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return 2;   // the lists, then New List
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return section == 0 ? _lists.count : 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    return section == 0 ? (_game.gameTitle ?: @"") : @"";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell* cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];

    if (indexPath.section == 1) {
        cell.textLabel.text = NSLocalizedString(@"New List…", @"Settings: create a list");
        cell.textLabel.textColor = self.view.tintColor;
        return cell;
    }

    GameList* list = _lists[indexPath.row];
    cell.textLabel.text = list.name;
    cell.accessoryType = [list containsGame:_game] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (indexPath.section == 1)
        return [self promptForNewList];

    // toggle in place - the whole point of this screen over an action sheet
    GameList* list = _lists[indexPath.row];

    if ([list containsGame:_game])
        [list removeGame:_game];
    else
        [list addGame:_game];

    [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
}

- (void)promptForNewList
{
    UIAlertController* alert = [UIAlertController alertControllerWithTitle:NSLocalizedString(@"New List", @"")
                                                                  message:nil
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField* field) {
        field.placeholder = NSLocalizedString(@"List Name", @"");
    }];

    [alert addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Create", @"") style:UIAlertActionStyleDefault handler:^(UIAlertAction* action) {
        GameList* list = [GameList createListNamed:alert.textFields.firstObject.text ?: @""];
        [list addGame:self->_game];
        [self reload];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Cancel", @"") style:UIAlertActionStyleCancel handler:nil]];

    [self presentViewController:alert animated:YES completion:nil];
}

- (void)done
{
    void (^didFinish)(void) = self.didFinish;

    [self dismissViewControllerAnimated:YES completion:^{
        if (didFinish != nil)
            didFinish();
    }];
}

@end
