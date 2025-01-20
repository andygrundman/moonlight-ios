// This is a version of StreamFrameViewController that runs on full-screen
// external displays. It only contains the video stream. UI, overlays, touch input
// and everything else remains on the main screen.

#import "Connection.h"
#import "StreamConfiguration.h"
#import "StreamView.h"

#import <UIKit/UIKit.h>

@interface ExternalStreamFrameViewController : UIViewController <UIScrollViewDelegate>

@property (nonatomic) StreamConfiguration* streamConfig;

-(void)updatePreferredDisplayMode:(BOOL)streamActive;

@end
