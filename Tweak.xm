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
html,body{height:100%;margin:0}
body{background:transparent;color:var(--ink);font-family:-apple-system,"Segoe UI",Helvetica,Arial,sans-serif;
overflow:hidden;overscroll-behavior:none;touch-action:pan-y;user-select:none;-webkit-user-select:none}

.main{height:100%;display:flex;align-items:center;justify-content:center;text-align:center;padding:24px;color:var(--mute);opacity:0;pointer-events:none;}
.main b{display:block;color:var(--ink);font-size:22px;margin-bottom:8px}

.scrim{position:fixed;inset:0;background:#000;opacity:0;pointer-events:none;z-index:30}

.side{position:fixed;top:0;bottom:0;left:0;background:var(--panel);border-right:3px solid var(--line);
box-sizing:border-box;will-change:transform; box-shadow: 10px 0 30px rgba(0,0,0,0.5);}
#drawer{width:0;padding:0;z-index:40}
#exec{width:100vw;border-right:none;z-index:50; background:#17181b;}
#openExec{cursor:pointer}

.anim{transition:transform .28s cubic-bezier(.2,.8,.2,1)}
.scrim.anim{transition:opacity .28s}

.handle{position:absolute;right:-43px;top:50%;width:46px;height:150px;margin-top:-75px;box-sizing:border-box;
background:linear-gradient(160deg,#bf5af2 0%,#8a2be2 50%,#6a0dad 100%);border-radius:0 80px 80px 0/0 75px 75px 0;
box-shadow:0 8px 22px rgba(191,90,242,.45),0 2px 6px rgba(0,0,0,.18),inset 0 1px 0 rgba(255,255,255,.5),inset -3px 0 8px rgba(255,255,255,.14);
display:flex;align-items:center;justify-content:center;-webkit-tap-highlight-color:transparent;transition:transform .15s}
.handle:active{transform:scale(.94)}
.handle svg{width:24px;height:24px;margin-left:-2px;filter:drop-shadow(0 1px 2px rgba(0,0,0,.3));animation:nudge 1.8s ease-in-out infinite}
@keyframes nudge{0%,100%{transform:translateX(0)}50%{transform:translateX(4px)}}
@media (prefers-reduced-motion:reduce){.handle svg{animation:none}}

.neko-container { display: flex; width: 100%; height: 100%; background: #17181b; color: #fff; }
.neko-sidebar { width: 80px; background: #202226; display: flex; flex-direction: column; align-items: center; padding-top: 20px; border-right: 1px solid #333; }
.neko-logo { color: #bf5af2; font-weight: 900; font-size: 20px; margin-bottom: 30px; }
.neko-nav-item { display: flex; flex-direction: column; align-items: center; padding: 15px 0; color: #888; font-size: 10px; font-weight: bold; width: 100%; cursor: pointer; }
.neko-nav-item.active { color: #bf5af2; background: rgba(191, 90, 242, 0.1); border-right: 3px solid #bf5af2; }
.neko-nav-item .icon { font-size: 20px; margin-bottom: 5px; }
.neko-main { flex: 1; display: flex; padding: 15px; gap: 15px; }
.neko-editor-wrapper { flex: 2; display: flex; flex-direction: column; gap: 15px; }
.neko-editor-wrapper textarea { flex: 1; background: #1c1c1e; color: #fff; border: 1px solid #333; border-radius: 10px; padding: 10px; font-family: "Courier New", monospace; font-size: 14px; resize: none; outline: none; }
.neko-exec-btn { height: 50px; background: #bf5af2; color: #000; font-weight: bold; font-size: 16px; border: none; border-radius: 10px; cursor: pointer; transition: 0.2s; box-shadow: 0 0 15px rgba(191, 90, 242, 0.4); }
.neko-exec-btn:active { transform: scale(0.98); }
.neko-console-wrapper { flex: 1; display: flex; flex-direction: column; background: #1c1c1e; border: 1px solid #333; border-radius: 10px; overflow: hidden; }
.neko-console-header { padding: 10px; background: #202226; color: #888; font-size: 12px; font-weight: bold; border-bottom: 1px solid #333; }
.neko-console { flex: 1; padding: 10px; color: #32d74b; font-family: "Courier New", monospace; font-size: 12px; overflow-y: auto; }
</style>
</head>
<body>
<div class="scrim" id="scrim"></div>

<aside class="side" id="drawer" aria-label="Open panel">
  <div class="handle" id="openExec">
    <svg viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="3.2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M9 4.5 16.5 12 9 19.5"/></svg>
  </div>
</aside>

<aside class="side" id="exec" aria-label="Full screen">
  <div class="handle">
    <svg viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="3.2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M9 4.5 16.5 12 9 19.5"/></svg>
  </div>
  
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
</aside>

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

(function(){
  var drawer=document.getElementById('drawer'),
      exec=document.getElementById('exec'),
      scrim=document.getElementById('scrim');
  var hd=drawer.querySelector('.handle'),he=exec.querySelector('.handle');

  var U1=60,
      U2=Math.max(300,innerWidth),
      stage=0,
      d=null;

  function pz(p){return p<=1?p*U1:U1+(p-1)*U2}
  function zp(z){return z<=U1?z/U1:1+(z-U1)/U2}

  function render(p){
    var q=Math.min(p,1);
    drawer.style.transform='translateX(calc(-1 * '+(1-q)+' * (100% + 60px)))';
    exec.style.transform='translateX('+(-(1-Math.max(p-1,0))*100)+'%)';
    hd.style.opacity=p<=1?1:0;
    he.style.opacity=p>1?1:0;
    scrim.style.opacity=(p/2)*.35;
    scrim.style.pointerEvents=p>0.05?'auto':'none';
  }

  function go(s){
    stage=Math.max(0,Math.min(2,s));
    [drawer,exec,scrim].forEach(function(e){e.classList.add('anim')});
    render(stage);
    setTimeout(function(){[drawer,exec,scrim].forEach(function(e){e.classList.remove('anim')})},300);
    // Tell the native side what stage we are in so we can control Roblox touches
    window.webkit.messageHandlers.nekoHandler.postMessage("STAGE_" + stage);
  }

  document.addEventListener('pointerdown',function(e){
    if(e.clientX>innerWidth*0.3&&!e.target.closest('.side'))return;
    d={x:e.clientX,y:e.clientY,t:Date.now(),on:false,p:stage,last:stage};
  });

  document.addEventListener('pointermove',function(e){
    if(!d)return;
    var dx=e.clientX-d.x,dy=e.clientY-d.y;
    if(!d.on){
      if(Math.abs(dx)<8&&Math.abs(dy)<8)return;
      if(Math.abs(dy)>Math.abs(dx)){d=null;return}
      d.on=true;[drawer,exec,scrim].forEach(function(el){el.classList.remove('anim')});
    }
    d.z=Math.max(0,Math.min(U1+U2,pz(d.p)+dx));
    d.last=zp(d.z);
    render(d.last);
  });

  function end(e){
    if(!d)return;
    if(d.on){
      var v=(e.clientX-d.x)/Math.max(1,Date.now()-d.t);
      var s=Math.round(zp(Math.max(0,pz(d.last)+v*250)));
      if(s===d.p&&Math.abs(d.last-d.p)>.25)s=d.p+(d.last>d.p?1:-1);
      go(s);
    }
    d=null;
  }
  document.addEventListener('pointerup',end);
  document.addEventListener('pointercancel',end);

  scrim.addEventListener('click',function(){go(0)});
  document.getElementById('openExec').addEventListener('click',function(){go(2)});
  addEventListener('keydown',function(e){if(e.key==='Escape')go(stage-1)});

  render(0);
})();
</script>
</body>
</html>
)STR";

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
        
        // Full screen WebView. The JS handles the sliding animation natively!
        self.webView = [[WKWebView alloc] initWithFrame:self.bounds configuration:config];
        self.webView.backgroundColor = [UIColor clearColor];
        self.webView.opaque = NO;
        self.webView.scrollView.scrollEnabled = NO;
        self.webView.scrollView.bounces = NO;
        
        NSString *html = [NSString stringWithUTF8String:HTML_UI];
        [self.webView loadHTMLString:html baseURL:nil];
        [self addSubview:self.webView];
    }
    return self;
}

// This fixes the joystick. When closed, the right 70% of the screen bypasses the WebView and goes to Roblox.
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (self.currentStage == 0) {
        if (point.x < self.bounds.size.width * 0.3) {
            return self.webView; // Left side catches the swipe
        }
        return nil; // Right side goes to Roblox
    }
    return self.webView; // If UI is open, catch all touches
}

- (void)userContentController:(WKUserContentController *)userContentController didReceiveScriptMessage:(WKScriptMessage *)message {
    if (![message.body isKindOfClass:[NSString class]]) return;
    NSString *body = message.body;
    
    if ([body hasPrefix:@"STAGE_"]) {
        self.currentStage = [[body substringFromIndex:6] integerValue];
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
