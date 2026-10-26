#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
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
    
    if (luau_load(T, "=console", code, strlen(code), 0) != 0) return -2;
    if (lua_pcall(T, 0, 0, 0) != 0) return -3;
    return 0;
}

@interface NekoUI : UIWindow
@property (nonatomic, strong) UIView *mainContainer;
@property (nonatomic, strong) UIView *dragHandle;
@property (nonatomic, strong) UITextView *editor;
@property (nonatomic, strong) UITextView *console;
@property (nonatomic, assign) BOOL isOpen;
@end

@implementation NekoUI

- (instancetype)initWithScene:(UIWindowScene *)scene {
    self = [super initWithWindowScene:scene];
    if (self) {
        self.frame = [UIScreen mainScreen].bounds;
        self.windowLevel = 999999;
        self.backgroundColor = [UIColor clearColor];
        self.isOpen = NO;

        // 1. The Main Sliding Drawer (Starts off-screen)
        self.mainContainer = [[UIView alloc] initWithFrame:CGRectMake(-800, 0, 800, self.bounds.size.height)];
        self.mainContainer.backgroundColor = [UIColor colorWithRed:0.09 green:0.09 blue:0.11 alpha:1.0];
        [self addSubview:self.mainContainer];

        // --- SIDEBAR ---
        UIView *sidebar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 90, self.bounds.size.height)];
        sidebar.backgroundColor = [UIColor colorWithRed:0.12 green:0.12 blue:0.15 alpha:1.0];
        [self.mainContainer addSubview:sidebar];

        UILabel *logo = [[UILabel alloc] initWithFrame:CGRectMake(0, 40, 90, 30)];
        logo.text = @"NEKO";
        logo.textColor = [UIColor colorWithRed:0.75 green:0.35 blue:0.95 alpha:1.0];
        logo.font = [UIFont fontWithName:@"AvenirNext-Heavy" size:22];
        logo.textAlignment = NSTextAlignmentCenter;
        [sidebar addSubview:logo];

        NSArray *navItems = @[@"▶\nEXEC", @"📄\nSCRI", @"📁\nSAVED", @"⚙\nCLA"];
        for (int i = 0; i < 4; i++) {
            UIView *navItem = [[UIView alloc] initWithFrame:CGRectMake(0, 100 + (i * 90), 90, 70)];
            if (i == 0) {
                navItem.backgroundColor = [UIColor colorWithRed:0.75 green:0.35 blue:0.95 alpha:0.15];
                UIView *indicator = [[UIView alloc] initWithFrame:CGRectMake(87, 0, 3, 70)];
                indicator.backgroundColor = [UIColor colorWithRed:0.75 green:0.35 blue:0.95 alpha:1.0];
                [navItem addSubview:indicator];
            }
            
            UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 90, 70)];
            lbl.text = navItems[i];
            lbl.textColor = (i == 0) ? [UIColor colorWithRed:0.75 green:0.35 blue:0.95 alpha:1.0] : [UIColor grayColor];
            lbl.font = [UIFont boldSystemFontOfSize:12];
            lbl.textAlignment = NSTextAlignmentCenter;
            lbl.numberOfLines = 2;
            [navItem addSubview:lbl];
            [sidebar addSubview:navItem];
        }

        // --- EDITOR PANEL ---
        UIView *editorWrapper = [[UIView alloc] initWithFrame:CGRectMake(110, 20, 420, self.bounds.size.height - 40)];
        editorWrapper.backgroundColor = [UIColor colorWithRed:0.12 green:0.12 blue:0.15 alpha:1.0];
        editorWrapper.layer.cornerRadius = 12;
        [self.mainContainer addSubview:editorWrapper];

        self.editor = [[UITextView alloc] initWithFrame:CGRectMake(15, 15, 390, editorWrapper.bounds.size.height - 90)];
        self.editor.backgroundColor = [UIColor colorWithRed:0.08 green:0.08 blue:0.1 alpha:1.0];
        self.editor.textColor = [UIColor whiteColor];
        self.editor.font = [UIFont fontWithName:@"Menlo" size:14];
        self.editor.text = @"-- A little space for your next idea.";
        self.editor.autocapitalizationType = UITextAutocapitalizationTypeNone;
        self.editor.autocorrectionType = UITextAutocorrectionTypeNo;
        self.editor.layer.cornerRadius = 8;
        self.editor.textContainerInset = UIEdgeInsetsMake(10, 10, 10, 10);
        [editorWrapper addSubview:self.editor];

        UIButton *execBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        execBtn.frame = CGRectMake(15, editorWrapper.bounds.size.height - 65, 390, 50);
        [execBtn setTitle:@"EXECUTE" forState:UIControlStateNormal];
        [execBtn setTitleColor:[UIColor blackColor] forState:UIControlStateNormal];
        execBtn.backgroundColor = [UIColor colorWithRed:0.75 green:0.35 blue:0.95 alpha:1.0];
        execBtn.titleLabel.font = [UIFont boldSystemFontOfSize:18];
        execBtn.layer.cornerRadius = 10;
        [execBtn addTarget:self action:@selector(execute) forControlEvents:UIControlEventTouchUpInside];
        [editorWrapper addSubview:execBtn];

        // --- CONSOLE PANEL ---
        UIView *consoleWrapper = [[UIView alloc] initWithFrame:CGRectMake(545, 20, 240, self.bounds.size.height - 40)];
        consoleWrapper.backgroundColor = [UIColor colorWithRed:0.12 green:0.12 blue:0.15 alpha:1.0];
        consoleWrapper.layer.cornerRadius = 12;
        [self.mainContainer addSubview:consoleWrapper];

        UILabel *consoleHeader = [[UILabel alloc] initWithFrame:CGRectMake(15, 15, 210, 20)];
        consoleHeader.text = @"Console";
        consoleHeader.textColor = [UIColor grayColor];
        consoleHeader.font = [UIFont boldSystemFontOfSize:14];
        [consoleWrapper addSubview:consoleHeader];

        self.console = [[UITextView alloc] initWithFrame:CGRectMake(15, 45, 210, consoleWrapper.bounds.size.height - 60)];
        self.console.backgroundColor = [UIColor colorWithRed:0.08 green:0.08 blue:0.1 alpha:1.0];
        self.console.textColor = [UIColor colorWithRed:0.2 green:0.8 blue:0.3 alpha:1.0];
        self.console.font = [UIFont fontWithName:@"Menlo" size:12];
        self.console.editable = NO;
        self.console.layer.cornerRadius = 8;
        self.console.text = @"[Neko] Loaded.\n";
        self.console.textContainerInset = UIEdgeInsetsMake(10, 10, 10, 10);
        [consoleWrapper addSubview:self.console];

        // 2. The Purple Drag Handle
        self.dragHandle = [[UIView alloc] initWithFrame:CGRectMake(0, self.bounds.size.height/2 - 75, 45, 150)];
        self.dragHandle.backgroundColor = [UIColor colorWithRed:0.75 green:0.35 blue:0.95 alpha:1.0];
        self.dragHandle.layer.cornerRadius = 22.5;
        self.dragHandle.layer.maskedCorners = kCALayerMaxXMaxYCorner | kCALayerMaxXMinYCorner;
        self.dragHandle.layer.shadowColor = [UIColor blackColor].CGColor;
        self.dragHandle.layer.shadowOpacity = 0.3;
        self.dragHandle.layer.shadowOffset = CGSizeMake(5, 0);
        self.dragHandle.layer.shadowRadius = 10;
        
        UIImageView *chevron = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right"]];
        chevron.tintColor = [UIColor whiteColor];
        chevron.frame = CGRectMake(12, 55, 25, 40);
        chevron.contentMode = UIViewContentModeScaleAspectFit;
        [self.dragHandle addSubview:chevron];
        [self addSubview:self.dragHandle];

        // 3. Native Drag Gesture
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
        [self.dragHandle addGestureRecognizer:pan];
    }
    return self;
}

// FIXED TOUCH LOGIC
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (!self.isOpen) {
        // When closed, ONLY the drag handle is clickable. 
        // Everything else (joystick) passes straight to Roblox.
        if (CGRectContainsPoint(self.dragHandle.frame, point)) {
            return self.dragHandle;
        }
        return nil; 
    }
    // When open, the UI is fully interactive so you can type and click.
    return [super hitTest:point withEvent:event];
}

- (void)handlePan:(UIPanGestureRecognizer *)gesture {
    CGPoint translation = [gesture translationInView:self];
    CGFloat baseX = self.isOpen ? 0 : -800;
    CGFloat newX = baseX + translation.x;
    if (newX > 0) newX = 0;
    if (newX < -800) newX = -800;

    if (gesture.state == UIGestureRecognizerStateChanged) {
        self.mainContainer.frame = CGRectMake(newX, 0, 800, self.bounds.size.height);
    } else if (gesture.state == UIGestureRecognizerStateEnded) {
        if (newX > -400) [self openUI];
        else [self closeUI];
    }
}

- (void)openUI {
    self.isOpen = YES;
    [UIView animateWithDuration:0.3 delay:0 usingSpringWithDamping:0.8 initialSpringVelocity:0.5 options:UIViewAnimationOptionCurveEaseOut animations:^{
        self.mainContainer.frame = CGRectMake(0, 0, 800, self.bounds.size.height);
    } completion:nil];
}

- (void)closeUI {
    self.isOpen = NO;
    [UIView animateWithDuration:0.3 delay:0 usingSpringWithDamping:0.8 initialSpringVelocity:0.5 options:UIViewAnimationOptionCurveEaseOut animations:^{
        self.mainContainer.frame = CGRectMake(-800, 0, 800, self.bounds.size.height);
    } completion:nil];
}

- (void)execute {
    NSString *code = self.editor.text;
    if (code.length == 0) return;
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        int res = ExecuteScript([code UTF8String]);
        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *log = (res == 0) ? @"[Neko] Success.\n" : @"[Neko] Error.\n";
            self.console.text = [self.console.text stringByAppendingString:log];
            [self.console scrollRangeToVisible:NSMakeRange([self.console.text length], 0)];
        });
    });
}

@end

static NekoUI *g_ui = nil;

__attribute__((constructor)) static void init() {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIWindowScene *activeScene = nil;
        for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
            if (s.activationState == UISceneActivationStateForegroundActive && [s isKindOfClass:[UIWindowScene class]]) {
                activeScene = (UIWindowScene *)s;
                break;
            }
        }
        if (activeScene) {
            g_ui = [[NekoUI alloc] initWithScene:activeScene];
            g_ui.rootViewController = [[UIViewController alloc] init];
            [g_ui makeKeyAndVisible];
        }
    });
}
