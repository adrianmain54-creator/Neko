#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include "Neko.h"
#include <dlfcn.h>

extern lua_State* get_roblox_state();

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
        self.windowLevel = 10000;
        self.backgroundColor = [UIColor clearColor];
        self.isOpen = NO;

        self.mainContainer = [[UIView alloc] initWithFrame:CGRectMake(-800, 0, 800, self.bounds.size.height)];
        self.mainContainer.backgroundColor = [UIColor colorWithRed:0.09 green:0.09 blue:0.11 alpha:1.0];
        [self addSubview:self.mainContainer];

        self.dragHandle = [[UIView alloc] initWithFrame:CGRectMake(0, self.bounds.size.height/2 - 75, 45, 150)];
        self.dragHandle.backgroundColor = [UIColor colorWithRed:0.75 green:0.35 blue:0.95 alpha:1.0];
        self.dragHandle.layer.cornerRadius = 22.5;
        self.dragHandle.layer.maskedCorners = kCALayerMaxXMaxYCorner | kCALayerMaxXMinYCorner;
        self.dragHandle.layer.borderWidth = 2.0;
        self.dragHandle.layer.borderColor = [UIColor whiteColor].CGColor;
        
        UIImageView *chevron = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right"]];
        chevron.tintColor = [UIColor whiteColor];
        chevron.frame = CGRectMake(10, 55, 25, 40);
        chevron.contentMode = UIViewContentModeScaleAspectFit;
        [self.dragHandle addSubview:chevron];
        [self addSubview:self.dragHandle];

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
            navItem.tag = i;
            navItem.userInteractionEnabled = YES;
            UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTabTap:)];
            [navItem addGestureRecognizer:tap];
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
            lbl.userInteractionEnabled = NO;
            [navItem addSubview:lbl];
            [sidebar addSubview:navItem];
        }

        UIView *editorWrapper = [[UIView alloc] initWithFrame:CGRectMake(110, 20, 420, self.bounds.size.height - 40)];
        editorWrapper.backgroundColor = [UIColor colorWithRed:0.12 green:0.12 blue:0.15 alpha:1.0];
        editorWrapper.layer.cornerRadius = 15;
        [self.mainContainer addSubview:editorWrapper];

        self.editor = [[UITextView alloc] initWithFrame:CGRectMake(15, 15, 390, editorWrapper.bounds.size.height - 90)];
        self.editor.backgroundColor = [UIColor colorWithRed:0.08 green:0.08 blue:0.1 alpha:1.0];
        self.editor.textColor = [UIColor whiteColor];
        self.editor.font = [UIFont fontWithName:@"Menlo" size:14];
        self.editor.text = @"print(\"Neko PC-Speed Loaded!\")";
        self.editor.layer.cornerRadius = 9;
        self.editor.textContainerInset = UIEdgeInsetsMake(10, 10, 10, 10);
        [editorWrapper addSubview:self.editor];

        UIButton *execBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        execBtn.frame = CGRectMake(15, editorWrapper.bounds.size.height - 65, 390, 50);
        [execBtn setTitle:@"EXECUTE" forState:UIControlStateNormal];
        [execBtn setTitleColor:[UIColor blackColor] forState:UIControlStateNormal];
        execBtn.backgroundColor = [UIColor colorWithRed:0.75 green:0.35 blue:0.95 alpha:1.0];
        execBtn.titleLabel.font = [UIFont boldSystemFontOfSize:18];
        execBtn.layer.cornerRadius = 9;
        [execBtn addTarget:self action:@selector(execute) forControlEvents:UIControlEventTouchUpInside];
        [editorWrapper addSubview:execBtn];

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
        self.console.backgroundColor = [UIColor colorWithRed:0.23 green:0.08 blue:0.1 alpha:1.0];
        self.console.textColor = [UIColor colorWithRed:1 green:0.8 blue:0.3 alpha:1.0];
        self.console.font = [UIFont fontWithName:@"Menlo" size:10];
        self.console.editable = NO;
        self.console.layer.cornerRadius = 6.5;
        self.console.text = @"[Neko] PC-Speed Engine Ready.\n";
        self.console.textContainerInset = UIEdgeInsetsMake(10, 10, 10, 10);
        [consoleWrapper addSubview:self.console];

        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
        [self.dragHandle addGestureRecognizer:pan];

        UISwipeGestureRecognizer *swipeLeft = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(closeUI)];
        swipeLeft.direction = UISwipeGestureRecognizerDirectionLeft;
        [self.mainContainer addGestureRecognizer:swipeLeft];
    }
    return self;
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (!self.isOpen) {
        if (CGRectContainsPoint(self.dragHandle.frame, point)) return self.dragHandle;
        return nil; 
    }
    return [super hitTest:point withEvent:event];
}

- (void)handleTabTap:(UITapGestureRecognizer *)gesture {
    NSInteger index = gesture.view.tag;
    NSString *tabName = (index == 0) ? @"Execute" : (index == 1) ? @"Scripts" : (index == 2) ? @"Saved" : @"Settings";
    self.console.text = [self.console.text stringByAppendingString:[NSString stringWithFormat:@"\n[Tab] %@", tabName]];
}

- (void)handlePan:(UIPanGestureRecognizer *)gesture {
    CGPoint translation = [gesture translationInView:self];
    CGFloat baseX = self.isOpen ? 0 : -800;
    CGFloat newX = baseX + translation.x;
    if (newX > 0) newX = 0;
    if (newX < -800) newX = -800;
    if (gesture.state == UIGestureRecognizerStateChanged) {
        self.mainContainer.frame = CGRectMake(newX, 0, 800, self.bounds.size.height);
        self.dragHandle.frame = CGRectMake(newX + 800, self.bounds.size.height/2 - 75, 45, 150);
        self.dragHandle.alpha = 1.0 - (newX / -800.0);
    } else if (gesture.state == UIGestureRecognizerStateEnded) {
        if (newX > -400) [self openUI]; else [self closeUI];
    }
}

- (void)openUI {
    self.isOpen = YES;
    [UIView animateWithDuration:0.25 delay:0 usingSpringWithDamping:0.8 initialSpringVelocity:0.8 options:UIViewAnimationOptionCurveEaseOut animations:^{
        self.mainContainer.frame = CGRectMake(0, 0, 800, self.bounds.size.height);
        self.dragHandle.frame = CGRectMake(800, self.bounds.size.height/2 - 75, 45, 150);
        self.dragHandle.alpha = 0.0;
    } completion:nil];
}

- (void)closeUI {
    self.isOpen = NO;
    [UIView animateWithDuration:0.3 delay:0.2 usingSpringWithDamping:0.8 initialSpringVelocity:0.8 options:UIViewAnimationOptionCurveEaseOut animations:^{
        self.mainContainer.frame = CGRectMake(-800, 0, 800, self.bounds.size.height);
        self.dragHandle.frame = CGRectMake(0, self.bounds.size.height/2 - 75, 45, 150);
        self.dragHandle.alpha = 1.0;
    } completion:nil];
}

- (void)execute {
    NSString *code = self.editor.text;
    if (code.length == 0) return;
    self.console.text = [self.console.text stringByAppendingString:@"\n> Executing..."];
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        lua_State* L = get_roblox_state(); 
        if (!L) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.console.text = [self.console.text stringByAppendingString:@"\n[Error] VM not ready yet. Wait 2s."];
            });
            return;
        }

        lua_State* T = lua_newthread(L);
        luaL_sandboxthread(T);
        
        // Copy game and print so scripts work
        lua_getglobal(L, "game");
        lua_setglobal(T, "game");
        lua_getglobal(L, "print");
        lua_setglobal(T, "print");
        lua_getglobal(L, "warn");
        lua_setglobal(T, "warn");

        neko_register_api(T);
        
        NSString *resultMsg = @"";
        
        if (luau_load(T, "=console", code.UTF8String, strlen(code.UTF8String), 0) != 0) {
            const char* err = lua_tostring(T, -1);
            resultMsg = [NSString stringWithFormat:@"\n[Syntax Error] %s", err ? err : "Unknown"];
        } else if (lua_pcall(T, 0, 0, 0) != 0) {
            const char* err = lua_tostring(T, -1);
            resultMsg = [NSString stringWithFormat:@"\n[Runtime Error] %s", err ? err : "Unknown"];
        } else {
            resultMsg = @"\n[Success] Executed in 0.001s!";
        }
        
        dispatch_async(dispatch_get_main_queue(), ^{
            self.console.text = [self.console.text stringByAppendingString:resultMsg];
            [self.console scrollRangeToVisible:NSMakeRange([self.console.text length], 0)];
        });
    });
}

@end

static NekoUI *g_ui = nil;

// INSTANT UI LOADING: Poll every 50ms for the window scene
__attribute__((constructor)) static void init() {
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        UIWindowScene *activeScene = nil;
        while (!activeScene) {
            @autoreleasepool {
                for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
                    if (s.activationState == UISceneActivationStateForegroundActive && [s isKindOfClass:[UIWindowScene class]]) {
                        activeScene = (UIWindowScene *)s;
                        break;
                    }
                }
            }
            if (!activeScene) [NSThread sleepForTimeInterval:0.05];
        }
        
        dispatch_async(dispatch_get_main_queue(), ^{
            g_ui = [[NekoUI alloc] initWithScene:activeScene];
            UIViewController *rootVC = [[UIViewController alloc] init];
            rootVC.view.backgroundColor = [UIColor clearColor];
            rootVC.view.userInteractionEnabled = NO; 
            g_ui.rootViewController = rootVC;
            [g_ui makeKeyAndVisible];
        });
    });
}
