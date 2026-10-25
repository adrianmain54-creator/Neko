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

// The HTML/CSS/JS UI as a raw string
const char* HTML_UI = R"(
<!DOCTYPE html>
<html>
<head>
<meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
<style>
    * { box-sizing: border-box; user-select: none; -webkit-user-select: none; -webkit-tap-highlight-color: transparent; }
    body {
        margin: 0; padding: 0; background: transparent; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
        display: flex; justify-content: center; align-items: center; height: 100vh; overflow: hidden;
    }
    .window {
        width: 700px; height: 480px; background: rgba(15, 15, 20, 0.95);
        border-radius: 20px; border: 2px solid #bf5af2; display: flex; flex-direction: column;
        box-shadow: 0 10px 30px rgba(0,0,0,0.5); backdrop-filter: blur(10px);
    }
    .header {
        height: 50px; padding: 0 20px; display: flex; justify-content: space-between; align-items: center;
        border-bottom: 1px solid rgba(255,255,255,0.1);
    }
    .title { color: #bf5af2; font-weight: 900; font-size: 24px; letter-spacing: 2px; }
    .close { color: #ff453a; font-size: 24px; cursor: pointer; padding: 5px; font-weight: bold; }
    .content { display: flex; flex: 1; padding: 15px; gap: 15px; }
    .left-panel { flex: 2; display: flex; flex-direction: column; gap: 15px; }
    .right-panel { flex: 1; display: flex; flex-direction: column; gap: 15px; }
    textarea {
        width: 100%; flex: 1; background: #1c1c1e; color: #fff; border: 1px solid #333;
        border-radius: 10px; padding: 10px; font-family: "Courier New", Courier, monospace; font-size: 14px; resize: none; outline: none;
    }
    .console {
        flex: 1; background: #1c1c1e; color: #32d74b; border-radius: 10px; padding: 10px;
        font-family: "Courier New", Courier, monospace; font-size: 12px; overflow-y: auto; border: 1px solid #333;
    }
    .execute-btn {
        height: 50px; background: #bf5af2; color: #000; font-weight: bold; font-size: 16px;
        border: none; border-radius: 10px; cursor: pointer; transition: 0.2s; box-shadow: 0 0 15px rgba(191, 90, 242, 0.4);
    }
    .execute-btn:active { transform: scale(0.98); box-shadow: none; }
</style>
</head>
<body>
    <div class="window">
        <div class="header">
            <div class="title">NEKO</div>
            <div class="close" onclick="closeUI()">✖</div>
        </div>
        <div class="content">
            <div class="left-panel">
                <textarea id="script" placeholder="-- Paste your script here"></textarea>
                <button class="execute-btn" onclick="executeScript()">EXECUTE</button>
            </div>
            <div class="right-panel">
                <div class="console" id="console">[Neko] HTML UI Loaded.<br></div>
            </div>
        </div>
    </div>

    <script>
        function executeScript() {
            var code = document.getElementById('script').value;
            if(!code) return;
            document.getElementById('console').innerHTML += "> Executing...<br>";
            window.webkit.messageHandlers.nekoHandler.postMessage(code);
        }
        function closeUI() {
            window.webkit.messageHandlers.nekoHandler.postMessage("HIDE_UI");
        }
        function logMsg(msg) {
            document.getElementById('console').innerHTML += msg + "<br>";
        }
    </script>
</body>
</html>
)";

@interface NekoUI : UIWindow <WKScriptMessageHandler>
@property (nonatomic, strong) WKWebView *webView;
@property (nonatomic, strong) UIView *triggerView;
@end

@implementation NekoUI

- (instancetype)initWithScene:(UIWindowScene *)scene {
    self = [super initWithWindowScene:scene];
    if (self) {
        self.frame = [UIScreen mainScreen].bounds;
        self.windowLevel = 999999;
        self.backgroundColor = [UIColor clearColor];

        // Invisible Swipe Trigger Area (Left edge)
        self.triggerView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 40, self.bounds.size.height)];
        self.triggerView.backgroundColor = [UIColor clearColor];
        [self addSubview:self.triggerView];
        
        UISwipeGestureRecognizer *swipe = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(showUI)];
        swipe.direction = UISwipeGestureRecognizerDirectionRight;
        [self.triggerView addGestureRecognizer:swipe];

        // Setup WKWebView
        WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
        [config.userContentController addScriptMessageHandler:self name:@"nekoHandler"];
        
        self.webView = [[WKWebView alloc] initWithFrame:self.bounds configuration:config];
        self.webView.backgroundColor = [UIColor clearColor];
        self.webView.opaque = NO;
        self.webView.scrollView.scrollEnabled = NO;
        self.webView.hidden = YES;
        
        NSString *html = [NSString stringWithUTF8String:HTML_UI];
        [self.webView loadHTMLString:html baseURL:nil];
        [self addSubview:self.webView];
    }
    return self;
}

// Touch Logic: Only let the WebView or Trigger capture touches
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (self.webView.hidden) {
        if (CGRectContainsPoint(self.triggerView.frame, point)) {
            return self.triggerView;
        }
        return nil; // Pass to Roblox
    }
    return [super hitTest:point withEvent:event];
}

// Catch messages from JavaScript
- (void)userContentController:(WKUserContentController *)userContentController didReceiveScriptMessage:(WKScriptMessage *)message {
    if (![message.body isKindOfClass:[NSString class]]) return;
    NSString *body = message.body;
    
    if ([body isEqualToString:@"HIDE_UI"]) {
        [self hideUI];
        return;
    }
    
    // Run the script
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        int res = ExecuteScript([body UTF8String]);
        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *log = (res == 0) ? @"[Neko] Success." : @"[Neko] Error.";
            NSString *js = [NSString stringWithFormat:@"logMsg('%@');", log];
            [self.webView evaluateJavaScript:js completionHandler:nil];
        });
    });
}

- (void)showUI {
    self.webView.hidden = NO;
    self.webView.alpha = 0;
    [UIView animateWithDuration:0.3 animations:^{
        self.webView.alpha = 1;
    }];
}

- (void)hideUI {
    [UIView animateWithDuration:0.3 animations:^{
        self.webView.alpha = 0;
    } completion:^(BOOL finished) {
        self.webView.hidden = YES;
    }];
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
