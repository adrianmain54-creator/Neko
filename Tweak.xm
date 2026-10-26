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

// Your exact UI design, minus the scrolling logic
const char* HTML_UI = R"STR(
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<style>
:root{--bg:#17181b;--panel:#1c1c1e;--ink:#f1f1f3;--mute:#9a9aa2;--line:#bf5af2}
html,body{height:100%;margin:0;overflow:hidden;background:transparent;color:var(--ink);
font-family:-apple-system,"Segoe UI",Helvetica,Arial,sans-serif;overscroll-behavior:none;user-select:none;}

/* NEKO UI CSS */
.neko-container { display: flex; width: 100%; height: 100%; background: #17181b; color: #fff; }
.neko-sidebar { width: 80px; background: #202226; display: flex; flex-direction: column; align-items: center; padding-top: 20px; border-right: 1px solid #333; }
.neko-logo { color: #bf5af2; font-weight: 900; font-size: 20px; margin-bottom: 30px; }
.neko-nav-item { display: flex; flex-direction: column; align-items: center; padding: 15px 0; color: #888; font-size: 10px; font-weight: bold; width: 100%; cursor: pointer; }
.neko-nav-item.active { color: #bf5af2; background: rgba(191, 90, 242, 0.1); border-right: 3px solid #bf5af2; }
.neko-nav-item .icon { font-size: 20px; margin-bottom: 5px; }
.neko-main { flex: 1; display: flex; padding: 15px; gap: 15px; }
.neko-editor-wrapper { flex: 2; display: flex; flex-direction: column; gap: 15px; }
.neko-editor-wrapper textarea { flex: 1; background: #1c1c1e; color: #fff; border: 1px solid #333; border-radius: 10px; padding: 10px; font-family: "Courier New", monospace; font-size: 14px; resize: none; outline: none; }
.neko-exec-btn { height: 50px; background: #bf5af2; color: #000; font-weight: bold; font-size: 16px; border: none; border-radius: 10px; cursor: pointer; box-shadow: 0 0 15px rgba(191, 90, 242, 0.4); }
.neko-exec-btn:active { transform: scale(0.98); }
.neko-console-wrapper { flex: 1; display: flex; flex-direction: column; background: #1c1c1e; border: 1px solid #333; border-radius: 10px; overflow: hidden; }
.neko-console-header { padding: 10px; background: #202226; color: #888; font-size: 12px; font-weight: bold; border-bottom: 1px solid #333; }
.neko-console { flex: 1; padding: 10px; color: #32d74b; font-family: "Courier New", monospace; font-size: 12px; overflow-y: auto; }
</style>
</head>
<body>
    <div class="neko-container">
        <div class="neko-sidebar">
            <div class="neko-logo">NEKO</div>
            <div class="neko-nav">
                <div class="neko-nav-item active"><div class="icon">▶</div> EXEC</div>
                <div class="neko-nav-item"><div class="icon">📄</div> SCRI</div>
                <div class="neko-nav-item"><div class="icon">📁</div> SAVED</div>
                <div class="neko-nav-item"><div class="icon">⚙</div> CLA</div>
            </div>
        </div>
        <div class="neko-main">
            <div class="neko-editor-wrapper">
                <textarea id="script" placeholder="-- A little space for your next idea."></textarea>
                <button class="neko-exec-btn" onclick="executeScript()">EXECUTE</button>
            </div>
            <div class="neko-console-wrapper">
                <div class="neko-console-header">Console</div>
                <div class="neko-console" id="console">[Neko] Loaded.<br></div>
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
        function logMsg(msg) {
            document.getElementById('console').innerHTML += msg + "<br>";
        }
    </script>
</body>
</html>
)STR";

@interface NekoUI : UIWindow <WKScriptMessageHandler>
@property (nonatomic, strong) WKWebView *webView;
@property (nonatomic, strong) UIView *dragHandle;
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

        // 1. The WebView (Starts off-screen to the left)
        WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
        [config.userContentController addScriptMessageHandler:self name:@"nekoHandler"];
        
        self.webView = [[WKWebView alloc] initWithFrame:CGRectMake(-700, 0, 700, self.bounds.size.height) configuration:config];
        self.webView.backgroundColor = [UIColor colorWithRed:0.09 green:0.09 blue:0.11 alpha:1.0];
        self.webView.opaque = NO;
        self.webView.scrollView.scrollEnabled = NO;
        
        NSString *html = [NSString stringWithUTF8String:HTML_UI];
        [self.webView loadHTMLString:html baseURL:nil];
        [self addSubview:self.webView];

        // 2. The Native Drag Handle (Matches your purple design)
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

        // 3. Native Pan Gesture
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
        [self.dragHandle addGestureRecognizer:pan];
    }
    return self;
}

// THE JOYSTICK FIX: Only intercept the left 50 pixels when closed.
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (!self.isOpen) {
        // If closed, ONLY the drag handle is touchable. Everything else goes to Roblox.
        if (CGRectContainsPoint(self.dragHandle.frame, point)) {
            return self.dragHandle;
        }
        return nil; 
    }
    // If open, the whole WebView is touchable so you can type.
    return self.webView;
}

- (void)handlePan:(UIPanGestureRecognizer *)gesture {
    CGPoint translation = [gesture translationInView:self];
    CGFloat baseX = self.isOpen ? 0 : -700;
    CGFloat newX = baseX + translation.x;
    if (newX > 0) newX = 0;
    if (newX < -700) newX = -700;

    if (gesture.state == UIGestureRecognizerStateChanged) {
        self.webView.frame = CGRectMake(newX, 0, 700, self.bounds.size.height);
    } else if (gesture.state == UIGestureRecognizerStateEnded) {
        if (newX > -350) [self openUI];
        else [self closeUI];
    }
}

- (void)openUI {
    self.isOpen = YES;
    [UIView animateWithDuration:0.3 animations:^{
        self.webView.frame = CGRectMake(0, 0, 700, self.bounds.size.height);
    }];
}

- (void)closeUI {
    self.isOpen = NO;
    [UIView animateWithDuration:0.3 animations:^{
        self.webView.frame = CGRectMake(-700, 0, 700, self.bounds.size.height);
    }];
}

- (void)userContentController:(WKUserContentController *)userContentController didReceiveScriptMessage:(WKScriptMessage *)message {
    if (![message.body isKindOfClass:[NSString class]]) return;
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        int res = ExecuteScript([message.body UTF8String]);
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
