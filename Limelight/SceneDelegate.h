//
//  SceneDelegate.h
//  Moonlight
//
//  Created by Andy Grundman on 1/17/25.
//

#import <UIKit/UIKit.h>

@interface SceneDelegate : UIResponder <UIWindowSceneDelegate>

@property (strong, nonatomic) UIWindow *window;

- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)connectionOptions;
- (void)sceneDidDisconnect:(UIScene *)scene;
- (void)sceneDidBecomeActive:(UIScene *)scene;
- (void)sceneWillResignActive:(UIScene *)scene;
- (NSUserActivity *)stateRestorationActivityForScene:(UIScene *)scene;

@end
