//
//  SceneDelegate.m
//  Moonlight
//
//  Created by Andy Grundman on 1/17/25.
//  Copyright © 2025 Moonlight Game Streaming Project. All rights reserved.
//

#import "SceneDelegate.h"
#import "MainFrameViewController.h"

@implementation SceneDelegate

- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)connectionOptions
{
    NSUserActivity *userActivity = connectionOptions.userActivities.anyObject ?: session.stateRestorationActivity;
    if (userActivity) {
        NSLog(@"TODO: restore from userActivity %@", userActivity);
    }

    if (session.role == UIWindowSceneSessionRoleApplication) {
        self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
        MainFrameViewController *viewController = [[MainFrameViewController alloc] init];
        self.window.rootViewController = viewController;
        [self.window makeKeyAndVisible];
    }
    else {
        Log(LOG_E, @"scene willConnectToSession for invalid role %@", session.role.description);
    }
}

- (void)sceneDidDisconnect:(UIScene *)scene
{
    // Perform cleanup tasks specific to the disconnected scene
    Log(LOG_I, @"sceneDidDisconnect: %@", scene.title);
}


- (void)sceneDidBecomeActive:(UIScene *)scene
{
    // Handle scene activation
    Log(LOG_I, @"sceneDidBecomeActive: %@", scene.title);
}

- (void)sceneWillResignActive:(UIScene *)scene
{
    // Handle scene deactivation
    Log(LOG_I, @"sceneWillResignActive: %@", scene.title);
}

- (NSUserActivity *)stateRestorationActivityForScene:(UIScene *)scene
{
    return scene.userActivity;
}

@end
