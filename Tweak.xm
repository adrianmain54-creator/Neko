#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include "Neko.h"
#include <dlfcn.h>

static lua_State* g_L = nullptr;

int ExecuteScript(const char* code) {
    if (!g_L) {
        void* addr = dlsym(RTLD_DEFAULT, "lua_newstate");
        if (addr) g_L = ((lua_State*(*)(void*, void*))addr)(nullptr, nullptr);
    }
    if (!g_L) return -1;

    lua_State* T = lua_newthread(g_L);
    luaL_sandboxthread(T);
    neko_register_api(T);
    neko_install_hooks(T);
    
    if (luau_load(T, "=console", code, strlen(code), 0) != 0) {
        NSString* err = [NSString stringWithUTF8String:lua_tostring(T, -1)];
        [[NSNotificationCenter defaultCenter] postNotificationName:@"NekoLog" object:[NSString stringWithFormat:@"[Syntax] %@", err]];
        return -2;
    }
    if (lua_pcall(T, 0, 0, 0) != 0) {
        NSString* err = [NSString stringWithUTF8String:lua_tostring(T, -1)];
        [[NSNotificationCenter defaultCenter] postNotificationName:@"NekoLog" object:[NSString stringWithFormat:@"[Runtime] %@", err]];
        return -3;
    }
    [[NSNotificationCenter defaultCenter] postNotificationName:@"NekoLog" object:@"[Success] Script executed."];
    return 0;
}

@interface NekoUI : UIWindow <UIDocumentPickerDelegate>
@property (nonatomic, strong) UIVisualEffectView *blurView;
@property (nonatomic, strong) UITextView *consoleView;
@property (nonatomic, strong) UITextView *inputView;
@property (nonatomic, strong) UIButton *invisBtn;
@end

@implementation NekoUI

- (instancetype)init {
    self = [super initWithFrame:CGRectMake(20, 80, 360, 500)];
    if (self) {
        self.windowLevel = UIWindowLevelAlert + 1;
        self.backgroundColor = [UIColor clearColor];
        
        UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleDark];
        self.blurView = [[UIVisualEffectView alloc] initWithEffect:blur];
        self.blurView.frame = self.bounds;
        self.blurView.layer.cornerRadius = 16;
        self.blurView.layer.masksToBounds = YES;
        self.blurView.layer.borderWidth = 1.0;
        self.blurView.layer.borderColor = [UIColor colorWithRed:0.0 green:0.8 blue:1.0 alpha:0.6].CGColor;
        [self addSubview:self.blurView];

        UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 360, 45)];
        header.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.4];
        [self addSubview:header];
        
        UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(15, 12, 200, 20)];
        title.text = @"NEKO";
        title.textColor = [UIColor colorWithRed:0.0 green:0.8 blue:1.0 alpha:1.0];
        title.font = [UIFont fontWithName:@"AvenirNext-Bold" size:14];
        [header addSubview:title];

        UIButton *fileBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        fileBtn.frame = CGRectMake(280, 10, 70, 25);
        [fileBtn setTitle:@"📁 LOAD" forState:UIControlStateNormal];
        [fileBtn setTitleColor:[UIColor cyanColor] forState:UIControlStateNormal];
        fileBtn.titleLabel.font = [UIFont boldSystemFontOfSize:12];
        [fileBtn addTarget:self action:@selector(pickFile) forControlEvents:UIControlEventTouchUpInside];
        [header addSubview:fileBtn];

        UITapGestureRecognizer *hideGesture = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(hideUI)];
        hideGesture.numberOfTapsRequired = 3;
        hideGesture.numberOfTouchesRequired = 3;
        [self addGestureRecognizer:hideGesture];

        self.invisBtn = [UIButton buttonWithType:UIButtonTypeCustom];
        self.invisBtn.frame = CGRectMake(0, 40, 30, 30); 
        [self.invisBtn addTarget:self action:@selector(showUI) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:self.invisBtn];

        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(drag:)];
        [header addGestureRecognizer:pan];

        self.consoleView = [[UITextView alloc] initWithFrame:CGRectMake(15, 55, 330, 120)];
        self.consoleView.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.5];
        self.consoleView.textColor = [UIColor greenColor];
        self.consoleView.font = [UIFont fontWithName:@"Menlo" size:11];
        self.consoleView.editable = NO;
        self.consoleView.layer.cornerRadius = 8;
        self.consoleView.text = @"[Neko] Stealth initialized.\n[System] API ready.\n";
        [self addSubview:self.consoleView];

        self.inputView = [[UITextView alloc] initWithFrame:CGRectMake(15, 185, 330, 250)];
        self.inputView.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.5];
        self.inputView.textColor = [UIColor whiteColor];
        self.inputView.font = [UIFont fontWithName:@"Menlo" size:12];
        self.inputView.layer.cornerRadius = 8;
        self.inputView.autocapitalizationType = UITextAutocapitalizationTypeNone;
        self.inputView.autocorrectionType = UITextAutocorrectionTypeNo;
        self.inputView.keyboardAppearance = UIKeyboardAppearanceDark;
        self.inputView.text = @"-- Paste script or tap LOAD\n";
        [self addSubview:self.inputView];

        UIButton *execBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        execBtn.frame = CGRectMake(15, 445, 330, 40);
        [execBtn setTitle:@"EXECUTE" forState:UIControlStateNormal];
        [execBtn setTitleColor:[UIColor blackColor] forState:UIControlStateNormal];
        execBtn.backgroundColor = [UIColor colorWithRed:0.0 green:0.8 blue:1.0 alpha:1.0];
        execBtn.titleLabel.font = [UIFont fontWithName:@"AvenirNext-Bold" size:14];
        execBtn.layer.cornerRadius = 8;
        [execBtn addTarget:self action:@selector(execute) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:execBtn];

        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(log:) name:@"NekoLog" object:nil];
    }
    return self;
}

- (void)hideUI {
    self.blurView.hidden = YES;
    self.invisBtn.hidden = NO;
}

- (void)showUI {
    self.blurView.hidden = NO;
    self.invisBtn.hidden = YES;
}

- (void)pickFile {
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[@"public.plain-text", @"public.source-code"] inMode:UIDocumentPickerModeImport];
    picker.delegate = self;
    UIViewController *vc = [[UIViewController alloc] init];
    [self.rootViewController presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject;
    NSString *content = [NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:nil];
    if (content) {
        self.inputView.text = content;
        self.consoleView.text = [self.consoleView.text stringByAppendingString:@"\n> Script loaded from Files."];
    }
}

- (void)log:(NSNotification *)n {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.consoleView.text = [self.consoleView.text stringByAppendingFormat:@"\n%@", n.object];
        [self.consoleView scrollRangeToVisible:NSMakeRange([self.consoleView.text length], 0)];
    });
}

- (void)execute {
    NSString *code = self.inputView.text;
    if (code.length == 0 || [code isEqualToString:@"-- Paste script or tap LOAD\n"]) return;
    
    self.consoleView.text = [self.consoleView.text stringByAppendingString:@"\n> Parsing..."];
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        ExecuteScript([code UTF8String]);
    });
}

- (void)drag:(UIPanGestureRecognizer *)p {
    CGPoint t = [p translationInView:self];
    self.center = CGPointMake(self.center.x + t.x, self.center.y + t.y);
    [p setTranslation:CGPointZero inView:self];
}
@end

static NekoUI *g_console = nil;

__attribute__((constructor)) static void init() {
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        while (true) {
            @autoreleasepool {
                Class PlayersClass = NSClassFromString(@"Players");
                if (PlayersClass) {
                    id localPlayer = [[PlayersClass sharedPlayers] performSelector:@selector(LocalPlayer)];
                    if (localPlayer) {
                        id character = [localPlayer performSelector:@selector(Character)];
                        if (character) break; 
                    }
                }
            }
            [NSThread sleepForTimeInterval:2.0];
        }

        sleep(5 + arc4random_uniform(5));

        dispatch_async(dispatch_get_main_queue(), ^{
            g_console = [[NekoUI alloc] init];
            g_console.rootViewController = [[UIViewController alloc] init];
            [g_console makeKeyAndVisible];
        });
    });
}
