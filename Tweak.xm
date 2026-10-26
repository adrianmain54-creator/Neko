#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>

@interface NekoUI : UIWindow
@property (nonatomic, strong) WKWebView *webView;
@end

@implementation NekoUI

- (instancetype)initWithScene:(UIWindowScene *)scene {
    self = [super initWithWindowScene:scene];
    if (self) {
        self.frame = [UIScreen mainScreen].bounds;
        self.windowLevel = 999999;
        self.backgroundColor = [UIColor clearColor];

        self.webView = [[WKWebView alloc] initWithFrame:self.bounds];
        self.webView.opaque = NO;
        self.webView.backgroundColor = [UIColor clearColor];
        
        // BRIGHT RED BACKGROUND TEST
        NSString *html = @"<html><body style='background: rgba(255,0,0,0.8); color: white; font-size: 40px; display: flex; justify-content: center; align-items: center; height: 100vh; margin: 0;'><b>WEBVIEW IS WORKING</b></body></html>";
        
        [self.webView loadHTMLString:html baseURL:nil];
        [self addSubview:self.webView];
    }
    return self;
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
