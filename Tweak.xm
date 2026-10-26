#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
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

// Simplified HTML just for the drawer content
const char* HTML_UI = R"STR(
<!DOCTYPE html>
<html>
<head>
<meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
<style>
    * { box-sizing: border-box; user-select: none; -webkit-user-select: none; -webkit-tap-highlight-color: transparent; }
    body { margin: 0; padding: 0; background: #17181b; color: #fff; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; display: flex; height: 100vh; overflow: hidden; }
    .sidebar { width: 80px; background: #202226; display: flex; flex-direction: column; align-items: center; padding-top: 20px; border-right: 1px solid #333; }
    .logo { color: #bf5af2; font-weight: 900; font-size: 20px; margin-bottom: 30px; }
    .nav-item { display: flex; flex-direction: column; align-items: center; padding: 15px 0; color: #888; font-size: 10px; font-weight: bold; width: 100%; }
    .nav-item.active { color: #bf5af2; background: rgba(191, 90, 242, 0.1); border-right: 3px solid #bf5af2; }
    .icon { font-size: 20px; margin-bottom: 5px; }
    .main { flex: 1; display: flex; padding: 15px; gap: 15px; }
    .editor-wrapper { flex: 2; display: flex; flex-direction: column; gap: 15px; }
    textarea { flex: 1; background: #1c1c1e; color: #fff; border: 1px solid #333; border-radius: 10px; padding: 10px; font-family: "Courier New", monospace; font-size: 14px; resize: none; outline: none; }
    .exec-btn { height: 50px; background: #bf5af2; color: #000; font-weight: bold; font-size: 16px; border: none; border-radius: 10px; box-shadow: 0 0 15px rgba(191, 90, 242, 0.4); }
    .console-wrapper { flex: 1; display: flex; flex-direction: column; background: #1c1c1e; border: 1px solid #333; border-radius: 10px; overflow: hidden; }
    .console-header { padding: 10px; background: #202226; color: #888; font-size: 12px; font-weight: bold; border-bottom: 1px solid #333; }
    .console { flex: 1; padding: 10px; color: #32d74b; font-family: "Courier New", monospace; font-size: 12px; overflow-y: auto; }
</style>
</head>
<body>
    <div class="sidebar">
        <div class="logo">NEKO</div>
        <div class="nav-item active"><div class="icon">▶</div> EXEC</div>
        <div class="nav-item"><div class="icon">📄</div> SCRI</div>
        <div class="nav-item"><div class="icon">📁</div> SAVED</div>
        <div class="nav-item"><div class="icon">⚙</div> CLA</div>
    </div>
    <div class="main">
        <div class="editor-wrapper">
            <textarea id="script" placeholder="-- Paste script here"></textarea>
            <button class="exec-btn" onclick="executeScript()">EXECUTE</button>
        </div>
        <div class="console-wrapper">
            <div class="console-header">Console</div>
            <div class="console" id="console">[Neko] Ready.<br></div>
        </div>
    </div>
    <script>
        function executeScript() { var code = document.getElementById('script').value; if(!code) return; document.getElementById('console').innerHTML += "> Executing...<br>"; window.webkit.messageHandlers.nekoHandler.postMessage(code); }
        function logMsg(msg) { document.getElementById('console').innerHTML += msg + "<br>"; }
    </script>
</body>
</html>
)STR";

@interface NekoUI : UIWindow <WKScriptMessageHandler>
@property (nonatomic, strong) UIView *mainContainer;
@property (nonatomic, strong) UIView *dragHandle;
@property (nonatomic, strong) WKWebView *webView;
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

        // 1. The Drawer Container (Starts off-screen)
        self.mainContainer = [[UIView alloc] initWithFrame:CGRectMake(-700, 0, 700, self.bounds.size.height)];
        self.mainContainer.backgroundColor = [UIColor clearColor];
        self.mainContainer.layer.shadowColor = [UIColor blackColor].CGColor;
        self.mainContainer.layer.shadowOpacity = 0.5;
        self.mainContainer.layer.shadowRadius = 20;
        [self addSubview:self.mainContainer];

        // 2. The WebView inside the Drawer
        WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
        [config.userContentController addScriptMessageHandler:self name:@"nekoHandler"];
        self.webView = [[WKWebView alloc] initWithFrame:self.mainContainer.bounds configuration:config];
        self.webView.backgroundColor = [UIColor colorWithRed:0.09 green:0.09 blue:0.11 alpha:1.0];
        self.webView.opaque = NO;
        self.webView.scrollView.scrollEnabled = NO;
        NSString *html = [NSString stringWithUTF8String:HTML_UI];
        [self.webView loadHTMLString:html baseURL:nil];
        [self.mainContainer addSubview:self.webView];

        // 3. The Native Drag Handle (Attached to the right edge of the drawer)
        self.dragHandle = [[UIView alloc] initWithFrame:CGRectMake(700, self.bounds.size.height/2 - 75, 45, 150)];
        self.dragHandle.backgroundColor = [UIColor colorWithRed:0.75 green:0.35 blue:0.95 alpha:1.0];
        self.dragHandle.layer.cornerRadius = 22.5;
        self.dragHandle.layer.maskedCorners = kCALayerMaxXMaxYCorner | kCALayerMaxXMinYCorner; // Round right side
        self.dragHandle.layer.borderWidth = 2.0;
        self.dragHandle.layer.borderColor = [UIColor whiteColor].CGColor;
        
        // Add the chevron icon to the handle
        UIImageView *chevron = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right"]];
        chevron.tintColor = [UIColor whiteColor];
        chevron.frame = CGRectMake(10, 55, 25, 40);
        chevron.contentMode = UIViewContentModeScaleAspectFit;
        [self.dragHandle addSubview:chevron];
        
        [self.mainContainer addSubview:self.dragHandle];

        // 4. Native Pan Gesture (Bulletproof)
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
        [self.dragHandle addGestureRecognizer:pan];
    }
    return self;
}

// Only catch touches on the drag handle, pass everything else to Roblox
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (!self.isOpen) {
        // If closed, only the drag handle is touchable
        if (CGRectContainsPoint(self.dragHandle.frame, point)) {
            return self.dragHandle;
        }
        return nil; // Joystick passes through
    }
    // If open, the whole UI is touchable
    return [super hitTest:point withEvent:event];
}

- (void)handlePan:(UIPanGestureRecognizer *)gesture {
    CGPoint translation = [gesture translationInView:self];
    
    // Calculate new X position
    CGFloat baseX = self.isOpen ? 0 : -700;
    CGFloat newX = baseX + translation.x;
    if (newX > 0) newX = 0;
    if (newX < -700) newX = -700;

    if (gesture.state == UIGestureRecognizerStateChanged) {
        self.mainContainer.frame = CGRectMake(newX, 0, 700, self.bounds.size.height);
    } 
    else if (gesture.state == UIGestureRecognizerStateEnded) {
        // If dragged past halfway, snap open
        if (newX > -350) {
            [self openUI];
        } else {
            [self closeUI];
        }
    }
}

- (void)openUI {
    self.isOpen = YES;
    [UIView animateWithDuration:0.3 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        self.mainContainer.frame = CGRectMake(0, 0, 700, self.bounds.size.height);
    } completion:nil];
}

- (void)closeUI {
    self.isOpen = NO;
    [UIView animateWithDuration:0.3 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        self.mainContainer.frame = CGRectMake(-700, 0, 700, self.bounds.size.height);
    } completion:nil];
}

- (void)userContentController:(WKUserContentController *)userContentController didReceiveScriptMessage:(WKScriptMessage *)message {
    if (![message.body isKindOfClass:[NSString class]]) return;
    NSString *body = message.body;
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        int res = ExecuteScript([body UTF8String]);
        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *log = (res == 0) ? @"[Neko] Success." : @"[Neko] Error.";
            NSString *js = [NSString stringWithFormat:@"logMsg('%@');", log];
            [self.webView evaluateJavaScript:js completionHandler:nil];
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
            if (activeScene) {
                g_ui = [[NekoUI alloc] initWithScene:activeScene];
                g_ui.rootViewController = [[UIViewController alloc] init];
                [g_ui makeKeyAndVisible];
            }
        });
    });
}
