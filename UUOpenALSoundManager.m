//
//  UUOpenALSoundManager.m
//  Useful Utilities - OpenAL wrapper
//
//	License:
//  You are free to use this code for whatever purposes you desire. The only requirement is that you smile everytime you use it.
//
//  Contact: @cheesemaker or jon@threejacks.com

#import "UUOpenALSoundManager.h"
#import <OpenAL/al.h>
#import <OpenAL/alc.h>
#import <AudioToolbox/AudioToolbox.h>

///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - UUOpenALTools
///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

typedef ALvoid	AL_APIENTRY	(*alBufferDataStaticProcPtr) (const ALint bid, ALenum format, ALvoid* data, ALsizei size, ALsizei freq);

ALvoid UUBufferALAudioDataStatic(const ALint bid, ALenum format, ALvoid* data, ALsizei size, ALsizei freq)
{
	static	alBufferDataStaticProcPtr	proc = NULL;
    
    if (proc == NULL) 
    {
        proc = (alBufferDataStaticProcPtr) alcGetProcAddress(NULL, (const ALCchar*) "alBufferDataStatic");
    }
    
    if (proc)
    {
        proc(bid, format, data, size, freq);
    }
	
    return;
}

void* UUGetOpenALAudioData(CFURLRef inFileURL, ALsizei *outDataSize, ALenum *outDataFormat, ALsizei* outSampleRate)
{
	OSStatus						err = noErr;	
	SInt64							fileLengthInFrames = 0;
	AudioStreamBasicDescription		format;
	UInt32							propertySize = sizeof(format);
	ExtAudioFileRef					extRef = NULL;
	void*							data = NULL;
	AudioStreamBasicDescription		outputFormat;
    
	err = ExtAudioFileOpenURL(inFileURL, &extRef);
	if (err) 
    { 
        NSLog(@"ExtAudioFileOpenURL FAILED, Error = %ld", err);
        goto Exit; 
    }
	
	err = ExtAudioFileGetProperty(extRef, kExtAudioFileProperty_FileDataFormat, &propertySize, &format);
	if (err) 
    { 
        NSLog(@"ExtAudioFileGetProperty(kExtAudioFileProperty_FileDataFormat) FAILED, Error = %ld", err);
        goto Exit; 
    }
    
	if (format.mChannelsPerFrame > 2)  
    { 
        NSLog(@"Unsupported Format, channel count is greater than stereo");
        goto Exit;
    }
    
	// Default to 16 bit signed integer (native-endian) data
	outputFormat.mSampleRate = format.mSampleRate;
	outputFormat.mChannelsPerFrame = format.mChannelsPerFrame;
    
	outputFormat.mFormatID = kAudioFormatLinearPCM;
	outputFormat.mBytesPerPacket = 2 * outputFormat.mChannelsPerFrame;
	outputFormat.mFramesPerPacket = 1;
	outputFormat.mBytesPerFrame = 2 * outputFormat.mChannelsPerFrame;
	outputFormat.mBitsPerChannel = 16;
	outputFormat.mFormatFlags = kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked | kAudioFormatFlagIsSignedInteger;
	
	err = ExtAudioFileSetProperty(extRef, kExtAudioFileProperty_ClientDataFormat, sizeof(outputFormat), &outputFormat);
	if(err) 
    { 
        NSLog(@"ExtAudioFileSetProperty(kExtAudioFileProperty_ClientDataFormat) FAILED, Error = %ld", err);
        goto Exit; 
    }
	
	propertySize = sizeof(fileLengthInFrames);
	err = ExtAudioFileGetProperty(extRef, kExtAudioFileProperty_FileLengthFrames, &propertySize, &fileLengthInFrames);
	if(err) 
    { 
        NSLog(@"ExtAudioFileGetProperty(kExtAudioFileProperty_FileLengthFrames) FAILED, Error = %ld", err);
        goto Exit; 
    }
	
	UInt32		dataSize = fileLengthInFrames * outputFormat.mBytesPerFrame;;
	data = malloc(dataSize);
	if (data)
	{
		AudioBufferList		theDataBuffer;
		theDataBuffer.mNumberBuffers = 1;
		theDataBuffer.mBuffers[0].mDataByteSize = dataSize;
		theDataBuffer.mBuffers[0].mNumberChannels = outputFormat.mChannelsPerFrame;
		theDataBuffer.mBuffers[0].mData = data;
		
		err = ExtAudioFileRead(extRef, (UInt32*)&fileLengthInFrames, &theDataBuffer);
		if(err == noErr)
		{
			*outDataSize = (ALsizei)dataSize;
			*outDataFormat = (outputFormat.mChannelsPerFrame > 1) ? AL_FORMAT_STEREO16 : AL_FORMAT_MONO16;
			*outSampleRate = (ALsizei)outputFormat.mSampleRate;
		}
		else 
		{ 
			free (data);
			data = NULL; // make sure to return NULL
			NSLog(@"ExtAudioFileRead FAILED, Error = %ld", err);
            goto Exit;
		}	
	}
	
Exit:
	if (extRef)
		ExtAudioFileDispose(extRef);
		
	return data;
}

void UUHandleOpenALInterruption(void*	inClientData, UInt32 inInterruptionState)
{
    //NSLog(@"State=%ld", inInterruptionState);
}

void UUHandleOpenALRouteChanged(void* inClientData, AudioSessionPropertyID inID, UInt32 inDataSize, const void* inData)
{
    CFDictionaryRef dict = (CFDictionaryRef)inData;
     
    CFStringRef oldRoute = CFDictionaryGetValue(dict, CFSTR(kAudioSession_AudioRouteChangeKey_OldRoute));
     
    UInt32 size = sizeof(CFStringRef);
     
    CFStringRef newRoute;
    OSStatus result = AudioSessionGetProperty(kAudioSessionProperty_AudioRoute, &size, &newRoute);
     
    NSLog(@"result: %ld Route changed from %@ to %@", result, oldRoute, newRoute);
}

///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - UUOpenALSoundClip
///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////


@interface UUOpenALSoundClip()

	- (id) initWithContext:(ALCcontext*)context SoundFile:(NSURL*)soundFile;

	@property (nonatomic, assign) ALCcontext* openAlContext;
	@property (nonatomic, assign) ALuint source;
	@property (nonatomic, assign) ALuint buffer;
	@property (nonatomic, assign) void* rawData;
@end

@implementation UUOpenALSoundClip
@synthesize openAlContext = _openAlContext;
@synthesize source = _source;
@synthesize buffer = _buffer;
@synthesize rawData = _rawData;

- (id) initWithContext:(ALCcontext*)context SoundFile:(NSURL*)soundFile
{
    self = [super init];
    if (self)
    {
        self.openAlContext = context;
        
        // Make the new context the Current OpenAL Context
        alcMakeContextCurrent(_openAlContext);
        
        ALenum error = AL_NO_ERROR;
        alGetError(); // Clear the error
        
        // Create some OpenAL Buffer Objects
        alGenBuffers(1, &_buffer);
        if((error = alGetError()) != AL_NO_ERROR) 
        {
            NSLog(@"Error Generating Buffers: %x", error);
        }
        
        // Create some OpenAL Source Objects
        alGenSources(1, &_source);
        if(alGetError() != AL_NO_ERROR) 
        {
            NSLog(@"Error generating sources! %x\n", error);
        }
        
        alGetError(); // Clear the error
        
        ALenum  format;
        ALsizei size;
        ALsizei freq;
        _rawData = UUGetOpenALAudioData((CFURLRef)soundFile, &size, &format, &freq);

        if((error = alGetError()) != AL_NO_ERROR) 
        {
            NSLog(@"error loading sound: %x", error);
        }
        
        // use the static buffer data API
        UUBufferALAudioDataStatic(_buffer, format, _rawData, size, freq);
        
        if((error = alGetError()) != AL_NO_ERROR) 
        {
            NSLog(@"error attaching audio to buffer: %x", error);
        }		
        
        
        alGetError(); // Clear the error
        
        // Turn Looping OFF
        alSourcei(_source, AL_LOOPING, AL_FALSE);
        
        // Set Source Position
        CGPoint sourcePos = CGPointMake(0, -70);
        CGFloat distance = 25.0f;
        
        float sourcePosAL[] = {sourcePos.x, distance, sourcePos.y};
        alSourcefv(_source, AL_POSITION, sourcePosAL);
        
        // Set Source Reference Distance
        alSourcef(_source, AL_REFERENCE_DISTANCE, 50.0f);
        
        // attach OpenAL Buffer to OpenAL Source
        alSourcei(_source, AL_BUFFER, _buffer);
        
        if((error = alGetError()) != AL_NO_ERROR) 
        {
            NSLog(@"Error attaching buffer to source: %x\n", error);
        }	
        
        alSourcef(_source, AL_GAIN, 1.0f);
    }
    
    return self;
}

- (void) dealloc
{
    alDeleteSources(1, &_source);
    alDeleteBuffers(1, &_buffer);
    
    [super dealloc];
}

- (void) playSound:(float)volume
{
	alSourcef(_source, AL_GAIN, volume);
	alSourcePlay(_source);
}

@end

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - UUOpenALSoundManager
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

@interface UUOpenALSoundManager()
	@property (nonatomic, assign) ALCcontext* openAlContext;
	@property (nonatomic, assign) ALCdevice* openAlDevice;
@end

static UUOpenALSoundManager* theSoundManager = nil;

@implementation UUOpenALSoundManager

@synthesize openAlContext = _openAlContext;
@synthesize openAlDevice = _openAlDevice;

+ (UUOpenALSoundManager*) sharedSoundManager
{
    if (theSoundManager == nil)
    {
        theSoundManager = [[UUOpenALSoundManager alloc] init];
    }
    
    return theSoundManager;
}

- (id) init
{
    self = [super init];
    if (self)
    {
		// setup our audio session
		OSStatus result = AudioSessionInitialize(NULL, NULL, UUHandleOpenALInterruption, self);
		if (result == kAudioSessionNoError) 
        {
            BOOL isOtherMusicPlaying = [self isOtherMusicPlaying];
            
			// if the iPod is playing, use the ambient category to mix with it
			// otherwise, use solo ambient to get the hardware for playing the app background track
            // RCD: 2/1/2013 -- Hack to always ambient for ZDay 1.0 release
			UInt32 category = (isOtherMusicPlaying) ? kAudioSessionCategory_AmbientSound : kAudioSessionCategory_SoloAmbientSound;
            
			//TEST
			category = kAudioSessionCategory_AmbientSound;
			
			result = AudioSessionSetProperty(kAudioSessionProperty_AudioCategory, sizeof(category), &category);
			if (result) 
            {
                NSLog(@"Error setting audio session category! %ld\n", result);
            }
            
			result = AudioSessionAddPropertyListener(kAudioSessionProperty_AudioRouteChange, UUHandleOpenALRouteChanged, self);
			if (result) 
            {
                NSLog(@"Couldn't add listener: %ld", result);
            }
            
			result = AudioSessionSetActive(true);
			if (result) 
            {
                NSLog(@"Error setting audio session active! %ld\n", result);
            }
            
            
            // Create a new OpenAL Device
            // Pass NULL to specify the system’s default output device
            _openAlDevice = alcOpenDevice(NULL);
            if (_openAlDevice != NULL)
            {
                // Create a new OpenAL Context
                // The new context will render to the OpenAL Device just created 
                _openAlContext = alcCreateContext(_openAlDevice, 0);
                if (_openAlContext != NULL)
                {
                    // Make the new context the Current OpenAL Context
                    alcMakeContextCurrent(_openAlContext);
                }
            }
            // clear any errors
            alGetError();
		}
        else
        {
            NSLog(@"Error initializing audio session! %ld\n", result);
        }
    }
    
    return self;
}

- (void)dealloc
{
    // Shutdown OpenAL
    alcDestroyContext(_openAlContext);
    alcCloseDevice(_openAlDevice);
    
	[super dealloc];
}

- (void) disableOtherMusicPlaying
{
	UInt32 category = kAudioSessionCategory_SoloAmbientSound;
	AudioSessionSetProperty(kAudioSessionProperty_AudioCategory, sizeof(category), &category);
	category = kAudioSessionCategory_AmbientSound;
	AudioSessionSetProperty(kAudioSessionProperty_AudioCategory, sizeof(category), &category);
}

- (bool) isOtherMusicPlaying
{
    UInt32 isPlaying = 0;
    UInt32 size = sizeof(isPlaying);
    OSStatus result = AudioSessionGetProperty(kAudioSessionProperty_OtherAudioIsPlaying, &size, &isPlaying);
    if (result != kAudioSessionNoError) 
    {
        NSLog(@"Error getting other audio playing property! %ld", result);
    }
    
    return (isPlaying);
}

- (UUOpenALSoundClip*) soundClipFromResource:(NSString*)file Ext:(NSString*)ext
{
    NSURL* url = [NSURL fileURLWithPath:[[NSBundle mainBundle] pathForResource:file ofType:ext]];
    return [[[UUOpenALSoundClip alloc] initWithContext:_openAlContext SoundFile:url] autorelease];
}

@end
