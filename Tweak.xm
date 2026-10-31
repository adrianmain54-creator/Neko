// Tweak.mm — Neko
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>
#import <mach/mach.h>
#import <mach/mach_vm.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/getsect.h>
#include <dlfcn.h>
#include <string.h>
#include <stdlib.h>
#include <libkern/OSCacheControl.h>

#include "lua.h"
#include "lualib.h"
#include "lauxlib.h"

extern int luau_load(lua_State* L, const char* chunkname, const char* data, size_t size, int env);
extern kern_return_t mach_vm_protect(vm_map_t, mach_vm_address_t, mach_vm_size_t, boolean_t, vm_prot_t);

// ───────────── stealth ─────────────
static inline char* sx_dec(const uint8_t* enc, size_t len, uint8_t key) {
    char* out = (char*)malloc(len + 1);
    for (size_t i = 0; i < len; i++) out[i] = (char)(enc[i] ^ key);
    out[len] = 0;
    return out;
}
static inline void sx_wipe(void* p, size_t n) {
    volatile uint8_t* v = (volatile uint8_t*)p;
    for (size_t i = 0; i < n; i++) v[i] = 0;
}

static const uint8_t k_newstate_enc[] = { 0x36,0x35,0x3B,0x54,0x3C,0x3B,0x29,0x34,0x3B,0x2A,0x3B,0x2A,0x3B };
static const uint8_t k_imgname_enc[] = { 0x08,0x35,0x38,0x32,0x3B,0x5C,0x2C,0x35,0x3B,0x2C,0x3B,0x2C,0x3B,0x5B,0x3C,0x3B,0x5B };
static const uint8_t k_handler_enc[] = { 0x34,0x3B,0x30,0x35,0x12,0x3B,0x34,0x2B,0x35,0x3B };

// ───────────── pattern scan ─────────────
static uintptr_t scan_bytes(const uint8_t* data, size_t size, const uint8_t* sig, const char* mask, size_t n) {
    if (size < n) return 0;
    for (size_t i = 0; i + n <= size; i++) {
        bool ok = true;
        for (size_t j = 0; j < n; j++)
            if (mask[j] == 'x' && data[i+j] != sig[j]) { ok = false; break; }
        if (ok) return (uintptr_t)(data + i);
    }
    return 0;
}

static uintptr_t find_pattern_in(const char* img_sub, const uint8_t* sig, const char* mask, size_t n) {
    uint32_t cnt = _dyld_image_count();
    for (uint32_t i = 0; i < cnt; i++) {
        const char* nm = _dyld_get_image_name(i);
        if (!nm || !strstr(nm, img_sub)) continue;
        const struct mach_header_64* h = (const struct mach_header_64*)_dyld_get_image_header(i);
        if (!h || h->magic != MH_MAGIC_64) continue;
        uint64_t sz = 0;
        const uint8_t* t = getsectiondata(h, "__TEXT", "__text", &sz);
        if (!t) continue;
        uintptr_t r = scan_bytes(t, (size_t)sz, sig, mask, n);
        if (r) return r;
    }
    return 0;
}

// ───────────── lua state ─────────────
static lua_State* g_state = NULL;
static NSMutableSet<NSValue*>* g_tracked = nil;
static lua_State* neko_get_state(void) { return g_state; }
static void neko_set_state(lua_State* L) { g_state = L; }
static void neko_track_state(lua_State* L) {
    if (!g_tracked) g_tracked = [NSMutableSet new];
    [g_tracked addObject:[NSValue valueWithPointer:L]];
}
static void neko_untrack_state(lua_State* L) {
    [g_tracked removeObject:[NSValue valueWithPointer:L]];
}

// ───────────── NekoUI ─────────────
@interface NekoUI : NSObject <WKScriptMessageHandler>
@property (nonatomic, strong) UIWindow* window;
@property (nonatomic, strong) WKWebView* webView;
@property (nonatomic, assign) NSInteger currentStage;
- (void)show;
- (void)executeChunk:(const char*)src length:(NSUInteger)len;
@end

static NekoUI* g_ui = nil;

// ───────────── console ─────────────
static void neko_console(WKWebView* wv, NSString* msg, BOOL isErr) {
    if (!wv) return;
    NSString* safe = msg ?: @"";
    dispatch_async(dispatch_get_main_queue(), ^{
        if (@available(iOS 14.3, *)) {
            [wv callAsyncJavaScript:@"window.nekoConsole(msg, isErr);"
                          arguments:@{ @"msg": safe, @"isErr": @(isErr) }
                            inFrame:nil inContentWorld:WKContentWorld.pageWorld completionHandler:nil];
        } else {
            NSData* d = [NSJSONSerialization dataWithJSONObject:@[safe, @(isErr)] options:0 error:nil];
            NSString* json = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
            NSString* js = [NSString stringWithFormat:@"window.nekoConsole.apply(null, %@);", json];
            [wv evaluateJavaScript:js completionHandler:nil];
        }
    });
}

// ───────────── print() ─────────────
static int luaB_neko_print(lua_State* L) {
    int n = lua_gettop(L);
    NSMutableString* out = [NSMutableString string];
    for (int i = 1; i <= n; i++) {
        size_t len = 0;
        const char* s = lua_tolstring(L, i, &len);
        if (i > 1) [out appendString:@"\t"];
        if (s) [out appendFormat:@"%s", s];
        else   [out appendString:@"nil"];
    }
    NSString* msg = [out copy];
    dispatch_async(dispatch_get_main_queue(), ^{
        if (g_ui && g_ui.webView) neko_console(g_ui.webView, msg, NO);
    });
    return 0;
}

static void neko_register_api(lua_State* L) {
    if (!L) return;
    lua_pushcfunction(L, luaB_neko_print);
    lua_setglobal(L, "print");
}
static void neko_install_hooks(lua_State* L) { neko_register_api(L); }

// ───────────── BL patch ─────────────
static bool make_rwx(void* addr, size_t len) {
    uintptr_t page = (uintptr_t)addr & ~0xFFFULL;
    size_t span = (((uintptr_t)addr + len + 0xFFF) & ~0xFFFULL) - page;
    return mach_vm_protect(mach_task_self(), (mach_vm_address_t)page, span, false, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_EXECUTE) == KERN_SUCCESS;
}

static bool bl_patch(void* site, void* target, uint8_t saved[4]) {
    uintptr_t s = (uintptr_t)site;
    int64_t off = (int64_t)(uintptr_t)target - (int64_t)s;
    if (off & 3) return false;
    if (off < -(1LL << 27) || off >= (1LL << 27)) return false;
    memcpy(saved, (void*)s, 4);
    uint32_t insn = 0x94000000u | (((uint32_t)(off >> 2)) & 0x03FFFFFFu);
    if (!make_rwx((void*)s, 4)) return false;
    memcpy((void*)s, &insn, 4);
    sys_icache_invalidate((void*)s, 4);
    return true;
}

static bool bl_restore(void* site, const uint8_t saved[4]) {
    if (!make_rwx(site, 4)) return false;
    memcpy(site, saved, 4);
    sys_icache_invalidate(site, 4);
    return true;
}

// ───────────── hook ─────────────
typedef lua_State* (*lua_newstate_fn)(lua_Alloc, void*);
static lua_newstate_fn p_real_newstate = NULL;
static uint8_t g_saved_bl[4] = {0};
static void*   g_patched_site = NULL;

static lua_State* my_newstate(lua_Alloc f, void* ud) {
    lua_State* L = p_real_newstate ? p_real_newstate(f, ud) : NULL;
    if (L && !g_state) {
        neko_set_state(L);
        neko_install_hooks(L);
        if (g_patched_site) { bl_restore(g_patched_site, g_saved_bl); g_patched_site = NULL; }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (g_ui && g_ui.webView)
                [g_ui.webView evaluateJavaScript:@"window.nekoReady && window.nekoReady(true);" completionHandler:nil];
        });
    }
    return L;
}

#if __has_include("sigs.h")
#include "sigs.h"
#define NEKO_HAS_SIGS 1
#else
#define NEKO_HAS_SIGS 0
#endif

static void neko_hook_init(void) {
    char* s_newstate = sx_dec(k_newstate_enc, sizeof(k_newstate_enc), 0x5A);
    char* s_img      = sx_dec(k_imgname_enc,  sizeof(k_imgname_enc),  0x5A);

    uintptr_t real = (uintptr_t)dlsym(RTLD_DEFAULT, s_newstate);
#if NEKO_HAS_SIGS
    if (!real) real = find_pattern_in(s_img, off::lua_newstate_sig, off::lua_newstate_mask, sizeof(off::lua_newstate_sig));
#endif
    if (!real) {
        NSLog(@"[Neko] lua_newstate unresolved");
        sx_wipe(s_newstate, sizeof(k_newstate_enc)); sx_wipe(s_img, sizeof(k_imgname_enc));
        free(s_newstate); free(s_img);
        return;
    }
    p_real_newstate = (lua_newstate_fn)real;

    uintptr_t site = 0;
#if NEKO_HAS_SIGS
    site = find_pattern_in(s_img, off::blsite_sig, off::blsite_mask, sizeof(off::blsite_sig));
#endif
    if (!site) {
        NSLog(@"[Neko] BL site unresolved");
        sx_wipe(s_newstate, sizeof(k_newstate_enc)); sx_wipe(s_img, sizeof(k_imgname_enc));
        free(s_newstate); free(s_img);
        return;
    }

    if (!bl_patch((void*)site, (void*)&my_newstate, g_saved_bl)) {
        NSLog(@"[Neko] BL patch failed");
        sx_wipe(s_newstate, sizeof(k_newstate_enc)); sx_wipe(s_img, sizeof(k_imgname_enc));
        free(s_newstate); free(s_img);
        return;
    }
    g_patched_site = (void*)site;
    NSLog(@"[Neko] BL patch %p -> %p", (void*)site, (void*)&my_newstate);

    sx_wipe(s_newstate, sizeof(k_newstate_enc)); sx_wipe(s_img, sizeof(k_imgname_enc));
    free(s_newstate); free(s_img);
}

// ───────────── UI ─────────────
@interface NekoRootView : UIView
@property (nonatomic, weak) NekoUI* neko;
@end

@implementation NekoRootView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (!self.neko || !self.neko.webView) return [super hitTest:point withEvent:event];
    NSInteger stage = self.neko.currentStage;
    if (stage == 2) return self.neko.webView;
    if (stage == 1) return (point.x <= 340.0) ? self.neko.webView : nil;
    return (point.x <= 34.0) ? self.neko.webView : nil;
}
@end

static NSMutableDictionary<NSNumber*, NSMutableData*>* g_execBuf = nil;

@implementation NekoUI
- (void)show {
    UIWindowScene* scene = nil;
    for (UIScene* s in UIApplication.sharedApplication.connectedScenes) {
        if ([s isKindOfClass:UIWindowScene.class]) { scene = (UIWindowScene*)s; break; }
    }
    if (!scene) return;

    self.window = [[UIWindow alloc] initWithWindowScene:scene];
    self.window.frame = scene.coordinateSpace.bounds;
    self.window.windowLevel = UIWindowLevelAlert + 100;
    self.window.backgroundColor = UIColor.clearColor;

    WKWebViewConfiguration* cfg = [WKWebViewConfiguration new];
    cfg.userContentController = [WKUserContentController new];
    char* s_handler = sx_dec(k_handler_enc, sizeof(k_handler_enc), 0x5A);
    [cfg.userContentController addScriptMessageHandler:self name:[NSString stringWithUTF8String:s_handler]];
    sx_wipe(s_handler, sizeof(k_handler_enc)); free(s_handler);
    cfg.defaultWebpagePreferences.allowsContentJavaScript = YES;

    self.webView = [[WKWebView alloc] initWithFrame:self.window.bounds configuration:cfg];
    self.webView.backgroundColor = UIColor.clearColor;
    self.webView.opaque = NO;
    self.webView.scrollView.scrollEnabled = YES;
    self.webView.scrollView.bounces = NO;
    self.webView.scrollView.alwaysBounceVertical = NO;
    self.webView.scrollView.alwaysBounceHorizontal = NO;
    self.webView.scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    self.webView.scrollView.backgroundColor = UIColor.clearColor;

    NekoRootView* root = [[NekoRootView alloc] initWithFrame:self.window.bounds];
    root.backgroundColor = UIColor.clearColor;
    root.neko = self;
    [root addSubview:self.webView];

    UIViewController* vc = [UIViewController new];
    vc.view = root;
    self.window.rootViewController = vc;
    self.window.hidden = NO;
    self.currentStage = 0;

    NSString* html = @R"HTML(<!doctype html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no,viewport-fit=cover">
<style>
:root{ --bg:rgba(18,18,22,.82); --bg2:rgba(28,28,34,.9); --line:rgba(255,255,255,.08); --txt:#e8e8ee; --dim:#8a8a96; --accent:#ff3b4e; --ok:#3ddc84; --err:#ff5d6c; --mono:ui-monospace,"SF Mono",Menlo,monospace; }
*{box-sizing:border-box;-webkit-tap-highlight-color:transparent}
html,body{margin:0;height:100%;overflow:hidden;background:transparent;font:14px/1.35 -apple-system,"SF Pro Text",system-ui;color:var(--txt);-webkit-user-select:none;user-select:none}
button{font:inherit;color:inherit;background:none;border:0;padding:0;cursor:pointer}
input,textarea{font:inherit;color:inherit;background:none;border:0;outline:0}
#root{position:fixed;inset:0;pointer-events:none}
#handle{position:absolute;left:0;top:50%;transform:translateY(-50%);width:30px;height:92px;pointer-events:auto;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:4px;background:var(--bg);border:1px solid var(--line);border-left:0;border-radius:0 14px 14px 0;backdrop-filter:blur(18px);-webkit-backdrop-filter:blur(18px);box-shadow:0 6px 24px rgba(0,0,0,.45);transition:opacity .18s}
#handle b{font-size:15px;color:var(--accent)}
#handle span{font-size:9px;color:var(--dim);letter-spacing:.12em;writing-mode:vertical-rl}
#panel{position:absolute;left:0;top:0;bottom:0;width:100%;max-width:430px;display:flex;flex-direction:column;pointer-events:auto;background:var(--bg);backdrop-filter:blur(26px) saturate(1.4);-webkit-backdrop-filter:blur(26px) saturate(1.4);border-right:1px solid var(--line);box-shadow:0 0 60px rgba(0,0,0,.6);transform:translateX(-100%);transition:transform .26s cubic-bezier(.32,.72,0,1),width .26s;padding-top:env(safe-area-inset-top);padding-bottom:env(safe-area-inset-bottom)}
#root[data-stage="peek"] #panel{transform:translateX(0);width:330px}
#root[data-stage="full"] #panel{transform:translateX(0);width:100%;max-width:none;border-right:0}
#root[data-stage="peek"] #handle,#root[data-stage="full"] #handle{opacity:0;pointer-events:none}
#hdr{display:flex;align-items:center;justify-content:space-between;padding:14px 14px 10px;border-bottom:1px solid var(--line);flex:0 0 auto}
.brand{display:flex;align-items:center;gap:8px;font-weight:600;letter-spacing:.2px}
.brand i{width:8px;height:8px;border-radius:50%;background:var(--dim);box-shadow:0 0 0 3px rgba(255,255,255,.04)}
.brand i.on{background:var(--ok);box-shadow:0 0 8px var(--ok)}
.brand small{font-weight:400;color:var(--dim);font-size:11px;margin-left:2px}
.hbtns{display:flex;gap:6px;align-items:center}
.hbtns button{height:30px;min-width:30px;padding:0 10px;border-radius:9px;border:1px solid var(--line);background:rgba(255,255,255,.04);font-size:13px;font-weight:600;transition:background .12s}
.hbtns button:active{background:rgba(255,255,255,.12)}
#bRun{background:var(--accent);border-color:transparent;color:#fff}
#bRun:active{filter:brightness(.85)}
#editorWrap{flex:1 1 auto;min-height:0;display:flex;padding:0 12px 8px;margin-top:8px}
#code{flex:1;width:100%;height:100%;resize:none;padding:12px;border-radius:12px;background:var(--bg2);border:1px solid var(--line);font-family:var(--mono);font-size:14px;line-height:1.45;-webkit-user-select:text;user-select:text;tab-size:2;overflow:auto;-webkit-overflow-scrolling:touch;white-space:pre;word-break:normal}
#body{flex:1 1 auto;min-height:0;display:flex;flex-direction:column}
#consoleWrap{flex:0 0 auto;height:34%;min-height:110px;display:flex;flex-direction:column;border-top:1px solid var(--line);background:rgba(0,0,0,.22)}
#cHdr{display:flex;align-items:center;justify-content:space-between;padding:7px 12px 5px;font-size:11px;color:var(--dim);letter-spacing:.08em;text-transform:uppercase;flex:0 0 auto}
#cHdr button{font-size:11px;color:var(--dim);padding:3px 7px;border-radius:6px;border:1px solid var(--line);text-transform:none;letter-spacing:0}
#log{flex:1 1 auto;min-height:0;overflow:auto;-webkit-overflow-scrolling:touch;padding:0 12px 10px;font-family:var(--mono);font-size:12px;line-height:1.5;-webkit-user-select:text;user-select:text}
.line{margin-bottom:4px;white-space:pre-wrap;word-break:break-word}
.line.err{color:var(--err)}
.line.ok{color:var(--ok)}
.line.sys{color:var(--dim)}
</style>
</head>
<body>
<div id="root" data-stage="closed">
  <div id="handle"><b>N</b><span>NEKO</span></div>
  <section id="panel">
    <header id="hdr">
      <div class="brand"><i id="dot"></i><span>Neko</span><small>v0.2</small></div>
      <div class="hbtns"><button id="bRun">▶ Run</button><button id="bClose">✕</button></div>
    </header>
    <div id="body">
      <div id="editorWrap"><textarea id="code" spellcheck="false" placeholder="-- neko&#10;print(&quot;hello&quot;)"></textarea></div>
      <div id="consoleWrap"><div id="cHdr"><span>Console</span><button id="cClear">clear</button></div><div id="log"></div></div>
    </div>
  </section>
</div>
<script>
(function(){
"use strict";
var __execId = 0;
window.Neko = window.Neko || {};
window.Neko.exec = function(src) {
  src = String(src);
  var id = ++__execId, CHUNK = 32768, i = 0;
  try { window.webkit.messageHandlers.nekoHandler.postMessage("EXEC_BEGIN:" + id + ":" + src.length); } catch(e){ return; }
  function push(){
    if (i >= src.length) { try { window.webkit.messageHandlers.nekoHandler.postMessage("EXEC_END:" + id); } catch(e){} return; }
    var part = src.slice(i, i + CHUNK); i += CHUNK;
    try { window.webkit.messageHandlers.nekoHandler.postMessage("EXEC_CHUNK:" + id + ":" + btoa(unescape(encodeURIComponent(part)))); } catch(e){ return; }
    setTimeout(push, 0);
  }
  push();
};
window.Neko.setStage = function(s){ try { window.webkit.messageHandlers.nekoHandler.postMessage("STAGE_" + s.toUpperCase()); } catch(e){} };
var logEl = document.getElementById("log"), dot = document.getElementById("dot"), MAX = 400;
window.nekoConsole = function(msg, isErr) {
  var d = document.createElement("div"); d.className = "line " + (isErr ? "err" : ""); d.textContent = String(msg == null ? "" : msg);
  logEl.appendChild(d); while (logEl.children.length > MAX) logEl.removeChild(logEl.firstChild); logEl.scrollTop = logEl.scrollHeight;
};
window.nekoReady = function(ok) {
  dot.classList.toggle("on", !!ok);
  if (ok) { var d = document.createElement("div"); d.className = "line sys"; d.textContent = "VM ready."; logEl.appendChild(d); logEl.scrollTop = logEl.scrollHeight; }
};
var stage = "closed", root = document.getElementById("root");
function setStage(s){ if (s === stage) return; stage = s; root.dataset.stage = s; window.Neko.setStage(s); if (s === "full") requestAnimationFrame(function(){ document.getElementById("code").focus(); }); }
document.getElementById("handle").onclick = function(){ setStage("full"); };
document.getElementById("bClose").onclick = function(){ setStage("closed"); };
var code = document.getElementById("code");
code.addEventListener("keydown", function(e){
  if ((e.metaKey || e.ctrlKey) && e.key === "Enter") { e.preventDefault(); window.Neko.exec(code.value); }
  if (e.key === "Tab") { e.preventDefault(); var s = this.selectionStart; this.value = this.value.slice(0, s) + "  " + this.value.slice(this.selectionEnd); this.selectionStart = this.selectionEnd = s + 2; }
});
document.getElementById("bRun").onclick = function(){ var src = code.value; if (!src.trim()) { window.nekoConsole("nothing to run.", true); return; } window.nekoConsole("> " + src.split("\n")[0] + (src.indexOf("\n") >= 0 ? " …" : ""), false); window.Neko.exec(src); };
document.getElementById("cClear").onclick = function(){ logEl.innerHTML = ""; };
})();
</script>
</body>
</html>
)HTML";
    [self.webView loadHTMLString:html baseURL:nil];
}

- (void)userContentController:(WKUserContentController *)ucc didReceiveScriptMessage:(WKScriptMessage *)message {
    char* s_handler = sx_dec(k_handler_enc, sizeof(k_handler_enc), 0x5A);
    NSString* wantHandler = [NSString stringWithUTF8String:s_handler];
    sx_wipe(s_handler, sizeof(k_handler_enc)); free(s_handler);
    if (![message.name isEqualToString:wantHandler]) return;

    NSString* body = [message.body isKindOfClass:NSString.class] ? message.body : [message.body description];
    if ([body hasPrefix:@"EXEC_BEGIN:"]) {
        NSArray* p = [body componentsSeparatedByString:@":"]; if (p.count < 3) return;
        NSNumber* eid = @([p[1] intValue]); if (!g_execBuf) g_execBuf = [NSMutableDictionary new];
        g_execBuf[eid] = [NSMutableData new];
    } else if ([body hasPrefix:@"EXEC_CHUNK:"]) {
        NSRange r1 = [body rangeOfString:@":"]; if (r1.location == NSNotFound) return;
        NSRange searchRange = NSMakeRange(r1.location + 1, body.length - r1.location - 1);
        NSRange r2 = [body rangeOfString:@":" options:0 range:searchRange]; if (r2.location == NSNotFound) return;
        NSNumber* eid = @([[body substringWithRange:NSMakeRange(r1.location + 1, r2.location - r1.location - 1)] intValue]);
        NSString* b64 = [body substringFromIndex:r2.location + 1];
        NSData* raw = [[NSData alloc] initWithBase64EncodedString:b64 options:0];
        NSMutableData* buf = g_execBuf[eid]; if (buf && raw) [buf appendData:raw];
    } else if ([body hasPrefix:@"EXEC_END:"]) {
        NSNumber* eid = @([[body substringFromIndex:9] intValue]);
        NSMutableData* buf = g_execBuf[eid]; [g_execBuf removeObjectForKey:eid]; if (!buf) return;
        [buf appendBytes:"\0" length:1]; [self executeChunk:(const char*)buf.bytes length:buf.length - 1];
    } else if ([body isEqualToString:@"STAGE_PEEK"]) self.currentStage = 1;
    else if ([body isEqualToString:@"STAGE_FULL"]) self.currentStage = 2;
    else if ([body isEqualToString:@"STAGE_CLOSED"]) self.currentStage = 0;
}

- (void)executeChunk:(const char*)src length:(NSUInteger)len {
    lua_State* L = neko_get_state();
    if (!L) { neko_console(self.webView, @"Error: VM not ready.", YES); return; }
    lua_State* T = lua_newthread(L);
    if (!T) { neko_console(self.webView, @"Error: lua_newthread failed.", YES); return; }
    neko_track_state(T); neko_register_api(T);
    NSString* msg = nil; BOOL isErr = NO;
    int rc = luau_load(T, "=console", src, (size_t)len, 0);
    if (rc != 0) { const char* err = lua_tostring(T, -1); msg = [NSString stringWithFormat:@"[Syntax Error] %s", err ?: "unknown"]; isErr = YES; }
    else if (lua_pcall(T, 0, 0, 0) != 0) { const char* err = lua_tostring(T, -1); msg = [NSString stringWithFormat:@"[Runtime Error] %s", err ?: "unknown"]; isErr = YES; }
    else { msg = @"[Success] Executed!"; }
    lua_settop(T, 0); neko_untrack_state(T); neko_console(self.webView, msg, isErr);
}
@end

static void neko_boot(void) { neko_hook_init(); g_ui = [NekoUI new]; [g_ui show]; }
%ctor { dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ neko_boot(); }); }
