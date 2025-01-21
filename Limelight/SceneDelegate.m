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
    // Nothing to do
}

- (void)sceneDidBecomeActive:(UIScene *)scene
{
    // Handle scene activation
    Log(LOG_I, @"sceneDidBecomeActive: %@, self.window: %@", scene, self.window);
}

- (void)sceneWillResignActive:(UIScene *)scene
{
    // Handle scene deactivation
    Log(LOG_I, @"sceneWillResignActive: %@", scene);
}

- (void)sceneDidDisconnect:(UIScene *)scene
{
    // Perform cleanup tasks specific to the disconnected scene
    Log(LOG_I, @"sceneDidDisconnect: %@", scene);
}

- (NSUserActivity *)stateRestorationActivityForScene:(UIScene *)scene
{
    return scene.userActivity;
}

@end
