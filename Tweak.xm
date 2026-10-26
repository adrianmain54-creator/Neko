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
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>Swipe UI</title>
<style>
:root{--bg:#17181b;--panel:#1c1c1e;--ink:#f1f1f3;--mute:#9a9aa2;--line:#bf5af2}
html,body{height:100%;margin:0;overflow:hidden;background:transparent;color:var(--ink);
font-family:-apple-system,"Segoe UI",Helvetica,Arial,sans-serif;overscroll-behavior:none}

.main{position:fixed;inset:0;z-index:0;display:flex;align-items:center;justify-content:center;
text-align:center;padding:24px;color:var(--mute);pointer-events:none;}

.track{position:fixed;inset:0;z-index:1;display:flex;direction:rtl;overflow-x:auto;overflow-y:hidden;
scroll-snap-type:x mandatory;scroll-behavior:smooth;overscroll-behavior:none;
-webkit-overflow-scrolling:touch;scrollbar-width:none}
.track::-webkit-scrollbar{display:none}
.track>*{flex:none;direction:ltr;height:100%;box-sizing:border-box}

.spacer{width:100vw;scroll-snap-align:start;scroll-snap-stop:always}

.peek{width:3px;position:relative;scroll-snap-align:end;scroll-snap-stop:always}

.full{width:100vw;background:var(--panel);scroll-snap-align:start;scroll-snap-stop:always}

.handle{position:absolute;left:0;top:50%;width:46px;height:150px;margin-top:-75px;box-sizing:border-box;
background:linear-gradient(160deg,#bf5af2 0%,#8a2be2 50%,#6a0dad 100%);border-radius:0 80px 80px 0/0 75px 75px 0;
box-shadow:0 8px 22px rgba(191,90,242,.45),0 2px 6px rgba(0,0,0,.18),inset 0 1px 0 rgba(255,255,255,.5),inset -3px 0 8px rgba(255,255,255,.14);
display:flex;align-items:center;justify-content:center;-webkit-tap-highlight-color:transparent;transition:transform .15s}
.handle:active{transform:scale(.94)}
.handle svg{width:24px;height:24px;margin-left:-2px;filter:drop-shadow(0 1px 2px rgba(0,0,0,.3));animation:nudge 1.8s ease-in-out infinite}
@keyframes nudge{0%,100%{transform:translateX(0)}50%{transform:translateX(4px)}}
@media (prefers-reduced-motion:reduce){.handle svg{animation:none}}

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

<div class="main"></div>

<div class="track">
  <section class="spacer"></section>

  <section class="peek">
    <a class="handle" href="#full" aria-label="Open full screen">
      <svg viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="3.2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M9 4.5 16.5 12 9 19.5"/></svg>
    </a>
  </section>

  <section class="full" id="full">
    <!-- YOUR NEKO UI GOES HERE -->
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
  </section>
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
    
    // Detect when the user swipes the track to open/close
    var track = document.querySelector('.track');
    track.addEventListener('scroll', function() {
        // If we scrolled past the spacer, the UI is open
        if (track.scrollLeft < 0) {
            window.webkit.messageHandlers.nekoHandler.postMessage("STAGE_OPEN");
        } else {
            window.webkit.messageHandlers.nekoHandler.postMessage("STAGE_CLOSED");
        }
    });
</script>
</body>
</html>
)STR";

@interface NekoUI : UIWindow <WKScriptMessageHandler>
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

        WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
        [config.userContentController addScriptMessageHandler:self name:@"nekoHandler"];
        
        self.webView = [[WKWebView alloc] initWithFrame:self.bounds configuration:config];
        self.webView.backgroundColor = [UIColor clearColor];
        self.webView.opaque = NO;
        self.webView.scrollView.bounces = NO;
        
        NSString *html = [NSString stringWithUTF8String:HTML_UI];
        [self.webView loadHTMLString:html baseURL:nil];
        [self addSubview:self.webView];
    }
    return self;
}

// THIS IS THE MAGIC TOUCH LOGIC
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (!self.isOpen) {
        // When closed, only let touches through on the left 30% of the screen
        if (point.x < self.bounds.size.width * 0.3) {
            return self.webView;
        }
        // Let the right side (joystick) pass through to Roblox
        return nil;
    }
    // When open, the whole screen goes to the WebView (so you can type)
    return self.webView;
}

- (void)userContentController:(WKUserContentController *)userContentController didReceiveScriptMessage:(WKScriptMessage *)message {
    if (![message.body isKindOfClass:[NSString class]]) return;
    NSString *body = message.body;
    
    if ([body isEqualToString:@"STAGE_OPEN"]) {
        self.isOpen = YES;
        return;
    }
    if ([body isEqualToString:@"STAGE_CLOSED"]) {
        self.isOpen = NO;
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
