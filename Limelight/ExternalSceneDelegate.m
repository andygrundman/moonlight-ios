#import "ExternalSceneDelegate.h"
#import "ExternalStreamFrameViewController.h"

@implementation ExternalSceneDelegate

- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)connectionOptions
{
    if (@available(iOS 16.0, *)) {
        if (session.role == UIWindowSceneSessionRoleExternalDisplayNonInteractive) {
            Log(LOG_I, @"external scene willConnectToSession for screen %@", self.screen);

            for (UIScreenMode *mode in [self.screen availableModes]) {
                Log(LOG_I, @"External availableMode: %f x %f pixel aspect ratio %f", mode.size.width, mode.size.height, mode.pixelAspectRatio);
                // XXX match configured stream res if possible, probably need a setting

//                if (mode.size.width == 1920 && mode.size.height == 1080) {
//                    [self.screen setCurrentMode:mode];
//                    break;
//                }
            }

            self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
            ExternalStreamFrameViewController *viewController = [[ExternalStreamFrameViewController alloc] init];
            self.window.rootViewController = viewController;
            self.window.hidden = NO;
        }
        else {
            Log(LOG_E, @"external scene willConnectToSession for invalid role %@", session.role.description);
        }
    }
}

- (void)windowScene:(UIWindowScene *)windowScene didUpdateCoordinateSpace:(id<UICoordinateSpace>)previousCoordinateSpace interfaceOrientation:(UIInterfaceOrientation)previousInterfaceOrientation traitCollection:(UITraitCollection *)previousTraitCollection
{
    self.screen = windowScene.screen;

    Log(LOG_I, @"didUpdateCoordinateSpace for screen %@", self.screen.description);
}

- (void)sceneDidDisconnect:(UIScene *)scene
{
    // Perform cleanup tasks specific to the disconnected scene
    Log(LOG_I, @"external sceneDidDisconnect: %@", scene.title);

    self.window.hidden = YES;

    NSNotificationCenter* nc = [NSNotificationCenter defaultCenter];
    [nc postNotificationName:@"ScreenDisconnected" object:self];

    //    Log(LOG_I, @"Removing External Screen");
    //    _extWindow.hidden = YES;
    //    _renderView.bounds = _deviceWindow.bounds;
    //    _renderView.frame = _deviceWindow.frame;
    //    NSNotificationCenter* nc = [NSNotificationCenter defaultCenter];
    //    [nc postNotificationName:@"ScreenDisconnected" object:self];
    //    [self.view insertSubview:_renderView atIndex:0];
}

@end
