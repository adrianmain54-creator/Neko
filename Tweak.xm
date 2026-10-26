#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

__attribute__((constructor)) static void init() {
    // Wait 10 seconds for the game to fully load
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"NEKO DIAGNOSTIC" 
                                                                       message:@"The dylib is loading and executing code!" 
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];

        // Find the correct window to present the alert
        UIViewController *rootVC = nil;
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (scene.activationState == UISceneActivationStateForegroundActive && [scene isKindOfClass:[UIWindowScene class]]) {
                for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                    if (window.isKeyWindow) { rootVC = window.rootViewController; break; }
                }
            }
        }
        if (!rootVC) {
            rootVC = [UIApplication sharedApplication].keyWindow.rootViewController;
        }
        
        if (rootVC) {
            [rootVC presentViewController:alert animated:YES completion:nil];
        }
    });
}
