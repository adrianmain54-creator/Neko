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

const char* HTML_UI = R"STR(
<!DOCTYPE html>
<html>
<head>
<meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
<style>
    * { box-sizing: border-box; user-select: none; -webkit-user-select: none; -webkit-tap-highlight-color: transparent; }
    body { margin: 0; padding: 0; background: transparent; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; display: flex; justify-content: center; align-items: center; height: 100vh; overflow: hidden; }
    .window { width: 700px; height: 480px; background: rgba(15, 15, 20, 0.95); border-radius: 0 20px 20px 0; border: 2px solid #bf5af2; border-left: none; display: flex; flex-direction: column; box-shadow: 10px 10px 30px rgba(0,0,0,0.5); backdrop-filter: blur(10px); }
    .header { height: 50px; padding: 0 20px; display: flex; justify-content: space-between; align-items: center; border-bottom: 1px solid rgba(255,255,255,0.1); }
    .title { color: #bf5af2; font-weight: 900; font-size: 24px; letter-spacing: 2px; }
    .close { color: #ff453a; font-size: 24px; cursor: pointer; padding: 5px; font-weight: bold; }
    .content { display: flex; flex: 1; padding: 15px; gap: 15px; }
    .left-panel { flex: 2; display: flex; flex-direction: column; gap: 15px; }
    .right-panel { flex: 1; display: flex; flex-direction: column; gap: 15px; }
    textarea { width: 100%; flex: 1; background: #1c1c1e; color: #fff; border: 1px solid #333; border-radius: 10px; padding: 10px; font-family: "Courier New", monospace; font-size: 14px; resize: none; outline: none; }
    .console { flex: 1; background: #1c1c1e; color: #32d74b; border-radius: 10px; padding: 10px; font-family: "Courier New", monospace; font-size: 12px; overflow-y: auto; border: 1px solid #333; }
    .execute-btn { height: 50px; background: #bf5af2; color: #000; font-weight: bold; font-size: 16px; border: none; border-radius: 10px; cursor: pointer; transition: 0.2s; box-shadow: 0 0 15px rgba(191, 90, 242, 0.4); }
    .execute-btn:active { transform: scale(0.98); }
</style>
</head>
<body>
    <div class="window">
        <div class="header"><div class="title">NEKO</div><div class="close" onclick="closeUI()">X</div></div>
        <div class="content">
            <div class="left-panel"><textarea id="script" placeholder="-- Paste script"></textarea><button class="execute-btn" onclick="executeScript()">EXECUTE</button></div>
            <div class="right-panel"><div class="console" id="console">[Neko] Loaded.<br></div></div>
        </div>
    </div>
    <script>
        function executeScript() { var code = document.getElementById('script').value; if(!code) return; document.getElementById('console').innerHTML += "> Executing...<br>"; window.webkit.messageHandlers.nekoHandler.postMessage(code); }
        function closeUI() { window.webkit.messageHandlers.nekoHandler.postMessage("HIDE_UI"); }
        function logMsg(msg) { document.getElementById('console').innerHTML += msg + "<br>"; }
    </script>
</body>
</html>
)STR";

@interface NekoUI : UIWindow <WKScriptMessageHandler>
@property (nonatomic, strong) WKWebView *webView;
@property (nonatomic, strong) UIView *edgeTrigger;
@property (nonatomic, strong) UIButton *chevronBtn;
@property (nonatomic, assign) BOOL isUIDraggedOut;
@end

@implementation NekoUI

- (instancetype)initWithScene:(UIWindowScene *)scene {
    self = [super initWithWindowScene:scene];
    if (self) {
        self.frame = [UIScreen mainScreen].bounds;
        self.windowLevel = 999999;
        self.backgroundColor = [UIColor clearColor];
        self.isUIDraggedOut = NO;

        // 1. WebView (Starts hidden off-screen left)
        WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
        [config.userContentController addScriptMessageHandler:self name:@"nekoHandler"];
        
        self.webView = [[WKWebView alloc] initWithFrame:CGRectMake(-700, 100, 700, 480) configuration:config];
        self.webView.backgroundColor = [UIColor clearColor];
        self.webView.opaque = NO;
        self.webView.scrollView.scrollEnabled = NO;
        
        NSString *html = [NSString stringWithUTF8String:HTML_UI];
        [self.webView loadHTMLString:html baseURL:nil];
        [self addSubview:self.webView];

        // 2. Edge Trigger (Only the first 30 pixels to keep joystick safe)
        self.edgeTrigger = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 30, self.bounds.size.height)];
        self.edgeTrigger.backgroundColor = [UIColor clearColor];
        [self addSubview:self.edgeTrigger];
        
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
        pan.cancelsTouchesInView = NO; // Allow simultaneous touches (like joystick if it reaches the edge)
        [self.edgeTrigger addGestureRecognizer:pan];

        // 3. Chevron (Starts on the edge)
        self.chevronBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        self.chevronBtn.frame = CGRectMake(0, 300, 50, 120); 
        [self.chevronBtn setTitle:@">" forState:UIControlStateNormal];
        self.chevronBtn.titleLabel.font = [UIFont boldSystemFontOfSize:40];
        self.chevronBtn.backgroundColor = [UIColor colorWithRed:0.75 green:0.35 blue:0.95 alpha:0.95];
        self.chevronBtn.layer.maskedCorners = kCALayerMaxXMaxYCorner | kCALayerMaxXMinYCorner;
        self.chevronBtn.layer.cornerRadius = 15;
        self.chevronBtn.layer.borderWidth = 2.0;
        self.chevronBtn.layer.borderColor = [UIColor whiteColor].CGColor;
        [self.chevronBtn addTarget:self action:@selector(openUIFully) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:self.chevronBtn];
    }
    return self;
}

// Touch Logic: Pass everything to Roblox except the edge trigger and the open UI
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    // If UI is fully open, let the WebView handle touches
    if (self.webView.frame.origin.x == 0) {
        return [super hitTest:point withEvent:event];
    }
    
    // If UI is sliding, catch the touches so the drag continues
    if (self.webView.frame.origin.x > -700 && self.webView.frame.origin.x < 0) {
        return self;
    }

    // If UI is closed: allow touches on chevron or edge trigger, pass everything else to Roblox
    if (CGRectContainsPoint(self.chevronBtn.frame, point)) {
        return self.chevronBtn;
    }
    if (CGRectContainsPoint(self.edgeTrigger.frame, point)) {
        return self.edgeTrigger;
    }
    
    return nil; // Pass joystick and camera touches to the game
}

- (void)handlePan:(UIPanGestureRecognizer *)gesture {
    CGPoint translation = [gesture translationInView:self];
    CGFloat baseX = self.isUIDraggedOut ? 0 : -700;
    CGFloat newX = baseX + translation.x;

    if (gesture.state == UIGestureRecognizerStateChanged) {
        if (newX > 0) newX = 0;
        if (newX < -700) newX = -700;
        
        // Slide the UI
        self.webView.frame = CGRectMake(newX, 100, 700, 480);
        // Keep chevron attached to the edge of the sliding UI
        self.chevronBtn.frame = CGRectMake(newX + 700, 300, 50, 120);
    } 
    else if (gesture.state == UIGestureRecognizerStateEnded) {
        // Snap open if dragged past halfway, otherwise snap closed
        if (newX > -350) {
            [self openUIFully];
        } else {
            [self closeUIFully];
        }
    }
}

- (void)openUIFully {
    self.isUIDraggedOut = YES;
    [UIView animateWithDuration:0.3 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        self.webView.frame = CGRectMake(0, 100, 700, 480);
        self.chevronBtn.frame = CGRectMake(700, 300, 50, 120); // Hide chevron off right
    } completion:nil];
}

- (void)closeUIFully {
    self.isUIDraggedOut = NO;
    [UIView animateWithDuration:0.3 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        self.webView.frame = CGRectMake(-700, 100, 700, 480);
        self.chevronBtn.frame = CGRectMake(0, 300, 50, 120); // Bring chevron to edge
    } completion:nil];
}

- (void)userContentController:(WKUserContentController *)userContentController didReceiveScriptMessage:(WKScriptMessage *)message {
    if (![message.body isKindOfClass:[NSString class]]) return;
    NSString *body = message.body;
    
    if ([body isEqualToString:@"HIDE_UI"]) {
        [self closeUIFully];
        return;
    }
    
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
