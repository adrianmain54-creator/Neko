#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include "Neko.h"
#include <dlfcn.h>

extern lua_State* get_roblox_state();

@interface NekoUI : UIWindow
@property (nonatomic, strong) UIView *mainContainer;
@property (nonatomic, strong) UIView *dragHandle;
@property (nonatomic, strong) UITextView *editor;
@property (nonatomic, strong) UITextView *console;
@property (nonatomic, assign) BOOL isOpen;
@end

@implementation NekoUI

// ... [Keep all the UI initialization code exactly the same as the last message] ...

- (void)execute {
    NSString *code = self.editor.text;
    if (code.length == 0) return;
    
    self.console.text = [self.console.text stringByAppendingString:@"\n> Executing..."];
    
    // HIGH PRIORITY THREAD: Fastest possible execution
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        lua_State* L = get_roblox_state(); 
        if (!L) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.console.text = [self.console.text stringByAppendingString:@"\n[Error] VM not ready."];
            });
            return;
        }

        // 1. Create the thread (Luau's newthread is extremely fast)
        lua_State* T = lua_newthread(L);
        
        // 2. Compile the script directly to bytecode (no extra parsing overhead)
        size_t bytecodeSize = 0;
        char* bytecode = luau_compile(code.UTF8String, strlen(code.UTF8String), nullptr, &bytecodeSize);
        
        NSString *resultMsg = @"";
        
        if (!bytecode) {
            resultMsg = @"\n[Syntax Error] Failed to compile.";
        } else {
            // 3. Load the compiled bytecode into the thread
            if (luau_load(T, "=neko", bytecode, bytecodeSize, 0) != 0) {
                const char* err = lua_tostring(T, -1);
                resultMsg = [NSString stringWithFormat:@"\n[Load Error] %s", err ? err : "Unknown"];
            } else {
                // 4. Register API only AFTER bytecode is loaded (saves time)
                luaL_sandboxthread(T);
                neko_register_api(T);
                
                // 5. Execute
                if (lua_pcall(T, 0, 0, 0) != 0) {
                    const char* err = lua_tostring(T, -1);
                    resultMsg = [NSString stringWithFormat:@"\n[Runtime Error] %s", err ? err : "Unknown"];
                } else {
                    resultMsg = @"\n[Success] Executed instantly!";
                }
            }
            free(bytecode); // Clean up
        }
        
        dispatch_async(dispatch_get_main_queue(), ^{
            self.console.text = [self.console.text stringByAppendingString:resultMsg];
            [self.console scrollRangeToVisible:NSMakeRange([self.console.text length], 0)];
        });
    });
}

@end

// ... [Keep the init function exactly the same] ...
