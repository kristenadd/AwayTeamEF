/*
===========================================================================
Elite Force for iOS / iPadOS: the platform layer (sys_platform.h hooks).

  - main(): hands the engine's SDL_main (sys_main.c) to SDL's UIKit app.
  - Game data and saves live in the app's Documents folder, which the Files
    app shows as "On My iPhone/iPad > Elite Force": Documents/baseEF holds the
    .pk3 files (fs_basepath and fs_homepath are both Documents).
  - Sys_PlatformLauncher: a touch start screen before the engine starts. It
    shows whether the game files are there, imports them from a folder or from
    .pk3 files chosen in the Files picker (iCloud Drive, a USB drive, ...), and
    starts Single Player or Holomatch.
  - Sys_Dialog: UIAlertController.
  - The bundled MoltenVK (Frameworks/MoltenVK.framework) is SDL's Vulkan library.

The Mac equivalents are sys_osx.m, sys_osx_data.m and sys_osx_launcher.m.
===========================================================================
*/

#include "../qcommon/q_shared.h"
#include "../qcommon/qcommon.h"
#include "sys_local.h"
#include "sys_platform.h"

#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <stdlib.h>
#include <string.h>
#import <objc/message.h>

// SDL's UIKit entry point (SDL_uikitappdelegate.m); SDL_main is sys_main.c's main(),
// renamed by SDL_main.h. Declared here so this file needs no SDL headers.
typedef int ( *SDL_main_func_t )( int argc, char *argv[] );
extern int SDL_UIKitRunApp( int argc, char *argv[], SDL_main_func_t mainFunction );
extern int SDL_main( int argc, char *argv[] );

int main( int argc, char *argv[] )
{
	return SDL_UIKitRunApp( argc, argv, SDL_main );
}

/*
=================
UIScene lifecycle

Apps built with the iOS 27 SDK must use scenes or they don't launch, and SDL2
predates them: it makes its windows with -initWithFrame: and listens for the
application delegate's activation callbacks. The Info.plist names IOSSceneDelegate
as the scene delegate (UIApplicationSceneManifest, ios/make-app.sh); it keeps the
scene, every UIWindow created without one is attached to it (SDL's included),
and the scene's activation changes are forwarded to SDL's application delegate,
so SDL still sends its SDL_APP_* events (the engine stops rendering in the
background on them, see IN_AndroidLifecycleFilter).
=================
*/
#import <objc/runtime.h>

static UIWindowScene *iosScene;

@interface IOSSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation IOSSceneDelegate

static void IOS_ForwardToApp( SEL sel )
{
	id<UIApplicationDelegate> app = [UIApplication sharedApplication].delegate;

	if ( [app respondsToSelector: sel] )
		( (void (*)( id, SEL, UIApplication * ))objc_msgSend )( app, sel, [UIApplication sharedApplication] );
}

- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options
{
	if ( ![scene isKindOfClass: [UIWindowScene class]] )
		return;
	iosScene = (UIWindowScene *)scene;
	// windows SDL (or anything else) made before the scene existed
	for ( UIWindow *w in [UIApplication sharedApplication].windows ) {
		if ( !w.windowScene )
			w.windowScene = iosScene;
	}
}
- (void)sceneDidDisconnect:(UIScene *)scene { if ( scene == iosScene ) iosScene = nil; }
- (void)sceneWillResignActive:(UIScene *)scene { IOS_ForwardToApp( @selector( applicationWillResignActive: ) ); }
- (void)sceneDidEnterBackground:(UIScene *)scene { IOS_ForwardToApp( @selector( applicationDidEnterBackground: ) ); }
- (void)sceneWillEnterForeground:(UIScene *)scene { IOS_ForwardToApp( @selector( applicationWillEnterForeground: ) ); }
- (void)sceneDidBecomeActive:(UIScene *)scene { IOS_ForwardToApp( @selector( applicationDidBecomeActive: ) ); }

@end

static id ( *iosOrigInitWithFrame )( id, SEL, CGRect );

static id IOS_WindowInitWithFrame( id self, SEL _cmd, CGRect frame )
{
	self = iosOrigInitWithFrame( self, _cmd, frame );
	if ( self && iosScene && ![(UIWindow *)self windowScene] )
		[(UIWindow *)self setWindowScene: iosScene];
	return self;
}

__attribute__(( constructor )) static void IOS_InstallWindowHook( void )
{
	Method m = class_getInstanceMethod( [UIWindow class], @selector( initWithFrame: ) );

	iosOrigInitWithFrame = (id (*)( id, SEL, CGRect ))method_setImplementation( m, (IMP)IOS_WindowInitWithFrame );
}

// the scene connects shortly after launch; UI shown before that would go nowhere
static void IOS_WaitForScene( void )
{
	NSDate *limit = [NSDate dateWithTimeIntervalSinceNow: 10];

	while ( !iosScene && [limit timeIntervalSinceNow] > 0 ) {
		@autoreleasepool {
			[[NSRunLoop currentRunLoop] runMode: NSDefaultRunLoopMode
				beforeDate: [NSDate dateWithTimeIntervalSinceNow: 0.02]];
		}
	}
}

/*
=================
Paths
=================
*/
static NSString *IOS_Documents( void )
{
	NSArray *dirs = NSSearchPathForDirectoriesInDomains( NSDocumentDirectory, NSUserDomainMask, YES );
	return dirs.count ? dirs[0] : [NSHomeDirectory() stringByAppendingPathComponent: @"Documents"];
}

static NSString *IOS_GameDir( void )
{
	return [IOS_Documents() stringByAppendingPathComponent: @BASEGAME];
}

char *Sys_IOSDocumentsPath( void )
{
	static char path[MAX_OSPATH];

	if ( !path[0] ) {
		@autoreleasepool {
			Q_strncpyz( path, [IOS_Documents() fileSystemRepresentation], sizeof( path ) );
		}
	}
	return path;
}

// the .pk3 files in Documents/baseEF, sorted (lower-case names)
static NSArray<NSString *> *IOS_InstalledPaks( void )
{
	NSArray *all = [[NSFileManager defaultManager] contentsOfDirectoryAtPath: IOS_GameDir() error: nil];
	NSMutableArray *paks = [NSMutableArray array];

	for ( NSString *name in all ) {
		if ( [[name pathExtension] caseInsensitiveCompare: @"pk3"] == NSOrderedSame )
			[paks addObject: name];
	}
	[paks sortUsingSelector: @selector( caseInsensitiveCompare: )];
	return paks;
}

static BOOL IOS_HavePak( NSString *name )
{
	for ( NSString *p in IOS_InstalledPaks() ) {
		if ( [p caseInsensitiveCompare: name] == NSOrderedSame )
			return YES;
	}
	return NO;
}

static BOOL IOS_HaveGameData( void )
{
	return IOS_HavePak( @"pak0.pk3" );
}

// Documents/baseEF exists from the first start, with a note, so the folder to fill is
// easy to find in the Files app
static void IOS_PrepareGameDir( void )
{
	NSFileManager *fm = [NSFileManager defaultManager];
	NSString *note = [IOS_GameDir() stringByAppendingPathComponent: @"Put the game's .pk3 files here.txt"];

	[fm createDirectoryAtPath: IOS_GameDir() withIntermediateDirectories: YES attributes: nil error: nil];
	if ( IOS_HaveGameData() )
		[fm removeItemAtPath: note error: nil];	// done with it
	else if ( ![fm fileExistsAtPath: note] ) {
		NSString *text = @"Copy pak0.pk3, pak1.pk3 and pak2.pk3 (and pak3.pk3 / playermaps.pk3 from the "
			"Expansion Pack, if you have them) from the BaseEF folder of your Elite Force installation "
			"into this folder, or use Import Game Files in the app.\n";
		[text writeToFile: note atomically: YES encoding: NSUTF8StringEncoding error: nil];
	}
}

/*
=================
Presenting UIKit while the engine owns the main loop

The engine runs inside SDL_main, called from SDL's application delegate, so a
modal piece of UI is shown by spinning the main run loop until it is done.
=================
*/
static UIWindow *IOS_TopWindow( void )
{
	UIWindow *best = nil;

	for ( UIScene *scene in [UIApplication sharedApplication].connectedScenes ) {
		if ( ![scene isKindOfClass: [UIWindowScene class]] )
			continue;
		for ( UIWindow *w in ( (UIWindowScene *)scene ).windows ) {
			if ( w.isKeyWindow )
				return w;
			if ( !w.hidden && !best )
				best = w;
		}
	}
	if ( best )
		return best;
	for ( UIWindow *w in [UIApplication sharedApplication].windows ) {	// no scenes (SDL2)
		if ( w.isKeyWindow )
			return w;
		if ( !w.hidden && !best )
			best = w;
	}
	return best;
}

static UIViewController *IOS_TopController( UIWindow *w )
{
	UIViewController *vc = w.rootViewController;

	while ( vc.presentedViewController )
		vc = vc.presentedViewController;
	return vc;
}

static void IOS_RunUntil( BOOL ( ^done )( void ) )
{
	while ( !done() ) {
		@autoreleasepool {
			[[NSRunLoop currentRunLoop] runMode: NSDefaultRunLoopMode
				beforeDate: [NSDate dateWithTimeIntervalSinceNow: 0.05]];
		}
	}
}

// a window of our own over SDL's (or before SDL has one)
static UIWindow *IOS_NewWindow( UIViewController *root )
{
	UIWindow *window = nil;

	IOS_WaitForScene();
	if ( iosScene )
		window = [[UIWindow alloc] initWithWindowScene: iosScene];
	if ( !window )
		window = [[UIWindow alloc] initWithFrame: [UIScreen mainScreen].bounds];
	window.windowLevel = UIWindowLevelAlert;
	window.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;	// the black screens read best dark
	window.rootViewController = root;
	window.backgroundColor = [UIColor blackColor];
	[window makeKeyAndVisible];
	return window;
}

/*
=================
Sys_Dialog
=================
*/
@interface IOSDialogController : UIViewController
@end
@implementation IOSDialogController
- (BOOL)prefersStatusBarHidden { return YES; }
@end

dialogResult_t Sys_Dialog( dialogType_t type, const char *message, const char *title )
{
	__block dialogResult_t result = DR_OK;
	__block BOOL answered = NO;

	if ( ![NSThread isMainThread] ) {
		Com_Printf( "%s: %s\n", title, message );
		return ( type == DT_YES_NO ) ? DR_NO : DR_OK;
	}

	@autoreleasepool {
		UIAlertController *alert = [UIAlertController
			alertControllerWithTitle: [NSString stringWithUTF8String: title ? title : ""]
			message: [NSString stringWithUTF8String: message ? message : ""]
			preferredStyle: UIAlertControllerStyleAlert];
		void ( ^answer )( dialogResult_t ) = ^( dialogResult_t r ) { result = r; answered = YES; };
		UIWindow *own = nil, *top;

		switch ( type ) {
			case DT_YES_NO: {
				[alert addAction: [UIAlertAction actionWithTitle: @"No" style: UIAlertActionStyleCancel
					handler: ^( UIAlertAction *a ) { answer( DR_NO ); }]];
				[alert addAction: [UIAlertAction actionWithTitle: @"Yes" style: UIAlertActionStyleDefault
					handler: ^( UIAlertAction *a ) { answer( DR_YES ); }]];
				break;
			}
			case DT_OK_CANCEL: {
				[alert addAction: [UIAlertAction actionWithTitle: @"Cancel" style: UIAlertActionStyleCancel
					handler: ^( UIAlertAction *a ) { answer( DR_CANCEL ); }]];
				[alert addAction: [UIAlertAction actionWithTitle: @"OK" style: UIAlertActionStyleDefault
					handler: ^( UIAlertAction *a ) { answer( DR_OK ); }]];
				break;
			}
			default: {
				[alert addAction: [UIAlertAction actionWithTitle: @"OK" style: UIAlertActionStyleDefault
					handler: ^( UIAlertAction *a ) { answer( DR_OK ); }]];
				break;
			}
		}

		top = IOS_TopWindow();
		if ( !top || !top.rootViewController ) {
			own = IOS_NewWindow( [IOSDialogController new] );
			top = own;
		}
		[IOS_TopController( top ) presentViewController: alert animated: YES completion: nil];
		IOS_RunUntil( ^BOOL { return answered; } );
		own.hidden = YES;
	}
	return result;
}

/*
=================
The start screen
=================
*/
typedef enum { IOS_CHOICE_NONE, IOS_CHOICE_SP, IOS_CHOICE_HM } iosChoice_t;

@interface IOSStartController : UIViewController <UIDocumentPickerDelegate>
@property (nonatomic) iosChoice_t choice;
@property (nonatomic, strong) UILabel *status;
@property (nonatomic, strong) UILabel *help;
@property (nonatomic, strong) UIButton *spButton, *hmButton, *importButton;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic) BOOL copying;
@end

@implementation IOSStartController

- (BOOL)prefersStatusBarHidden { return YES; }
- (BOOL)prefersHomeIndicatorAutoHidden { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }

- (UIButton *)buttonWithTitle:(NSString *)title subtitle:(NSString *)subtitle filled:(BOOL)filled action:(SEL)action
{
	UIButtonConfiguration *c = filled ? [UIButtonConfiguration filledButtonConfiguration]
		: [UIButtonConfiguration grayButtonConfiguration];
	UIButton *b;

	c.title = title;
	c.subtitle = subtitle;
	c.titleAlignment = UIButtonConfigurationTitleAlignmentCenter;
	c.cornerStyle = UIButtonConfigurationCornerStyleLarge;
	c.contentInsets = NSDirectionalEdgeInsetsMake( 14, 20, 14, 20 );
	if ( filled )
		c.baseBackgroundColor = [UIColor colorWithRed: 0.80 green: 0.45 blue: 0.10 alpha: 1.0];	// LCARS amber
	b = [UIButton buttonWithConfiguration: c primaryAction: nil];
	[b addTarget: self action: action forControlEvents: UIControlEventPrimaryActionTriggered];
	b.translatesAutoresizingMaskIntoConstraints = NO;
	return b;
}

- (void)viewDidLoad
{
	[super viewDidLoad];
	self.view.backgroundColor = [UIColor blackColor];

	UILabel *title = [UILabel new];
	title.text = @"Elite Force";
	title.font = [UIFont systemFontOfSize: 44 weight: UIFontWeightHeavy];
	title.textColor = [UIColor colorWithRed: 1.0 green: 0.62 blue: 0.25 alpha: 1.0];
	title.textAlignment = NSTextAlignmentCenter;

	UILabel *subtitle = [UILabel new];
	subtitle.text = @"Away Team Edition for iPhone and iPad";
	subtitle.font = [UIFont systemFontOfSize: 17 weight: UIFontWeightMedium];
	subtitle.textColor = [UIColor colorWithWhite: 0.75 alpha: 1.0];
	subtitle.textAlignment = NSTextAlignmentCenter;

	self.status = [UILabel new];
	self.status.font = [UIFont systemFontOfSize: 15 weight: UIFontWeightSemibold];
	self.status.textAlignment = NSTextAlignmentCenter;
	self.status.numberOfLines = 0;

	self.help = [UILabel new];
	self.help.font = [UIFont systemFontOfSize: 13];
	self.help.textColor = [UIColor colorWithWhite: 0.6 alpha: 1.0];
	self.help.textAlignment = NSTextAlignmentCenter;
	self.help.numberOfLines = 0;

	self.spButton = [self buttonWithTitle: @"Single Player" subtitle: @"The Voyager campaign" filled: YES
		action: @selector( playSP )];
	self.hmButton = [self buttonWithTitle: @"Holomatch" subtitle: @"Multiplayer" filled: YES
		action: @selector( playHM )];
	self.importButton = [self buttonWithTitle: @"Import Game Files…" subtitle: nil filled: NO
		action: @selector( importFiles )];

	UIStackView *play = [[UIStackView alloc] initWithArrangedSubviews: @[ self.spButton, self.hmButton ]];
	play.axis = UILayoutConstraintAxisHorizontal;
	play.spacing = 16;
	play.distribution = UIStackViewDistributionFillEqually;

	self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle: UIActivityIndicatorViewStyleMedium];
	self.spinner.color = [UIColor whiteColor];
	self.spinner.hidesWhenStopped = YES;

	UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:
		@[ title, subtitle, self.status, play, self.importButton, self.spinner, self.help ]];
	stack.axis = UILayoutConstraintAxisVertical;
	stack.spacing = 14;
	stack.alignment = UIStackViewAlignmentFill;
	[stack setCustomSpacing: 4 afterView: title];
	[stack setCustomSpacing: 24 afterView: subtitle];
	stack.translatesAutoresizingMaskIntoConstraints = NO;

	UIScrollView *scroll = [UIScrollView new];
	scroll.translatesAutoresizingMaskIntoConstraints = NO;
	scroll.alwaysBounceVertical = NO;
	[scroll addSubview: stack];
	[self.view addSubview: scroll];

	UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
	NSLayoutConstraint *maxWidth = [stack.widthAnchor constraintLessThanOrEqualToConstant: 560];
	NSLayoutConstraint *fill = [stack.widthAnchor constraintEqualToAnchor: scroll.frameLayoutGuide.widthAnchor constant: -40];
	fill.priority = UILayoutPriorityDefaultHigh;
	NSLayoutConstraint *centerY = [stack.centerYAnchor constraintEqualToAnchor: scroll.frameLayoutGuide.centerYAnchor];
	centerY.priority = UILayoutPriorityDefaultLow;
	[NSLayoutConstraint activateConstraints: @[
		[scroll.leadingAnchor constraintEqualToAnchor: safe.leadingAnchor],
		[scroll.trailingAnchor constraintEqualToAnchor: safe.trailingAnchor],
		[scroll.topAnchor constraintEqualToAnchor: safe.topAnchor],
		[scroll.bottomAnchor constraintEqualToAnchor: safe.bottomAnchor],
		[stack.centerXAnchor constraintEqualToAnchor: scroll.frameLayoutGuide.centerXAnchor],
		maxWidth, fill, centerY,
		[stack.topAnchor constraintGreaterThanOrEqualToAnchor: scroll.contentLayoutGuide.topAnchor constant: 16],
		[stack.bottomAnchor constraintLessThanOrEqualToAnchor: scroll.contentLayoutGuide.bottomAnchor constant: -16],
		[scroll.contentLayoutGuide.heightAnchor constraintGreaterThanOrEqualToAnchor: scroll.frameLayoutGuide.heightAnchor],
		[scroll.contentLayoutGuide.widthAnchor constraintEqualToAnchor: scroll.frameLayoutGuide.widthAnchor],
	]];

	[self refresh];
}

- (void)viewDidAppear:(BOOL)animated
{
	[super viewDidAppear: animated];
	[self refresh];	// files added in the Files app while the start screen was away
}

- (void)refresh
{
	BOOL have = IOS_HaveGameData();
	NSArray *paks = IOS_InstalledPaks();
	BOOL complete = have && IOS_HavePak( @"pak1.pk3" ) && IOS_HavePak( @"pak2.pk3" );

	if ( self.copying )
		return;
	if ( complete ) {
		self.status.text = [NSString stringWithFormat: @"Game files ready: %@%@",
			[paks componentsJoinedByString: @", "],
			IOS_HavePak( @"pak3.pk3" ) ? @"\nExpansion Pack found" : @""];
		self.status.textColor = [UIColor colorWithRed: 0.55 green: 0.85 blue: 0.55 alpha: 1.0];
	} else if ( have ) {
		self.status.text = @"Patch 1.2 files missing: pak1.pk3 and pak2.pk3 are needed too.";
		self.status.textColor = [UIColor colorWithRed: 1.0 green: 0.8 blue: 0.4 alpha: 1.0];
	} else {
		self.status.text = @"No game files yet. You need your own copy of Elite Force (GOG, Steam or CD with patch 1.2).";
		self.status.textColor = [UIColor colorWithRed: 1.0 green: 0.55 blue: 0.45 alpha: 1.0];
	}
	self.help.text = @"Tap Import and choose your game's BaseEF folder (or its .pk3 files), "
		"or copy the .pk3 files into Files ▸ On My iPhone/iPad ▸ Elite Force ▸ baseEF.\n"
		"Play with a game controller (Xbox, PlayStation, Switch Pro or MFi). Menus work by touch. "
		"In play, tap the screen with two fingers (or press Menu) for the menu.";
	self.spButton.enabled = complete;
	self.hmButton.enabled = complete;
	self.importButton.enabled = YES;
}

- (void)playSP { self.choice = IOS_CHOICE_SP; }
- (void)playHM { self.choice = IOS_CHOICE_HM; }

- (void)importFiles
{
	UTType *pk3 = [UTType typeWithFilenameExtension: @"pk3"] ?: UTTypeData;
	UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
		initForOpeningContentTypes: @[ UTTypeFolder, pk3, UTTypeZIP ] asCopy: NO];

	picker.delegate = self;
	picker.allowsMultipleSelection = YES;
	[self presentViewController: picker animated: YES completion: nil];
}

// the .pk3 / .key files to import from what was picked: a folder (its BaseEF subfolder
// when it has one, so the game's install folder works too) or the files themselves
static void IOS_CollectImports( NSURL *url, NSMutableArray<NSURL *> *out )
{
	NSFileManager *fm = [NSFileManager defaultManager];
	NSNumber *isDir = nil;

	[url getResourceValue: &isDir forKey: NSURLIsDirectoryKey error: nil];
	if ( isDir.boolValue ) {
		NSArray<NSURL *> *items = [fm contentsOfDirectoryAtURL: url
			includingPropertiesForKeys: @[ NSURLIsDirectoryKey ] options: 0 error: nil];
		for ( NSURL *u in items ) {
			NSNumber *sub = nil;
			[u getResourceValue: &sub forKey: NSURLIsDirectoryKey error: nil];
			if ( sub.boolValue && [u.lastPathComponent caseInsensitiveCompare: @BASEGAME] == NSOrderedSame ) {
				IOS_CollectImports( u, out );
				return;
			}
		}
		for ( NSURL *u in items ) {
			NSString *ext = u.pathExtension;
			if ( [ext caseInsensitiveCompare: @"pk3"] == NSOrderedSame || [ext caseInsensitiveCompare: @"key"] == NSOrderedSame )
				[out addObject: u];
		}
		return;
	}
	if ( [url.pathExtension caseInsensitiveCompare: @"pk3"] == NSOrderedSame
		|| [url.pathExtension caseInsensitiveCompare: @"key"] == NSOrderedSame )
		[out addObject: url];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls
{
	NSMutableArray<NSURL *> *scoped = [NSMutableArray array];
	NSMutableArray<NSURL *> *files = [NSMutableArray array];

	for ( NSURL *u in urls ) {
		if ( [u startAccessingSecurityScopedResource] )
			[scoped addObject: u];
		IOS_CollectImports( u, files );
	}
	if ( !files.count ) {
		for ( NSURL *u in scoped )
			[u stopAccessingSecurityScopedResource];
		self.status.text = @"No .pk3 files there. Choose the BaseEF folder of your Elite Force installation.";
		self.status.textColor = [UIColor colorWithRed: 1.0 green: 0.55 blue: 0.45 alpha: 1.0];
		return;
	}

	self.copying = YES;
	self.spButton.enabled = self.hmButton.enabled = self.importButton.enabled = NO;
	self.status.textColor = [UIColor whiteColor];
	[self.spinner startAnimating];

	dispatch_async( dispatch_get_global_queue( QOS_CLASS_USER_INITIATED, 0 ), ^{
		NSFileManager *fm = [NSFileManager defaultManager];
		NSString *dest = IOS_GameDir();
		NSMutableArray *failed = [NSMutableArray array];
		NSUInteger i = 0;

		[fm createDirectoryAtPath: dest withIntermediateDirectories: YES attributes: nil error: nil];
		for ( NSURL *src in files ) {
			// lower-case names: the engine looks for pak0.pk3 etc. on a case-sensitive file system
			NSString *name = src.lastPathComponent.lowercaseString;
			NSString *to = [dest stringByAppendingPathComponent: name];
			NSString *tmp = [to stringByAppendingString: @".part"];
			NSError *err = nil;
			NSFileCoordinator *coord = [[NSFileCoordinator alloc] initWithFilePresenter: nil];
			__block BOOL ok = NO;

			i++;
			dispatch_async( dispatch_get_main_queue(), ^{
				self.status.text = [NSString stringWithFormat: @"Copying %@ (%lu of %lu)…",
					name, (unsigned long)i, (unsigned long)files.count];
			} );
			// a file in iCloud Drive may have to be downloaded first: the coordinator waits
			[coord coordinateReadingItemAtURL: src options: NSFileCoordinatorReadingWithoutChanges error: &err
				byAccessor: ^( NSURL *readURL ) {
					NSError *e = nil;
					[fm removeItemAtPath: tmp error: nil];
					if ( [fm copyItemAtPath: readURL.path toPath: tmp error: &e] ) {
						[fm removeItemAtPath: to error: nil];
						ok = [fm moveItemAtPath: tmp toPath: to error: &e];
					}
					if ( !ok )
						[fm removeItemAtPath: tmp error: nil];
				}];
			if ( !ok )
				[failed addObject: name];
		}
		for ( NSURL *u in scoped )
			[u stopAccessingSecurityScopedResource];
		dispatch_async( dispatch_get_main_queue(), ^{
			self.copying = NO;
			[self.spinner stopAnimating];
			[self refresh];
			if ( failed.count ) {
				self.status.text = [NSString stringWithFormat: @"Could not copy %@.",
					[failed componentsJoinedByString: @", "]];
				self.status.textColor = [UIColor colorWithRed: 1.0 green: 0.55 blue: 0.45 alpha: 1.0];
			}
		} );
	} );
}

@end

/*
=================
Platform hooks (sys_platform.h)
=================
*/
static char iosVulkanLibrary[MAX_OSPATH];

void Sys_PlatformPreInit( int argc, char **argv, char *commandLine, int size )
{
	int i;
	qboolean homeSet = qfalse;

	@autoreleasepool {
		NSString *mvk = [[[NSBundle mainBundle] privateFrameworksPath]
			stringByAppendingPathComponent: @"MoltenVK.framework/MoltenVK"];

		// SDL's UIKit Vulkan backend loads this (it would look for libvulkan.dylib)
		if ( [[NSFileManager defaultManager] fileExistsAtPath: mvk] ) {
			Q_strncpyz( iosVulkanLibrary, [mvk fileSystemRepresentation], sizeof( iosVulkanLibrary ) );
			setenv( "SDL_VULKAN_LIBRARY", iosVulkanLibrary, 0 );
		}
		IOS_PrepareGameDir();
	}

	for ( i = 1; i < argc; i++ ) {
		if ( !Q_stricmp( argv[i], "fs_homepath" ) )
			homeSet = qtrue;
	}
	// saves and the config next to the game files, in Documents/baseEF (visible in Files)
	if ( !homeSet )
		Q_strcat( commandLine, size, va( "+set fs_homepath \"%s\" ", Sys_IOSDocumentsPath() ) );
}

qboolean Sys_PlatformLauncher( int argc, char **argv, char *commandLine, int size )
{
	int i;

	// a mode named on the command line (Xcode's scheme arguments) skips the start screen
	for ( i = 1; i < argc; i++ ) {
		if ( !Q_stricmp( argv[i], "com_holomatch" ) && IOS_HaveGameData() )
			return qtrue;
	}

	@autoreleasepool {
		IOSStartController *start = [IOSStartController new];
		UIWindow *window = IOS_NewWindow( start );

		IOS_RunUntil( ^BOOL { return start.choice != IOS_CHOICE_NONE; } );
		Q_strcat( commandLine, size, start.choice == IOS_CHOICE_HM ? "+set com_holomatch 1 " : "+set com_holomatch 0 " );
		window.hidden = YES;
		window.rootViewController = nil;
	}
	return qtrue;
}

const char *Sys_PlatformResolveGameData( int argc, char **argv, qboolean headless )
{
	return NULL;	// DEFAULT_BASEDIR (Documents) is the base path
}

void Sys_PlatformPostInit( void )
{
	Com_Printf( "iOS documents: %s\n", Sys_IOSDocumentsPath() );
	Com_Printf( "  SDL_VULKAN_LIBRARY = %s\n", iosVulkanLibrary[0] ? iosVulkanLibrary : "(not bundled)" );
}

void Sys_PlatformQuitSignals( void ) { }
void Sys_PlatformFrame( void ) { }
void Sys_PlatformQuitToLauncher( void ) { }	// an iOS app has no launcher to go back to: Quit quits
