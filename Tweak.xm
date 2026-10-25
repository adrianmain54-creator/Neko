#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include "Neko.h"
#include <dlfcn.h>

static UIColor *g_themeColor;
static int g_themeIndex = 0;
static NSArray *g_themeColors;

#define UI_BG_COLOR [UIColor colorWithWhite:0.05 alpha:0.95]
#define UI_SIDEBAR_COLOR [UIColor colorWithWhite:0.1 alpha:1.0]
#define UI_PANEL_COLOR [UIColor colorWithWhite:0.15 alpha:1.0]

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
@property (nonatomic, strong) UIView *triggerView;
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

- (instancetype)initWithScene:(UIWindowScene *)scene {
    self = [super initWithWindowScene:scene];
    if (self) {
        self.frame = [UIScreen mainScreen].bounds;
        self.windowLevel = 999999;
        self.backgroundColor = [UIColor clearColor];

        g_themeColors = @[
            [UIColor colorWithRed:0.75 green:0.35 blue:0.95 alpha:1.0],
            [UIColor colorWithRed:0.0 green:0.8 blue:1.0 alpha:1.0],
            [UIColor colorWithRed:0.0 green:1.0 blue:0.5 alpha:1.0],
            [UIColor colorWithRed:1.0 green:0.2 blue:0.2 alpha:1.0]
        ];
        g_themeColor = g_themeColors[0];

        // 1. Invisible Trigger Area (Just 30px wide on the far left)
        self.triggerView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 30, self.bounds.size.height)];
        self.triggerView.backgroundColor = [UIColor clearColor];
        [self addSubview:self.triggerView];
        
        UISwipeGestureRecognizer *swipe = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(handleSwipe:)];
        swipe.direction = UISwipeGestureRecognizerDirectionRight;
        [self.triggerView addGestureRecognizer:swipe];

        // 2. Sleek Glowing Chevron (Moved to middle-left, away from menus)
        self.chevronBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        self.chevronBtn.frame = CGRectMake(-5, 350, 35, 100); 
        [self.chevronBtn setTitle:@">" forState:UIControlStateNormal];
        self.chevronBtn.titleLabel.font = [UIFont boldSystemFontOfSize:36];
        self.chevronBtn.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.8];
        self.chevronBtn.layer.cornerRadius = 17.5;
        self.chevronBtn.layer.borderWidth = 2.0;
        [self.chevronBtn addTarget:self action:@selector(showUI) forControlEvents:UIControlEventTouchUpInside];
        self.chevronBtn.hidden = YES;
        [self addSubview:self.chevronBtn];

        // 3. Main Floating UI Container
        self.mainContainer = [[UIView alloc] initWithFrame:CGRectMake(30, 100, 700, 480)];
        self.mainContainer.backgroundColor = UI_BG_COLOR;
        self.mainContainer.layer.cornerRadius = 24;
        self.mainContainer.layer.masksToBounds = YES;
        self.mainContainer.layer.borderWidth = 1.5;
        self.mainContainer.hidden = YES;
        [self addSubview:self.mainContainer];

        self.titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(25, 20, 100, 30)];
        self.titleLabel.text = @"NEKO";
        self.titleLabel.font = [UIFont fontWithName:@"AvenirNext-Heavy" size:26];
        [self.mainContainer addSubview:self.titleLabel];

        UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        closeBtn.frame = CGRectMake(700 - 50, 20, 30, 30);
        [closeBtn setTitle:@"✖" forState:UIControlStateNormal];
        [closeBtn setTitleColor:[UIColor redColor] forState:UIControlStateNormal];
        closeBtn.titleLabel.font = [UIFont boldSystemFontOfSize:20];
        [closeBtn addTarget:self action:@selector(hideUI) forControlEvents:UIControlEventTouchUpInside];
        [self.mainContainer addSubview:closeBtn];

        UIView *sidebar = [[UIView alloc] initWithFrame:CGRectMake(15, 65, 80, 390)];
        sidebar.backgroundColor = UI_SIDEBAR_COLOR;
        sidebar.layer.cornerRadius = 16;
        [self.mainContainer addSubview:sidebar];

        NSArray *icons = @[@"play.fill", @"doc.text.fill", @"folder.fill", @"gearshape.fill"];
        NSArray *labels = @[@"EXEC", @"SCRI", @"SAVED", @"CLA"];
        
        for (int i = 0; i < 4; i++) {
            UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
            btn.frame = CGRectMake(10, 20 + (i * 85), 60, 60);
            btn.layer.cornerRadius = 14;
            
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

        UIView *editorPanel = [[UIView alloc] initWithFrame:CGRectMake(105, 65, 340, 330)];
        editorPanel.backgroundColor = UI_PANEL_COLOR;
        editorPanel.layer.cornerRadius = 16;
        [self.mainContainer addSubview:editorPanel];

        self.editor = [[UITextView alloc] initWithFrame:CGRectMake(15, 15, 310, 300)];
        self.editor.backgroundColor = [UIColor clearColor];
        self.editor.textColor = [UIColor whiteColor];
        self.editor.font = [UIFont fontWithName:@"Menlo" size:13];
        self.editor.autocapitalizationType = UITextAutocapitalizationTypeNone;
        self.editor.autocorrectionType = UITextAutocorrectionTypeNo;
        self.editor.text = @"-- A little space for your next idea.\n\nlocal message = \"Hello, world!\"\n\nlocal function greet(name)\n    print(message .. \" From \" .. name)\nend";
        [editorPanel addSubview:self.editor];

        UIView *consolePanel = [[UIView alloc] initWithFrame:CGRectMake(455, 65, 230, 330)];
        consolePanel.backgroundColor = UI_PANEL_COLOR;
        consolePanel.layer.cornerRadius = 16;
        [self.mainContainer addSubview:consolePanel];

        UILabel *consLabel = [[UILabel alloc] initWithFrame:CGRectMake(15, 10, 200, 20)];
        consLabel.text = @"Console";
        consLabel.textColor = [UIColor lightGrayColor];
        consLabel.font = [UIFont boldSystemFontOfSize:12];
        [consolePanel addSubview:consLabel];

        self.console = [[UITextView alloc] initWithFrame:CGRectMake(10, 35, 210, 285)];
        self.console.backgroundColor = [UIColor clearColor];
        self.console.font = [UIFont fontWithName:@"Menlo" size:11];
        self.console.editable = NO;
        [consolePanel addSubview:self.console];

        UIView *logsPanel = [[UIView alloc] initWithFrame:CGRectMake(105, 405, 340, 50)];
        logsPanel.backgroundColor = UI_PANEL_COLOR;
        logsPanel.layer.cornerRadius = 16;
        [self.mainContainer addSubview:logsPanel];

        self.logsLabel = [[UILabel alloc] initWithFrame:CGRectMake(15, 5, 310, 40)];
        self.logsLabel.text = @"[Logs] Ready.";
        self.logsLabel.textColor = [UIColor lightGrayColor];
        self.logsLabel.font = [UIFont fontWithName:@"Menlo" size:11];
        [logsPanel addSubview:self.logsLabel];

        UILabel *userLabel = [[UILabel alloc] initWithFrame:CGRectMake(455, 415, 230, 30)];
        userLabel.text = @"👤 User: Aoid";
        userLabel.textColor = [UIColor whiteColor];
        userLabel.font = [UIFont boldSystemFontOfSize:14];
        [self.mainContainer addSubview:userLabel];

        UIView *bottomBar = [[UIView alloc] initWithFrame:CGRectMake(105, 470, 580, 50)];
        [self.mainContainer addSubview:bottomBar];

        self.execBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        self.execBtn.frame = CGRectMake(0, 0, 140, 45);
        [self.execBtn setTitle:@"▶ Execute" forState:UIControlStateNormal];
        [self.execBtn setTitleColor:[UIColor blackColor] forState:UIControlStateNormal];
        self.execBtn.titleLabel.font = [UIFont boldSystemFontOfSize:15];
        self.execBtn.layer.cornerRadius = 12;
        [self.execBtn addTarget:self action:@selector(execute) forControlEvents:UIControlEventTouchUpInside];
        [bottomBar addSubview:self.execBtn];

        UIButton *themeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        themeBtn.frame = CGRectMake(150, 0, 100, 45);
        [themeBtn setTitle:@"Theme" forState:UIControlStateNormal];
        [themeBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        themeBtn.backgroundColor = UI_PANEL_COLOR;
        themeBtn.layer.cornerRadius = 12;
        [themeBtn addTarget:self action:@selector(changeTheme) forControlEvents:UIControlEventTouchUpInside];
        [bottomBar addSubview:themeBtn];

        UIButton *resizeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        resizeBtn.frame = CGRectMake(260, 0, 100, 45);
        [resizeBtn setTitle:@"⛶ Resize" forState:UIControlStateNormal];
        [resizeBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        resizeBtn.backgroundColor = UI_PANEL_COLOR;
        resizeBtn.layer.cornerRadius = 12;
        [resizeBtn addTarget:self action:@selector(toggleResize) forControlEvents:UIControlEventTouchUpInside];
        [bottomBar addSubview:resizeBtn];

        [self applyTheme];
    }
    return self;
}

// CRITICAL FIX: This allows you to move in Roblox while the menu is closed!
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (self.mainContainer.hidden) {
        if (!self.chevronBtn.hidden) {
            // If chevron is visible, ONLY the chevron is clickable
            CGPoint chevronPoint = [self.chevronBtn convertPoint:point fromView:self];
            if ([self.chevronBtn pointInside:chevronPoint withEvent:event]) {
                return self.chevronBtn;
            }
        } else {
            // If chevron is hidden, ONLY the 30px left edge is swipeable
            if (CGRectContainsPoint(self.triggerView.frame, point)) {
                return self.triggerView;
            }
        }
        // Everything else passes through to Roblox
        return nil; 
    }
    // If UI is open, interact normally
    return [super hitTest:point withEvent:event];
}

- (void)applyTheme {
    self.mainContainer.layer.borderColor = g_themeColor.CGColor;
    [self.chevronBtn setTitleColor:g_themeColor forState:UIControlStateNormal];
    self.chevronBtn.layer.borderColor = g_themeColor.CGColor;
    self.titleLabel.textColor = g_themeColor;
    self.execBtn.backgroundColor = g_themeColor;
    self.console.textColor = g_themeColor;
    self.sideExecBtn.backgroundColor = [g_themeColor colorWithAlphaComponent:0.25];
    [self.sideExecBtn setTintColor:g_themeColor];
    UILabel *sideLbl = [self.sideExecBtn viewWithTag:100];
    if (sideLbl) sideLbl.textColor = g_themeColor;
}

- (void)handleSwipe:(UISwipeGestureRecognizer *)gesture {
    if (self.mainContainer.hidden) {
        // Show chevron
        self.chevronBtn.hidden = NO;
        self.chevronBtn.alpha = 0;
        [UIView animateWithDuration:0.2 animations:^{ self.chevronBtn.alpha = 1; }];
        
        [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(resetChevron) object:nil];
        [self performSelector:@selector(resetChevron) withObject:nil afterDelay:5.0]; 
    }
}

- (void)resetChevron {
    if (self.mainContainer.hidden) {
        [UIView animateWithDuration:0.2 animations:^{
            self.chevronBtn.alpha = 0;
        } completion:^(BOOL finished) {
            self.chevronBtn.hidden = YES;
        }];
    }
}

- (void)showUI {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(resetChevron) object:nil];
    
    self.mainContainer.hidden = NO;
    self.chevronBtn.hidden = YES;
    
    self.mainContainer.transform = CGAffineTransformMakeScale(0.9, 0.9);
    self.mainContainer.alpha = 0;
    
    [UIView animateWithDuration:0.3 animations:^{
        self.mainContainer.transform = CGAffineTransformIdentity;
        self.mainContainer.alpha = 1;
    }];
}

- (void)hideUI {
    [UIView animateWithDuration:0.2 animations:^{
        self.mainContainer.alpha = 0;
    } completion:^(BOOL finished) {
        self.mainContainer.hidden = YES;
        self.chevronBtn.hidden = YES;
    }];
}

- (void)toggleResize {
    [UIView animateWithDuration:0.4 delay:0 usingSpringWithDamping:0.8 initialSpringVelocity:0.5 options:UIViewAnimationOptionCurveEaseInOut animations:^{
        if (self.isFullScreen) {
            self.mainContainer.frame = CGRectMake(30, 100, 700, 480);
            self.isFullScreen = NO;
        } else {
            self.mainContainer.frame = self.bounds;
            self.isFullScreen = YES;
        }
    } completion:nil];
}

- (void)changeTheme {
    g_themeIndex = (g_themeIndex + 1) % [g_themeColors count];
    g_themeColor = g_themeColors[g_themeIndex];
    [self applyTheme];
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
        int wait_count = 0;
        while (wait_count < 30) {
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
            wait_count++;
            [NSThread sleepForTimeInterval:1.0];
        }
        
        dispatch_async(dispatch_get_main_queue(), ^{
            UIWindowScene *activeScene = nil;
            for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
                if (s.activationState == UISceneActivationStateForegroundActive && [s isKindOfClass:[UIWindowScene class]]) {
                    activeScene = (UIWindowScene *)s;
                    break;
                }
            }
            if (!activeScene) {
                for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
                    if ([s isKindOfClass:[UIWindowScene class]]) {
                        activeScene = (UIWindowScene *)s;
                        break;
                    }
                }
            }
            if (activeScene) {
                g_ui = [[NekoUI alloc] initWithScene:activeScene];
                g_ui.rootViewController = [[UIViewController alloc] init];
                [g_ui makeKeyAndVisible];
            }
        });
    });
}
