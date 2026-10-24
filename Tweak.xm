#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include "Neko.h"
#include <dlfcn.h>

// --- THEME ENGINE ---
static UIColor *g_themeColor;
static int g_themeIndex = 0;
static NSArray *g_themeColors;

// --- UI COLORS ---
#define UI_BG_COLOR [UIColor colorWithRed:0.08 green:0.06 blue:0.12 alpha:0.85]
#define UI_SIDEBAR_COLOR [UIColor colorWithRed:0.12 green:0.10 blue:0.18 alpha:0.9]
#define UI_PANEL_COLOR [UIColor colorWithRed:0.15 green:0.13 blue:0.22 alpha:0.8]

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
    
    if (luau_load(T, "=console", code, strlen(code), 0) != 0) return -2;
    if (lua_pcall(T, 0, 0, 0) != 0) return -3;
    return 0;
}

@interface NekoUI : UIWindow <UIDocumentPickerDelegate>
@property (nonatomic, strong) UIVisualEffectView *blurView;
@property (nonatomic, strong) UIView *mainContainer;
@property (nonatomic, strong) UITextView *editor;
@property (nonatomic, strong) UITextView *console;
@property (nonatomic, strong) UILabel *logsLabel;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UIButton *chevronBtn;
@property (nonatomic, strong) UIButton *execBtn;
@property (nonatomic, strong) UIButton *sideExecBtn;
@property (nonatomic, assign) BOOL isFullScreen;
@end

@implementation NekoUI

- (instancetype)init {
    self = [super initWithFrame:CGRectMake(30, 100, 700, 480)];
    if (self) {
        self.windowLevel = UIWindowLevelAlert + 1;
        self.backgroundColor = [UIColor clearColor];
        self.layer.cornerRadius = 20;
        self.layer.masksToBounds = YES;
        self.layer.borderWidth = 1.5;

        g_themeColors = @[
            [UIColor colorWithRed:0.75 green:0.35 blue:0.95 alpha:1.0],
            [UIColor colorWithRed:0.0 green:0.8 blue:1.0 alpha:1.0],
            [UIColor colorWithRed:0.2 green:0.4 blue:1.0 alpha:1.0],
            [UIColor colorWithRed:0.0 green:1.0 blue:0.5 alpha:1.0],
            [UIColor colorWithRed:1.0 green:0.2 blue:0.2 alpha:1.0],
            [UIColor colorWithRed:1.0 green:0.4 blue:0.8 alpha:1.0],
            [UIColor colorWithRed:1.0 green:0.8 blue:0.2 alpha:1.0]
        ];
        g_themeColor = g_themeColors[0];

        UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleDark];
        self.blurView = [[UIVisualEffectView alloc] initWithEffect:blur];
        self.blurView.frame = self.bounds;
        self.blurView.backgroundColor = UI_BG_COLOR;
        [self addSubview:self.blurView];

        self.chevronBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        self.chevronBtn.frame = CGRectMake(0, 200, 30, 50);
        [self.chevronBtn setTitle:@">" forState:UIControlStateNormal];
        self.chevronBtn.titleLabel.font = [UIFont boldSystemFontOfSize:24];
        self.chevronBtn.backgroundColor = UI_BG_COLOR;
        [self.chevronBtn addTarget:self action:@selector(showUI) forControlEvents:UIControlEventTouchUpInside];
        self.chevronBtn.hidden = YES;
        [self addSubview:self.chevronBtn];

        self.mainContainer = [[UIView alloc] initWithFrame:self.bounds];
        self.mainContainer.hidden = YES;
        [self addSubview:self.mainContainer];

        self.titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 15, 100, 30)];
        self.titleLabel.text = @"NEKO";
        self.titleLabel.font = [UIFont fontWithName:@"AvenirNext-Heavy" size:24];
        [self.mainContainer addSubview:self.titleLabel];

        UIView *sidebar = [[UIView alloc] initWithFrame:CGRectMake(10, 60, 80, 400)];
        sidebar.backgroundColor = UI_SIDEBAR_COLOR;
        sidebar.layer.cornerRadius = 15;
        [self.mainContainer addSubview:sidebar];

        NSArray *icons = @[@"play.fill", @"doc.text.fill", @"folder.fill", @"gearshape.fill"];
        NSArray *labels = @[@"EXEC", @"SCRI", @"SAVED", @"CLA"];
        
        for (int i = 0; i < 4; i++) {
            UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
            btn.frame = CGRectMake(10, 20 + (i * 70), 60, 60);
            btn.layer.cornerRadius = 12;
            
            UIImage *icon = [UIImage systemImageNamed:icons[i]];
            [btn setImage:icon forState:UIControlStateNormal];
            
            UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(0, 40, 60, 15)];
            lbl.text = labels[i];
            lbl.font = [UIFont boldSystemFontOfSize:9];
            lbl.textAlignment = NSTextAlignmentCenter;
            lbl.tag = 100 + i;
            [btn addSubview:lbl];
            
            if (i == 0) {
                self.sideExecBtn = btn;
            } else {
                btn.backgroundColor = [UIColor clearColor];
                [btn setTintColor:[UIColor grayColor]];
                lbl.textColor = [UIColor grayColor];
            }
            [sidebar addSubview:btn];
        }

        UIView *editorPanel = [[UIView alloc] initWithFrame:CGRectMake(100, 60, 340, 340)];
        editorPanel.backgroundColor = UI_PANEL_COLOR;
        editorPanel.layer.cornerRadius = 15;
        [self.mainContainer addSubview:editorPanel];

        self.editor = [[UITextView alloc] initWithFrame:CGRectMake(10, 10, 320, 320)];
        self.editor.backgroundColor = [UIColor clearColor];
        self.editor.textColor = [UIColor whiteColor];
        self.editor.font = [UIFont fontWithName:@"Menlo" size:12];
        self.editor.autocapitalizationType = UITextAutocapitalizationTypeNone;
        self.editor.autocorrectionType = UITextAutocorrectionTypeNo;
        self.editor.text = @"-- A little space for your next idea.\n\nlocal message = \"Hello, world!\"\n\nlocal function greet(name)\n    print(message .. \" From \" .. name)\nend";
        [editorPanel addSubview:self.editor];

        UIView *consolePanel = [[UIView alloc] initWithFrame:CGRectMake(450, 60, 240, 340)];
        consolePanel.backgroundColor = UI_PANEL_COLOR;
        consolePanel.layer.cornerRadius = 15;
        [self.mainContainer addSubview:consolePanel];

        UILabel *consLabel = [[UILabel alloc] initWithFrame:CGRectMake(15, 10, 200, 20)];
        consLabel.text = @"Console";
        consLabel.textColor = [UIColor lightGrayColor];
        consLabel.font = [UIFont boldSystemFontOfSize:12];
        [consolePanel addSubview:consLabel];

        self.console = [[UITextView alloc] initWithFrame:CGRectMake(10, 35, 220, 295)];
        self.console.backgroundColor = [UIColor clearColor];
        self.console.font = [UIFont fontWithName:@"Menlo" size:11];
        self.console.editable = NO;
        [consolePanel addSubview:self.console];

        UIView *logsPanel = [[UIView alloc] initWithFrame:CGRectMake(100, 410, 340, 60)];
        logsPanel.backgroundColor = UI_PANEL_COLOR;
        logsPanel.layer.cornerRadius = 15;
        [self.mainContainer addSubview:logsPanel];

        self.logsLabel = [[UILabel alloc] initWithFrame:CGRectMake(15, 10, 310, 40)];
        self.logsLabel.text = @"[Logs] Ready.";
        self.logsLabel.textColor = [UIColor lightGrayColor];
        self.logsLabel.font = [UIFont fontWithName:@"Menlo" size:11];
        [logsPanel addSubview:self.logsLabel];

        UILabel *userLabel = [[UILabel alloc] initWithFrame:CGRectMake(450, 430, 240, 20)];
        userLabel.text = @"👤 User: Aoid";
        userLabel.textColor = [UIColor whiteColor];
        userLabel.font = [UIFont boldSystemFontOfSize:13];
        [self.mainContainer addSubview:userLabel];

        UIView *bottomBar = [[UIView alloc] initWithFrame:CGRectMake(100, 480, 590, 50)];
        [self.mainContainer addSubview:bottomBar];

        self.execBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        self.execBtn.frame = CGRectMake(0, 0, 130, 40);
        [self.execBtn setTitle:@"▶ Execute" forState:UIControlStateNormal];
        [self.execBtn setTitleColor:[UIColor blackColor] forState:UIControlStateNormal];
        self.execBtn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
        self.execBtn.layer.cornerRadius = 10;
        [self.execBtn addTarget:self action:@selector(execute) forControlEvents:UIControlEventTouchUpInside];
        [bottomBar addSubview:self.execBtn];

        UIButton *fpsBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        fpsBtn.frame = CGRectMake(140, 0, 100, 40);
        [fpsBtn setTitle:@"FPS Boost" forState:UIControlStateNormal];
        [fpsBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        fpsBtn.backgroundColor = UI_PANEL_COLOR;
        fpsBtn.layer.cornerRadius = 10;
        [fpsBtn addTarget:self action:@selector(runFPS) forControlEvents:UIControlEventTouchUpInside];
        [bottomBar addSubview:fpsBtn];

        UIButton *themeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        themeBtn.frame = CGRectMake(250, 0, 100, 40);
        [themeBtn setTitle:@"Theme" forState:UIControlStateNormal];
        [themeBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        themeBtn.backgroundColor = UI_PANEL_COLOR;
        themeBtn.layer.cornerRadius = 10;
        [themeBtn addTarget:self action:@selector(changeTheme) forControlEvents:UIControlEventTouchUpInside];
        [bottomBar addSubview:themeBtn];

        UIButton *resizeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        resizeBtn.frame = CGRectMake(360, 0, 100, 40);
        [resizeBtn setTitle:@"⛶ Resize" forState:UIControlStateNormal];
        [resizeBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        resizeBtn.backgroundColor = UI_PANEL_COLOR;
        resizeBtn.layer.cornerRadius = 10;
        [resizeBtn addTarget:self action:@selector(toggleResize) forControlEvents:UIControlEventTouchUpInside];
        [bottomBar addSubview:resizeBtn];

        UISwipeGestureRecognizer *swipe = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(handleSwipe:)];
        swipe.direction = UISwipeGestureRecognizerDirectionLeft;
        [self addGestureRecognizer:swipe];

        [self applyTheme];
    }
    return self;
}

- (void)applyTheme {
    self.layer.borderColor = g_themeColor.CGColor;
    [self.chevronBtn setTitleColor:g_themeColor forState:UIControlStateNormal];
    self.titleLabel.textColor = g_themeColor;
    self.execBtn.backgroundColor = g_themeColor;
    self.console.textColor = g_themeColor;
    self.sideExecBtn.backgroundColor = [g_themeColor colorWithAlphaComponent:0.3];
    [self.sideExecBtn setTintColor:g_themeColor];
    UILabel *sideLbl = [self.sideExecBtn viewWithTag:100];
    if (sideLbl) sideLbl.textColor = g_themeColor;
}

- (void)handleSwipe:(UISwipeGestureRecognizer *)gesture {
    if (self.mainContainer.hidden) {
        self.chevronBtn.hidden = NO;
        self.chevronBtn.alpha = 0;
        [UIView animateWithDuration:0.2 animations:^{ self.chevronBtn.alpha = 1; }];
    }
}

- (void)showUI {
    self.mainContainer.hidden = NO;
    self.chevronBtn.hidden = YES;
    self.mainContainer.alpha = 0;
    [UIView animateWithDuration:0.3 animations:^{ self.mainContainer.alpha = 1; }];
}

- (void)toggleResize {
    if (self.isFullScreen) {
        self.frame = CGRectMake(30, 100, 700, 480);
        self.blurView.frame = self.bounds;
        self.mainContainer.frame = self.bounds;
        self.isFullScreen = NO;
    } else {
        self.frame = [UIScreen mainScreen].bounds;
        self.blurView.frame = self.bounds;
        self.mainContainer.frame = self.bounds;
        self.isFullScreen = YES;
    }
}

- (void)changeTheme {
    g_themeIndex = (g_themeIndex + 1) % [g_themeColors count];
    g_themeColor = g_themeColors[g_themeIndex];
    [self applyTheme];
}

- (void)runFPS {
    NSString *script = @"local Lighting = game:GetService('Lighting'); Lighting.GlobalShadows = false; for _,v in pairs(game:GetDescendants()) do if v:IsA('BasePart') then v.Material = Enum.Material.SmoothPlastic; v.Reflectance = 0; end end; print('FPS Optimized.');";
    ExecuteScript([script UTF8String]);
    self.logsLabel.text = @"[Logs] FPS Optimized.";
}

- (void)execute {
    NSString *code = self.editor.text;
    if (code.length == 0) return;
    self.logsLabel.text = @"[Logs] Executing...";
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        int res = ExecuteScript([code UTF8String]);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (res == 0) {
                self.console.text = [self.console.text stringByAppendingString:@"\n> Success."];
                self.logsLabel.text = @"[Logs] Executed successfully.";
            } else {
                self.console.text = [self.console.text stringByAppendingString:@"\n> Error."];
                self.logsLabel.text = @"[Logs] Execution failed.";
            }
        });
    });
}

@end

static NekoUI *g_ui = nil;

__attribute__((constructor)) static void init() {
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        while (true) {
            @autoreleasepool {
                Class PlayersClass = NSClassFromString(@"Players");
                if (PlayersClass) {
                    id sharedPlayers = [PlayersClass performSelector:@selector(sharedPlayers)];
                    if (sharedPlayers) {
                        id localPlayer = [sharedPlayers performSelector:@selector(LocalPlayer)];
                        if (localPlayer) {
                            id character = [localPlayer performSelector:@selector(Character)];
                            if (character) break; 
                        }
                    }
                }
            }
            [NSThread sleepForTimeInterval:2.0];
        }
        sleep(5);
        dispatch_async(dispatch_get_main_queue(), ^{
            g_ui = [[NekoUI alloc] init];
            g_ui.rootViewController = [[UIViewController alloc] init];
            [g_ui makeKeyAndVisible];
        });
    });
}
