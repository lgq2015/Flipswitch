#import "A3ToggleManagerMain.h"
#import "A3ToggleService.h"
#import "A3Toggle.h"

#import "LightMessaging/LightMessaging.h"

#define kTogglesPath @"/Library/Toggles/"

@implementation A3ToggleManagerMain

- (void)registerToggle:(id<A3Toggle>)toggle forIdentifier:(NSString *)toggleIdentifier
{
	[_toggleImplementations setObject:toggle forKey:toggleIdentifier];
}

- (void)unregisterToggleIdentifier:(NSString *)toggleIdentifier
{
	[_toggleImplementations removeObjectForKey:toggleIdentifier];
}

- (void)stateDidChangeForToggleIdentifier:(NSString *)toggleIdentifier
{
	// TODO: Notify others of state changes
}

- (NSArray *)toggleIdentifiers
{
	return [_toggleImplementations allKeys];
}

- (NSString *)titleForToggleID:(NSString *)toggleID
{
	id<A3Toggle> toggle = [_toggleImplementations objectForKey:toggleID];
	return [toggle titleForToggleIdentifier:toggleID];
}

- (BOOL)toggleStateForToggleID:(NSString *)toggleID
{
	id<A3Toggle> toggle = [_toggleImplementations objectForKey:toggleID];
	return [toggle stateForToggleIdentifier:toggleID];
}

- (void)setToggleState:(BOOL)state onToggleID:(NSString *)toggleID
{
	id<A3Toggle> toggle = [_toggleImplementations objectForKey:toggleID];
	[toggle applyState:state forToggleIdentifier:toggleID];
}

- (UIImage *)toggleImageForIdentifier:(NSString *)toggleID withBackground:(UIImage *)backgroundImage overlay:(UIImage *)overlayMask andState:(BOOL)state
{
	id<A3Toggle> toggle = [_toggleImplementations objectForKey:toggleID];
	if ([toggle respondsToSelector:@selector(imageForToggleIdentifier:withState:)])
	{
		UIImage *toggleMask = [toggle imageForToggleIdentifier:toggleID withState:state];
		UIImage *createdImage = [self processImageForBackground:backgroundImage withToggleMask:toggleMask withOverlay:overlayMask];
		return createdImage;
	}
	else
	{
		@throw [NSException exceptionWithName:NSInternalInconsistencyException reason:[NSString stringWithFormat:@"Toggle with ID %@ is required to implement imageForToggleIdentifier:withState:", toggleID] userInfo:nil];
	}

	return nil;
}

- (UIImage *)processImageForBackground:(UIImage *)backgroundImage withToggleMask:(UIImage *)toggleMask withOverlay:(UIImage *)overlay
{
	//TODO: Apply image mask and lay over background etc

	return nil;
}


static void processMessage(SInt32 messageId, mach_port_t replyPort, CFDataRef data)
{
	switch ((A3ToggleServiceMessage)messageId) {
		case A3ToggleServiceMessageGetIdentifiers:
			LMSendPropertyListReply(replyPort, [A3ToggleManager sharedInstance].toggleIdentifiers);
			return;
		case A3ToggleServiceMessageGetTitleForIdentifier: {
			NSString *identifier = [NSPropertyListSerialization propertyListFromData:(NSData *)data mutabilityOption:0 format:NULL errorDescription:NULL];
			if ([identifier isKindOfClass:[NSString class]]) {
				NSString *title = [[A3ToggleManager sharedInstance] titleForToggleID:identifier];
				LMSendPropertyListReply(replyPort, title);
				return;
			}
			break;
		}
		case A3ToggleServiceMessageGetStateForIdentifier: {
			NSString *identifier = [NSPropertyListSerialization propertyListFromData:(NSData *)data mutabilityOption:0 format:NULL errorDescription:NULL];
			if ([identifier isKindOfClass:[NSString class]]) {
				LMSendIntegerReply(replyPort, [[A3ToggleManager sharedInstance] toggleStateForToggleID:identifier]);
				return;
			}
			break;
		}
		case A3ToggleServiceMessageSetStateForIdentifier: {
			NSArray *args = [NSPropertyListSerialization propertyListFromData:(NSData *)data mutabilityOption:0 format:NULL errorDescription:NULL];
			if ([args isKindOfClass:[NSArray class]] && [args count] == 2) {
				NSNumber *state = [args objectAtIndex:0];
				NSString *identifier = [args objectAtIndex:1];
				if ([state isKindOfClass:[NSNumber class]] && [identifier isKindOfClass:[NSString class]]) {
					[[A3ToggleManager sharedInstance] setToggleState:[state integerValue] onToggleID:identifier];
				}
			}
			break;
		}
		case A3ToggleServiceMessageGetImageForIdentifierAndState: {
			NSDictionary *args = [NSPropertyListSerialization propertyListFromData:(NSData *)data mutabilityOption:0 format:NULL errorDescription:NULL];
			if ([args isKindOfClass:[NSDictionary class]]) {
				NSString *identifier = [args objectForKey:@"toggleID"];
				UIImage *backgroundImage = [args objectForKey:@"toggleBackground"];
				UIImage *overlayMask = [args objectForKey:@"toggleOverlay"];
				NSNumber *state = [args objectForKey:@"toggleState"];

				if (identifier != nil && backgroundImage != nil && overlayMask != nil && state != nil)
				{
					UIImage *image = [[A3ToggleManager sharedInstance] toggleImageForIdentifier:identifier withBackground:backgroundImage overlay:overlayMask andState:[state boolValue]];
					if (image != nil) LMSendImageReply(replyPort, image);
				}
			}
			break;
		}
	}
	LMSendReply(replyPort, NULL, 0);
}

static void machPortCallback(CFMachPortRef port, void *bytes, CFIndex size, void *info)
{
	LMMessage *request = bytes;
	if (size < sizeof(LMMessage)) {
		LMSendReply(request->head.msgh_remote_port, NULL, 0);
		LMResponseBufferFree(bytes);
		return;
	}
	// Send Response
	const void *data = LMMessageGetData(request);
	size_t length = LMMessageGetDataLength(request);
	mach_port_t replyPort = request->head.msgh_remote_port;
	CFDataRef cfdata = CFDataCreateWithBytesNoCopy(kCFAllocatorDefault, data ?: &data, length, kCFAllocatorNull);
	processMessage(request->head.msgh_id, replyPort, cfdata);
	if (cfdata)
		CFRelease(cfdata);
	LMResponseBufferFree(bytes);
}

- (id)init
{
	if ((self = [super init]))
	{
		mach_port_t bootstrap = MACH_PORT_NULL;
		task_get_bootstrap_port(mach_task_self(), &bootstrap);
		CFMachPortContext context = { 0, NULL, NULL, NULL, NULL };
		CFMachPortRef machPort = CFMachPortCreate(kCFAllocatorDefault, machPortCallback, &context, NULL);
		CFRunLoopSourceRef machPortSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, machPort, 0);
		CFRunLoopAddSource(CFRunLoopGetCurrent(), machPortSource, kCFRunLoopDefaultMode);
		mach_port_t port = CFMachPortGetPort(machPort);
		kern_return_t err = bootstrap_register(bootstrap, kA3ToggleServiceName, port);
		if (err) NSLog(@"A3 Toggle API: Connection Creation failed with Error: %x", err);

		_toggleImplementations = [[NSMutableDictionary alloc] init];
		NSArray *toggleDirectoryContents = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:kTogglesPath error:nil];
		for (NSString *folder in toggleDirectoryContents)
		{
			NSBundle *bundle = [NSBundle bundleWithPath:folder];
			if (bundle != nil)
			{
				Class toggleClass = [bundle principalClass];
				if ([toggleClass conformsToProtocol:@protocol(A3Toggle)])
				{
					id<A3Toggle> toggle = [[toggleClass alloc] init];
					if (toggle != nil) [_toggleImplementations setObject:toggle forKey:[bundle bundleIdentifier]];
					[toggle release];
				}
				else NSLog(@"Bundle with Identifier %@ doesn't conform to the defined Toggle Protocol", [bundle bundleIdentifier]);
			}
		}

	}
	return self;
}

- (void)dealloc
{
	[_toggleImplementations release];
	[super dealloc];
}

@end

__attribute__((constructor))
static void constructor(void)
{
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	// Initialize in SpringBoard automatically so that the bootstrap service gets registered
	if ([[NSBundle mainBundle].bundleIdentifier isEqualToString:@"com.apple.springboard"]) {
		[A3ToggleManager sharedInstance];
	}
	[pool drain];
}