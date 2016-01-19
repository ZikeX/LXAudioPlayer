//
//  LXAudioPlayer.m
//  LXAudioPlayer
//
//  Created by 李 行 on 16/1/11.
//  Copyright © 2016年 lixing123.com. All rights reserved.
//

#import "LXAudioPlayer.h"
#import "LXHeader.h"
#import <AudioToolbox/AudioToolbox.h>
#import "LXRingBuffer.h"

typedef void (^failOperation) ();

typedef struct AudioConverterStruct{
    AudioBuffer audioBuffer;
    UInt32 packetCount;
    AudioStreamPacketDescription *packetDescriptions;
    BOOL used;
}AudioConverterStruct;

typedef struct
{
    BOOL done;
    UInt32 numberOfPackets;
    AudioBuffer audioBuffer;
    AudioStreamPacketDescription* packetDescriptions;
}
AudioConvertInfo;

static void handleError(OSStatus result, const char *failReason, failOperation operation)
{
    if (result == noErr) return;
    
    char errorString[20];
    *(UInt32 *)(errorString + 1) = CFSwapInt32HostToBig(result);
    if (isprint(errorString[1]) && isprint(errorString[2]) && isprint(errorString[3]) && isprint(errorString[4])) {
        errorString[0] = errorString[5] = '\'';
        errorString[6] = '\0';
    } else
        sprintf(errorString, "%d", (int)result);
    
    fprintf(stderr, "Error: %s (%s)\n", failReason, errorString);
    if (!operation) {
        exit(1);
    }else{
        operation();
    }
}

@interface LXAudioPlayer ()<NSStreamDelegate>{
}

@property(nonatomic)AUGraph graph;
@property(nonatomic)AudioUnit remoteIOUnit;
@property(nonatomic)NSURL *url;
@property(nonatomic)AudioFileStreamID stream;
@property(nonatomic)NSInputStream *inputStream;
@property(nonatomic)AudioStreamBasicDescription canonicalFormat;
@property(nonatomic)AudioStreamBasicDescription converterInputFormat;
@property(nonatomic)AudioConverterRef audioConverter;
@property(nonatomic)LXRingBuffer *ringBuffer;

- (void)setupAudioConverterWithSourceFormat:(AudioStreamBasicDescription *)sourceFormat;

@end

static OSStatus RemoteIOUnitCallback(void *							inRefCon,
                                     AudioUnitRenderActionFlags *	ioActionFlags,
                                     const AudioTimeStamp *			inTimeStamp,
                                     UInt32							inBusNumber,
                                     UInt32							inNumberFrames,
                                     AudioBufferList * __nullable	ioData){
    LXAudioPlayer *player = (__bridge LXAudioPlayer*)inRefCon;
    
    //read from ring buffer
    UInt32 ioDataByteSize = inNumberFrames*player.canonicalFormat.mBytesPerFrame;
    if ([player.ringBuffer hasDataAvailableForDequeue:ioDataByteSize]) {
        [player.ringBuffer dequeueData:ioData->mBuffers[0].mData dataByteLength:ioDataByteSize];
        ioData->mBuffers[0].mDataByteSize = ioDataByteSize;
        ioData->mBuffers[0].mNumberChannels = 1;
        ioData->mNumberBuffers = 1;
    }else{
        ioData->mBuffers[0].mData = calloc(ioDataByteSize, 1);
        ioData->mBuffers[0].mDataByteSize = ioDataByteSize;
        ioData->mBuffers[0].mNumberChannels = 1;
        ioData->mNumberBuffers = 1;
    }
    
    return noErr;
}

OSStatus MyAudioConverterComplexInputDataProc(AudioConverterRef               inAudioConverter,
                                              UInt32 *                        ioNumberDataPackets,
                                              AudioBufferList *               ioData,
                                              AudioStreamPacketDescription * __nullable * __nullable outDataPacketDescription,
                                              void * __nullable               inUserData){
    //LXLog(@"MyAudioConverterComplexInputDataProc");
    //supplies input data to AudioConverter and let the converter convert to PCM format
    AudioConvertInfo* convertInfo = (AudioConvertInfo*)inUserData;
    
    if (convertInfo->done)
    {
        ioNumberDataPackets = 0;
        
        return 100;
    }
    
    ioData->mNumberBuffers = 1;
    //将audioBuffer拷贝到converter的output中
    ioData->mBuffers[0] = convertInfo->audioBuffer;
    
    if (outDataPacketDescription)
    {
        *outDataPacketDescription = convertInfo->packetDescriptions;
    }
    
    *ioNumberDataPackets = convertInfo->numberOfPackets;
    convertInfo->done = YES;
    
    return 0;
}

void MyAudioFileStream_PropertyListenerProc(void *							inClientData,
                                            AudioFileStreamID				inAudioFileStream,
                                            AudioFileStreamPropertyID		inPropertyID,
                                            AudioFileStreamPropertyFlags *	ioFlags){
    LXAudioPlayer *player = (__bridge LXAudioPlayer*)inClientData;
    switch (inPropertyID) {
        case kAudioFileStreamProperty_DataFormat:{
            AudioStreamBasicDescription inputFormat;
            UInt32 size = sizeof(inputFormat);
            handleError(AudioFileStreamGetProperty(inAudioFileStream,
                                                   kAudioFileStreamProperty_DataFormat,
                                                   &size,
                                                   &inputFormat),
                        "failed to get input stream's data format",
                        ^{
                            
                        });
            [player setupAudioConverterWithSourceFormat:&inputFormat];
            break;
        }
        default:
            break;
    }
}

void MyAudioFileStream_PacketsProc (void *							inClientData,
                                    UInt32							inNumberBytes,
                                    UInt32							inNumberPackets,
                                    const void *					inInputData,
                                    AudioStreamPacketDescription	*inPacketDescriptions){
    //LXLog(@"%s",__func__);
    LXAudioPlayer *player = (__bridge LXAudioPlayer*)inClientData;
    
    //define input data of audio converter
    AudioConvertInfo convertInfo;
    
    convertInfo.done = NO;
    convertInfo.numberOfPackets = inNumberPackets;
    convertInfo.packetDescriptions = inPacketDescriptions;
    convertInfo.audioBuffer.mData = (void *)inInputData;
    convertInfo.audioBuffer.mDataByteSize = inNumberBytes;
    convertInfo.audioBuffer.mNumberChannels = player.converterInputFormat.mChannelsPerFrame;
    
    //define output data of audio converter
    while (1) {
        UInt32 maxBufferSize = 1024;
        AudioBufferList bufferList;
        bufferList.mNumberBuffers = 1;
        AudioBuffer *buffer = &bufferList.mBuffers[0];
        buffer->mNumberChannels = player.canonicalFormat.mChannelsPerFrame;
        buffer->mDataByteSize = maxBufferSize;
        buffer->mData = malloc(maxBufferSize);
        OSStatus result = AudioConverterFillComplexBuffer(player.audioConverter,
                                                          MyAudioConverterComplexInputDataProc,
                                                          &convertInfo,
                                                          &maxBufferSize,
                                                          &bufferList,
                                                          NULL);
        //LXLog(@"after AudioConverterFillComplexBuffer");
        //LXLog(@"converted buffer size:%d",maxBufferSize);
        
        if (result==0) {
            //store bufferList
            if ([player.ringBuffer hasSpaceAvailableForEnqueue:buffer->mDataByteSize]) {
                BOOL enqueueResult = [player.ringBuffer euqueueData:buffer->mData
                                                     dataByteLength:maxBufferSize*player.canonicalFormat.mBytesPerFrame];
                //LXLog(@"enqueue data %@",enqueueResult?@"succeed":@"failed");
            }else{
                //LXLog(@"no space for enqueue data");
            }
        }else if (result==100){//need data from AudioFileStream
            //LXLog(@"need data from AudioFileStream");
            return;
        }else{//
            //LXLog(@"AudioConverterFillComplexBuffer error:%d",result);
            return;
        }
    }
}

@implementation LXAudioPlayer

#pragma mark -

- (id)initWithURL:(NSURL *)url {
    if (self=[super init]) {
        self.url = url;
        
        [self setupInputStream];
        
        [self setupAudioFileStreamService];
        
        //set up graph
        [self setupGraph];
    }
    
    return self;
}

- (void)play {
    handleError(AUGraphStart(_graph),
                "AUGraphStart failed",
                ^{
                    
                });
    LXLog(@"play");
}

- (void)pause {
    handleError(AUGraphStop(_graph),
                "AUGraphStop failed",
                ^{
                    
                });
}

- (void)stop {
    
}

- (void)seekToTime:(float)seekTime {
    
}

//- (void)enableCache:(BOOL)cacheEnabled{}

- (void)setCacheURL:(NSURL *)cacheURL {
    
}

#pragma mark -

- (void)setupInputStream{
    self.inputStream = [[NSInputStream alloc] initWithURL:self.url];
    self.inputStream.delegate = self;
    [self.inputStream scheduleInRunLoop:[NSRunLoop currentRunLoop]
                                forMode:NSDefaultRunLoopMode];
    [self.inputStream open];
}

- (void)setupAudioFileStreamService{
    handleError(AudioFileStreamOpen((__bridge void*)self,
                                    MyAudioFileStream_PropertyListenerProc,
                                    MyAudioFileStream_PacketsProc,
                                    0,//TODO:define file type hint based on file extension
                                    &_stream),
                "failed to open audio file stream",
                ^{
                    
                });
}

- (void)setupAudioConverterWithSourceFormat:(AudioStreamBasicDescription *)sourceFormat{
    AudioStreamBasicDescription streamFormat = self.canonicalFormat;
    AudioConverterRef audioConverter;
    AudioConverterNew(sourceFormat,
                      &streamFormat,
                      &audioConverter);
    self.audioConverter = audioConverter;
    self.converterInputFormat = *sourceFormat;
}

- (void)setupGraph{
    handleError(NewAUGraph(&_graph),
                "NewAUGraph failed",
                ^{
                    
                });
    
    //create RemoteIO audio unit
    AudioComponentDescription remoteIODescription = {0};
    remoteIODescription.componentType = kAudioUnitType_Output;
    remoteIODescription.componentSubType = kAudioUnitSubType_RemoteIO;
    remoteIODescription.componentManufacturer = kAudioUnitManufacturer_Apple;
    
    AUNode remoteIONode;
    handleError(AUGraphAddNode(_graph,
                               &remoteIODescription,
                               &remoteIONode),
                "add RemoteIO node to graph failed",
                ^{
                    
                });
    handleError(AUGraphOpen(_graph),
                "open graph failed",
                ^{
                    
                });
    handleError(AUGraphNodeInfo(_graph,
                                remoteIONode,
                                NULL,
                                &_remoteIOUnit),
                "AUGraphNodeInfo failed",
                ^{
                    
                });
    
    //open output hardware(speaker) of remoteIO unit
    UInt32 enableIO = 1;
    UInt32 size = sizeof(enableIO);
    
    handleError(AudioUnitSetProperty(_remoteIOUnit,
                                     kAudioOutputUnitProperty_EnableIO,
                                     kAudioUnitScope_Output,
                                     0,
                                     &enableIO,
                                     size),
                "enable speaker of remoteIO failed",
                ^{
                    
                });
    
    //set input stream format of remoteIO unit
    //TODO: stream format should be set at the beginning of class init
    AudioStreamBasicDescription streamFormat = {0};
    streamFormat.mFormatID = kAudioFormatLinearPCM;
    streamFormat.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    streamFormat.mSampleRate = 44100.0;
    streamFormat.mFramesPerPacket = 1;
    streamFormat.mBytesPerPacket = 4;
    streamFormat.mBytesPerFrame = 4;
    streamFormat.mChannelsPerFrame = 2;
    streamFormat.mBitsPerChannel = 16;
    handleError(AudioUnitSetProperty(_remoteIOUnit,
                                     kAudioUnitProperty_StreamFormat,
                                     kAudioUnitScope_Input,
                                     0,
                                     &streamFormat,
                                     sizeof(streamFormat)),
                "unable to set stream format of remoteIO unit",
                ^{
                    
                });
    self.canonicalFormat = streamFormat;
    
    //init ring buffer
    self.ringBuffer = [[LXRingBuffer alloc] initWithDataPCMFormat:self.canonicalFormat seconds:50.0];
    
    //set render callback of remoteIO unit
    AURenderCallbackStruct callbackStruct;
    callbackStruct.inputProc = RemoteIOUnitCallback;
    //why need __bridge void*???
    callbackStruct.inputProcRefCon = (__bridge void*)self;
    handleError(AudioUnitSetProperty(_remoteIOUnit,
                                     kAudioUnitProperty_SetRenderCallback,
                                     kAudioUnitScope_Input,
                                     0,
                                     &callbackStruct,
                                     sizeof(callbackStruct)),
                "unable to set render callback of remoteIO unit",
                ^{
                    
                });
    
    handleError(AUGraphInitialize(_graph),
                "initialize graph failed",
                ^{
                    
                });
}

#pragma mark - NSStreamDelegate

- (void)stream:(NSStream *)aStream handleEvent:(NSStreamEvent)eventCode {
    switch (eventCode) {
        case NSStreamEventNone:
            
            break;
        case NSStreamEventOpenCompleted:
            
            break;
            
        case NSStreamEventHasBytesAvailable:{
            //read from input file
            //TODO:figure out buffer size
            UInt32 bufferSize = 1024;
            UInt8 *inputBuffer = calloc(sizeof(UInt8), bufferSize);
            NSInteger readLength;
            if (self.inputStream.hasBytesAvailable) {
                readLength = [self.inputStream read:inputBuffer
                                          maxLength:bufferSize];
            }else{
                LXLog(@"input stream has no data available");
            }
            
            AudioFileStreamParseBytes(self.stream,
                                      (UInt32)readLength,
                                      inputBuffer,
                                      0);
            
            break;
        }
        case NSStreamEventErrorOccurred:
            
            break;
        case NSStreamEventEndEncountered:
            
            break;
        default:
            break;
    }
}

@end















