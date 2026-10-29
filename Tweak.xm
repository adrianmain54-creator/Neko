#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#include "Neko.h"
#include <dlfcn.h>
#include "dobby.h"

typedef lua_State* (*newstate_fn)(lua_Alloc, void*);
static newstate_fn real_newstate = nullptr;

static lua_State* hooked_newstate(lua_Alloc f, void* ud) {
    lua_State* L = real_newstate(f, ud);
    if (!neko_get_state()) {
        neko_set_state(L);
        neko_install_hooks(L);
    }
    return L;
}

// Anti-scan string obfuscation for "lua_newstate"
static void* get_lua_newstate() {
    char s[13] = {'l','u','a','_','n','e','w','s','t','a','t','e','\0'};
    return dlsym(RTLD_DEFAULT, s);
}

__attribute__((constructor)) static void hook_init() {
    void* addr = get_lua_newstate();
    if (addr) {
        real_newstate = (newstate_fn)addr;
        DobbyHook(addr, (void*)hooked_newstate, (void**)&real_newstate);
    }
}

@interface NekoUI : UIWindow <WKScriptMessageHandler>
@property (nonatomic, strong) WKWebView *webView;
@property (nonatomic, assign) NSInteger currentStage;
@end

@implementation NekoUI

- (instancetype)initWithScene:(UIWindowScene *)scene {
    self = [super initWithWindowScene:scene];
    if (self) {
        self.frame = [UIScreen mainScreen].bounds;
        self.windowLevel = 999999;
        self.backgroundColor = [UIColor clearColor];
        self.currentStage = 0;

        WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
        [config.userContentController addScriptMessageHandler:self name:@"nekoHandler"];
        
        self.webView = [[WKWebView alloc] initWithFrame:self.bounds configuration:config];
        self.webView.backgroundColor = [UIColor clearColor];
        self.webView.opaque = NO;
        self.webView.scrollView.scrollEnabled = NO;
        self.webView.scrollView.bounces = NO;
        
        NSString *html = @R"HTML(
<!doctype html><html><head><meta charset=utf8><meta name=viewport content="width=device-width,initial-scale=1,viewport-fit=cover"><style>:root{color-scheme:light;box-sizing:border-box;padding-top:env(safe-area-inset-top,0px);padding-bottom:env(safe-area-inset-bottom,0px)}html{scroll-padding-top:env(safe-area-inset-top,0px)}body{margin:0;padding:0;font:14px -apple-system,BlinkMacSystemFont,sans-serif;background:#fff;color:#000}img{max-width:100%}[hidden]:not([hidden=until-found i]){display:none!important}</style></head><body>
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>Swipe UI</title>
<style>
:root{--bg:#f6f5f2;--panel:#fffefb;--ink:#1d1d1f;--mute:#6b6b70;--line:#1f6feb}
@media (prefers-color-scheme:dark){:root{--bg:#17181b;--panel:#202226;--ink:#f1f1f3;--mute:#9a9aa2;--line:#5aa2ff}}

html,body{height:100%;margin:0;overflow:hidden;background:var(--bg);color:var(--ink);
font-family:-apple-system,"Segoe UI",Helvetica,Arial,sans-serif;overscroll-behavior:none}

.main{position:fixed;inset:0;z-index:0}

.track{position:fixed;inset:0;z-index:1;display:flex;direction:rtl;overflow-x:auto;overflow-y:hidden;
scroll-snap-type:x mandatory;scroll-behavior:smooth;overscroll-behavior:none;
-webkit-overflow-scrolling:touch;scrollbar-width:none}
.track::-webkit-scrollbar{display:none}
.track>*{flex:none;direction:ltr;height:100%;box-sizing:border-box}

.spacer{width:100vw;scroll-snap-align:start;scroll-snap-stop:always}
.peek{width:50px;position:relative;scroll-snap-align:end;scroll-snap-stop:always}
.full{width:100vw;overflow-y:auto;overflow-x:hidden;scroll-snap-align:start;scroll-snap-stop:always;
  color:var(--foreground); font-family:"Sora",system-ui,sans-serif;
  background:radial-gradient(60% 50% at 10% 0%, oklch(0.9 0.035 140 / 70%), transparent),radial-gradient(50% 45% at 100% 100%, oklch(0.88 0.09 100 / 55%), transparent),var(--background);
  padding:max(0.75rem, env(safe-area-inset-top)) 0.75rem max(1.5rem, env(safe-area-inset-bottom))}

.handle{position:absolute;left:0;top:50%;width:46px;height:150px;margin-top:-75px;box-sizing:border-box;
background:var(--gradient-glow);border-radius:0 80px 80px 0/0 75px 75px 0;
box-shadow:var(--shadow-glow),0 8px 22px -6px oklch(0.52 0.12 152 / 45%),inset 0 1px 0 rgba(255,255,255,.5),inset -3px 0 8px rgba(255,255,255,.14);
display:flex;align-items:center;justify-content:center;-webkit-tap-highlight-color:transparent;transition:transform .15s}
.handle:active{transform:scale(.94)}
.handle svg{width:24px;height:24px;margin-left:-2px;filter:drop-shadow(0 1px 2px rgba(0,0,0,.3));animation:nudge 1.8s ease-in-out infinite}
@keyframes nudge{0%,100%{transform:translateX(0)}50%{transform:translateX(4px)}}
@media (prefers-reduced-motion:reduce){.handle svg{animation:none}}

  :root { --background: oklch(0.965 0.014 95); --foreground: oklch(0.3 0.035 155); --primary: oklch(0.52 0.12 152); --primary-foreground: oklch(0.98 0.012 95); --secondary: oklch(0.9 0.035 140); --muted-foreground: oklch(0.48 0.035 155); --accent: oklch(0.88 0.09 100); --destructive: oklch(0.6 0.19 25); --border: oklch(0.35 0.04 155 / 16%); --card: oklch(1 0 0 / 38%); --radius: 1rem; --gradient-glow: linear-gradient(135deg, var(--primary), var(--accent)); --shadow-glass: 0 18px 45px -18px oklch(0.32 0.05 155 / 28%), inset 0 1px 0 oklch(1 0 0 / 65%); --shadow-glow: 0 0 28px -6px oklch(0.52 0.12 152 / 45%); }
  * { margin: 0; padding: 0; box-sizing: border-box; border-color: var(--border); }
  .mono { font-family: "JetBrains Mono", ui-monospace, monospace; }
  .glass { background: var(--card); backdrop-filter: blur(5px) saturate(150%); -webkit-backdrop-filter: blur(5px) saturate(150%); background-image: linear-gradient(135deg, oklch(1 0 0 / 35%), transparent 45%, oklch(1 0 0 / 12%)); border: 1px solid var(--border); border-radius: var(--radius); box-shadow: var(--shadow-glass); }
  .glow { background: var(--gradient-glow); color: var(--primary-foreground); box-shadow: var(--shadow-glow); }
  .app { max-width: 64rem; margin: 0 auto; display: grid; grid-template-columns: 1fr 1fr; gap: 0.75rem; }
  @media (min-width: 768px) { .app { grid-template-columns: 5rem 1fr 18rem; } .rail { grid-row: span 2; } .main-col { grid-column: 2; } .side-col { grid-column: 3; } }
  @media (max-width: 767px) { .rail { grid-row: span 2; flex-direction: row; justify-content: space-around; } .rail nav { flex-direction: row; } .side-col { grid-column: span 2; } }
  .rail { display: flex; flex-direction: column; align-items: center; gap: 0.5rem; padding: 0.5rem; }
  .logo { width: 2.25rem; height: 2.25rem; display: grid; place-items: center; border-radius: 0.75rem; font-weight: 700; font-size: 0.875rem; margin-bottom: 0.5rem; }
  .rail nav { display: flex; flex-direction: column; gap: 0.5rem; width: 100%; }
  .tab-btn { display: flex; flex-direction: column; align-items: center; gap: 0.25rem; width: 100%; padding: 0.5rem 0.25rem; border-radius: 0.75rem; font-size: 0.6875rem; font-weight: 500; color: var(--muted-foreground); text-decoration: none; text-align: center; }
  .tab-btn span { font-size: 1rem; }
  .ico { position: relative; display: block; width: 16px; height: 16px; color: inherit; flex: none; }
  .tab-btn .ico { margin-bottom: 2px; }
  .ico-sliders b { position: absolute; left: 1px; right: 1px; height: 2px; border-radius: 2px; background: currentColor; }
  .ico-sliders b:first-child { top: 4px; }
  .ico-sliders b:last-child { bottom: 4px; }
  .ico-sliders b::after { content: ""; position: absolute; top: -3px; width: 8px; height: 8px; border-radius: 50%; background: currentColor; }
  .ico-sliders b:first-child::after { right: 0; }
  .ico-sliders b:last-child::after { left: 0; }
  .tab-btn:hover { background: var(--secondary); }
  .version { margin-top: auto; font-size: 9px; letter-spacing: 0.1em; text-transform: uppercase; color: oklch(0.48 0.035 155 / 70%); }
  .tab-state { display: none; }
  #tab-exec:checked ~ .app label[for="tab-exec"], #tab-scripts:checked ~ .app label[for="tab-scripts"], #tab-settings:checked ~ .app label[for="tab-settings"] { background: oklch(0.52 0.12 152 / 15%); color: var(--primary); }
  #tab-exec:checked ~ .app .panel-exec, #tab-scripts:checked ~ .app .panel-scripts, #tab-settings:checked ~ .app .panel-settings { display: flex; }
  .panel { display: none; }
  .panel-head { display: flex; align-items: center; justify-content: space-between; border-bottom: 1px solid var(--border); padding: 0.5rem 0.75rem; }
  .panel-title { font-size: 0.75rem; letter-spacing: 0.1em; text-transform: uppercase; }
  .run-btn { display: inline-flex; align-items: center; gap: 0.25rem; padding: 0.375rem 0.75rem; border-radius: 0.5rem; font-size: 0.875rem; font-weight: 600; cursor: pointer; }
  .editor-shell { display: flex; flex-direction: column; overflow: hidden; }
  textarea { height: 40vh; min-height: 14rem; resize: none; background: transparent; border: 0; outline: 0; padding: 1rem; font-family: "JetBrains Mono", ui-monospace, monospace; font-size: 16px; line-height: 1.5; color: var(--foreground); caret-color: var(--primary); -webkit-appearance: none; }
  .panel-body { padding: 1rem; height: 40vh; min-height: 14rem; overflow-y: auto; }
  .script-row { display: flex; align-items: center; justify-content: space-between; background: var(--secondary); border-radius: 0.5rem; padding: 0.5rem 0.75rem; font-size: 0.875rem; margin-bottom: 0.5rem; }
  .script-row small { font-size: 10px; letter-spacing: 0.1em; text-transform: uppercase; color: var(--muted-foreground); }
  .setting-row { display: flex; align-items: center; justify-content: space-between; background: var(--secondary); border-radius: 0.5rem; padding: 0.5rem 0.75rem; font-size: 0.875rem; margin-bottom: 0.75rem; }
  .size-pick { display: flex; gap: 0.25rem; }
  .size-pick label { padding: 0.25rem 0.5rem; border-radius: 0.375rem; font-size: 0.75rem; cursor: pointer; }
  #sz-12:checked ~ .app label[for="sz-12"], #sz-14:checked ~ .app label[for="sz-14"], #sz-16:checked ~ .app label[for="sz-16"], #sz-18:checked ~ .app label[for="sz-18"] { background: var(--gradient-glow); color: var(--primary-foreground); box-shadow: var(--shadow-glow); }
  .size-state { display: none; }
  #sz-12:checked ~ .app textarea { font-size: 12px; } #sz-14:checked ~ .app textarea { font-size: 14px; } #sz-16:checked ~ .app textarea { font-size: 16px; } #sz-18:checked ~ .app textarea { font-size: 18px; }
  .toggle { position: relative; width: 2.75rem; height: 1.5rem; }
  .toggle input { opacity: 0; width: 100%; height: 100%; position: absolute; cursor: pointer; }
  .toggle i { position: absolute; inset: 0; pointer-events: none; border-radius: 999px; background: oklch(0.35 0.04 155 / 25%); transition: background 0.2s; }
  .toggle i::after { content: ""; position: absolute; top: 0.125rem; left: 0.125rem; width: 1.25rem; height: 1.25rem; border-radius: 50%; background: #fff; transition: transform 0.2s; }
  .toggle input:checked + i { background: var(--primary); }
  .toggle input:checked + i::after { transform: translateX(1.25rem); }
  .main-col { display: flex; flex-direction: column; gap: 0.75rem; }
  .logs { padding-bottom: 0; }
  .logs-body { max-height: 10rem; min-height: 6rem; overflow-y: auto; padding: 1rem; font-size: 0.75rem; line-height: 1.5; color: var(--muted-foreground); }
  .side-col { display: flex; flex-direction: column; gap: 0.75rem; }
  .console { display: flex; flex-direction: column; flex: 1; }
  .console-head { display: flex; align-items: center; justify-content: space-between; border-bottom: 1px solid var(--border); padding: 0.5rem 1rem; font-size: 11px; letter-spacing: 0.1em; text-transform: uppercase; color: var(--muted-foreground); }
  .console-body { min-height: 12rem; flex: 1; overflow-y: auto; padding: 1rem; font-size: 0.75rem; line-height: 1.5; }
  .out-err { color: var(--destructive); }
  .out-info { color: var(--muted-foreground); }
  .user { display: flex; align-items: center; gap: 0.75rem; padding: 0.75rem 1rem; }
  .avatar { width: 2.25rem; height: 2.25rem; display: grid; place-items: center; border-radius: 50%; font-size: 0.875rem; }
  .user strong { font-weight: 600; }
  .user small { margin-left: auto; font-size: 10px; letter-spacing: 0.1em; text-transform: uppercase; color: var(--muted-foreground); }
</style>
</head>
<body>
<div class="main"></div>
<div class="track">
  <section class="spacer"></section>
  <section class="peek">
    <a class="handle" href="#full" aria-label="Open executor">
      <svg viewBox="0 0 24 24" fill="none" stroke="oklch(0.98 0.012 95)" stroke-width="3.2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M9 4.5 16.5 12 9 19.5"/></svg>
    </a>
  </section>
  <section class="full" id="full">
<input class="tab-state" type="radio" name="tab" id="tab-exec" checked />
<input class="tab-state" type="radio" name="tab" id="tab-scripts" />
<input class="tab-state" type="radio" name="tab" id="tab-settings" />
<input class="size-state" type="radio" name="size" id="sz-12" />
<input class="size-state" type="radio" name="size" id="sz-14" />
<input class="size-state" type="radio" name="size" id="sz-16" checked />
<input class="size-state" type="radio" name="size" id="sz-18" />
<div class="app">
  <aside class="rail glass">
    <div class="logo glow mono">N</div>
    <nav>
      <label class="tab-btn" for="tab-exec"><span>⌘</span>Exec</label>
      <label class="tab-btn" for="tab-scripts"><span>≡</span>Scripts</label>
      <label class="tab-btn" for="tab-settings"><i class="ico ico-sliders"><b></b><b></b></i>Settings</label>
    </nav>
    <span class="version mono">v0.1</span>
  </aside>
  <div class="main-col">
    <section class="editor-shell glass">
      <div class="panel panel-exec" style="flex-direction: column; width: 100%;">
        <div class="panel-head">
          <span class="panel-title mono">main.luau</span>
          <span class="run-btn glow mono" id="runBtn">▶ Run</span>
        </div>
        <textarea id="codeEditor" spellcheck="false" autocapitalize="off" autocorrect="off">-- Neko
local name = "world"
print("Hello, " .. name)</textarea>
      </div>
      <div class="panel panel-scripts" style="flex-direction: column; width: 100%;">
        <div class="panel-head"><span class="panel-title mono">scripts/</span></div>
        <div class="panel-body">
          <div class="script-row mono">Hello World <small>load</small></div>
          <div class="script-row mono">Quick Math <small>load</small></div>
        </div>
      </div>
      <div class="panel panel-settings" style="flex-direction: column; width: 100%;">
        <div class="panel-head"><span class="panel-title mono">settings</span></div>
        <div class="panel-body">
          <div class="setting-row">
            <span>Editor text size</span>
            <div class="size-pick mono">
              <label for="sz-12">12</label><label for="sz-14">14</label><label for="sz-16">16</label><label for="sz-18">18</label>
            </div>
          </div>
          <div class="setting-row">
            <span>Clear console before each run</span>
            <span class="toggle"><input type="checkbox" /><i></i></span>
          </div>
        </div>
      </div>
    </section>
    <section class="glass">
      <div class="panel-head"><span class="panel-title mono" style="font-size: 11px; color: var(--muted-foreground);">// logs</span></div>
      <div class="logs-body mono" id="logsOutput"><div>Neko loaded</div></div>
    </section>
  </div>
  <div class="side-col">
    <section class="console glass">
      <div class="console-head mono"><span>&gt;_ console</span><span style="font-size: 10px;">clear</span></div>
      <div class="console-body mono" id="consoleOutput"><div class="out-info">Console ready.</div><div>Hello, world</div></div>
    </section>
    <div class="user glass">
      <div class="avatar glow">U</div>
      <strong>User</strong>
      <small class="mono">online</small>
    </div>
  </div>
</div>
  </section>
</div>
<script>
    var track = document.querySelector('.track');
    track.addEventListener('scroll', function() {
        var scrollPos = Math.abs(track.scrollLeft);
        if (scrollPos > window.innerWidth * 1.5) { window.webkit.messageHandlers.nekoHandler.postMessage("STAGE_FULL"); }
        else if (scrollPos > 50) { window.webkit.messageHandlers.nekoHandler.postMessage("STAGE_PEEK"); }
        else { window.webkit.messageHandlers.nekoHandler.postMessage("STAGE_CLOSED"); }
    });
    document.getElementById('runBtn').addEventListener('click', function() {
        var code = document.getElementById('codeEditor').value;
        if (code) { window.webkit.messageHandlers.nekoHandler.postMessage("EXEC:" + code); }
    });
    function appendConsole(msg, isError) {
        var consoleDiv = document.getElementById('consoleOutput');
        var newDiv = document.createElement('div');
        newDiv.innerText = msg;
        if (isError) newDiv.className = 'out-err';
        consoleDiv.appendChild(newDiv);
        consoleDiv.scrollTop = consoleDiv.scrollHeight;
        var logsDiv = document.getElementById('logsOutput');
        if (logsDiv) {
            var logDiv = document.createElement('div');
            logDiv.innerText = msg;
            logsDiv.appendChild(logDiv);
            logsDiv.scrollTop = logsDiv.scrollHeight;
        }
    }
</script>
</body>
</html>
)HTML";
        [self.webView loadHTMLString:html baseURL:nil];
        [self addSubview:self.webView];
    }
    return self;
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (self.currentStage == 0) {
        if (point.x < self.bounds.size.width * 0.3) { return self.webView; }
        return nil;
    }
    return self.webView;
}

- (void)userContentController:(WKUserContentController *)userContentController didReceiveScriptMessage:(WKScriptMessage *)message {
    if (![message.body isKindOfClass:[NSString class]]) return;
    NSString *body = message.body;
    if ([body isEqualToString:@"STAGE_FULL"]) { self.currentStage = 2; return; }
    if ([body isEqualToString:@"STAGE_PEEK"]) { self.currentStage = 1; return; }
    if ([body isEqualToString:@"STAGE_CLOSED"]) { self.currentStage = 0; return; }
    
    if ([body hasPrefix:@"EXEC:"]) {
        NSString *code = [body substringFromIndex:5];
        [self executeScript:code];
        return;
    }
}

- (void)executeScript:(NSString *)code {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        lua_State* L = neko_get_state();
        if (!L) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.webView evaluateJavaScript:@"appendConsole('Error: VM not ready.', true);" completionHandler:nil];
            });
            return;
        }
        lua_State* T = lua_newthread(L);
        neko_track_state(T);
        neko_register_api(T);
        NSString *resultMsg = @"";
        BOOL isError = NO;
        if (luau_load(T, "=console", code.UTF8String, strlen(code.UTF8String), 0) != 0) {
            const char* err = lua_tostring(T, -1);
            resultMsg = [NSString stringWithFormat:@"[Syntax Error] %s", err ? err : "Unknown"];
            isError = YES;
        } else if (lua_pcall(T, 0, 0, 0) != 0) {
            const char* err = lua_tostring(T, -1);
            resultMsg = [NSString stringWithFormat:@"[Runtime Error] %s", err ? err : "Unknown"];
            isError = YES;
        } else { resultMsg = @"[Success] Executed!"; }
        neko_untrack_state(T);
        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *js = [NSString stringWithFormat:@"appendConsole('%@', %@);", resultMsg, isError ? @"true" : @"false"];
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
            UIViewController *rootVC = [[UIViewController alloc] init];
            rootVC.view.backgroundColor = [UIColor clearColor];
            rootVC.view.userInteractionEnabled = NO; 
            g_ui.rootViewController = rootVC;
            [g_ui makeKeyAndVisible];
        }
    });
}
