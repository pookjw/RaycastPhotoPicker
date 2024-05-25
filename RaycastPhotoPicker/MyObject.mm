//
//  MyObject.mm
//  RaycastPhotoPicker
//
//  Created by Jinwoo Kim on 5/21/24.
//

#import "MyObject.h"
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <MultipeerConnectivity/MultipeerConnectivity.h>

namespace _MCAlertController {
    namespace show {
        void (*original)(id, SEL);
        void custom(__kindof UIViewController *self, SEL _cmd) {
            UIWindowScene *activeWindowScene = nil;
            
            for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
                if ([scene isKindOfClass:UIWindowScene.class]) {
                    UIWindowScene *windowScene = (UIWindowScene *)scene;
                    
                    if (windowScene.activationState == UISceneActivationStateForegroundActive) {
                        activeWindowScene = windowScene;
                        break;
                    }
                }
            }
            
            UIWindow *window = [[UIWindow alloc] initWithWindowScene:activeWindowScene];
            
            ((void (*)(id, SEL, id))objc_msgSend)(self, sel_registerName("setAlertWindow:"), window);
            
            UIViewController *rootViewController = [UIViewController new];
            window.rootViewController = rootViewController;
            
            window.windowLevel = UIWindowLevelAlert;
            [window makeKeyAndVisible];
            [rootViewController presentViewController:self animated:YES completion:nil];
        }
    }
}

@implementation MyObject

+ (void)load {
    using namespace _MCAlertController::show;
    Method method = class_getInstanceMethod(objc_lookUpClass("MCAlertController"), sel_registerName("show"));
    original = (decltype(original))method_getImplementation(method);
    method_setImplementation(method, (IMP)custom);
}

@end
