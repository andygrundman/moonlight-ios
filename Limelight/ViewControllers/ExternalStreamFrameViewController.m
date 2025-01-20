#import "ExternalStreamFrameViewController.h"
#import "MainFrameViewController.h"
#import "VideoDecoderRenderer.h"
#import "StreamManager.h"
#import "ControllerSupport.h"
#import "DataManager.h"

#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <Limelight.h>

@interface AVDisplayCriteria()
@property(readonly) int videoDynamicRange;
@property(readonly, nonatomic) float refreshRate;
- (id)initWithRefreshRate:(float)arg1 videoDynamicRange:(int)arg2;
@end

@implementation ExternalStreamFrameViewController {
    StreamManager *_streamMan;
    StreamView *_streamView;
    UIScreen *_screen;
    BOOL _streamingIsActive;
}

- (void)viewDidLoad
{
    Log(LOG_I, @"external viewDidLoad");
}

- (void)viewDidAppear:(BOOL)animated
{
#if TARGET_OS_TV
    LC_ASSERT(@"AppleTV should never have an external display");
#endif

    [super viewDidAppear:animated];

    Log(LOG_I, @"external viewDidAppear");

    _screen = self.view.window.screen;

    //    Log(LOG_I, @"Preparing External Screen");
    //    CGRect frame = extScreen.bounds;
    //    extScreen.overscanCompensation = 3;
    //    _extWindow = [[UIWindow alloc] initWithFrame:frame];
    //    _extWindow.screen = extScreen;
    //    _renderView.bounds = frame;
    //    _renderView.frame = frame;

    NSNotificationCenter* nc = [NSNotificationCenter defaultCenter];
    [nc postNotificationName:@"ScreenConnected" object:self];

//        [_extWindow addSubview:_renderView];
//        _extWindow.hidden = NO;
}

- (void)updatePreferredDisplayMode:(BOOL)streamActive {
}

@end
