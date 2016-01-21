//
//  LXRingBuffer.m
//  LXAudioPlayer
//
//  Created by 李 行 on 16/1/13.
//  Copyright © 2016年 lixing123.com. All rights reserved.
//

#import "LXRingBuffer.h"
#import "LXHeader.h"
#import "libkern/OSAtomic.h"

//TODO define a OSSpinLock block

@interface LXRingBuffer (){
    AudioBufferList audioBufferList;
    //TODO: it seems that using multiple AudioBuffer is also possible
    AudioBuffer *audioBuffer;
    
    UInt32 totalByteCount;
    UInt32 currentByteIndex;
    UInt32 currentUsedByteCount;
    
    //TODO:add support for multithread
    OSSpinLock spinLock;
}

@end

@implementation LXRingBuffer

- (id)initWithDataPCMFormat:(AudioStreamBasicDescription)pcmFormat seconds:(float)seconds{
    if (self=[super init]) {
        //init audioBuffer
        UInt32 bufferSize = pcmFormat.mSampleRate * seconds * pcmFormat.mBytesPerFrame;
        audioBuffer = &audioBufferList.mBuffers[0];
        audioBufferList.mNumberBuffers = 1;
        audioBufferList.mBuffers[0].mDataByteSize = bufferSize;
        //TODO:AudioBufferList.mNumberChannels should always 1???
        audioBufferList.mBuffers[0].mNumberChannels = 2;
        audioBufferList.mBuffers[0].mData = (void*)calloc(audioBuffer->mDataByteSize, 1);
        
        totalByteCount = bufferSize;
        currentByteIndex = 0;
        currentUsedByteCount = 0;
        
        //LXLog(@"total byte count of ring buffer:%d",bufferSize);
    }
    return self;
}

- (BOOL)needToBeFilled {
    OSSpinLockLock(&spinLock);
    BOOL result = ((float)currentUsedByteCount/(float)totalByteCount<0.7);
    OSSpinLockUnlock(&spinLock);
    return result;
}

- (BOOL)hasSpaceAvailableForEnqueue:(UInt32)spaceSize {
    OSSpinLockLock(&spinLock);
    BOOL result = totalByteCount-currentUsedByteCount >= spaceSize;
    OSSpinLockUnlock(&spinLock);
    return result;
}

- (BOOL)hasDataAvailableForDequeue:(UInt32)dataSize {
    OSSpinLockLock(&spinLock);
    BOOL result = currentUsedByteCount >= dataSize;
    OSSpinLockUnlock(&spinLock);
    return result;
}

- (BOOL)euqueueData:(void *)data dataByteLength:(UInt32)dataByteSize {
    //if available bytes space is smaller than size of inserted data, return NO
    if (![self hasSpaceAvailableForEnqueue:dataByteSize]) {
        return NO;
    }
    
    OSSpinLockLock(&spinLock);
    UInt32 start = currentByteIndex;
    UInt32 used = currentUsedByteCount;
    OSSpinLockUnlock(&spinLock);
    
    LXLog(@"ring buffer status before enqueue:startIndex:%d     framesUsed:%d     data size:%d",start,used,dataByteSize);
    
    //does buffer has a continuous space to save audio?
    BOOL hasContinuousSpace = NO;
    if (start+used>totalByteCount) {
        hasContinuousSpace = YES;
    }else if (totalByteCount-start-used>dataByteSize){
        hasContinuousSpace = YES;
    }
    UInt32 end = (start+used)%totalByteCount;

    //if buffer has a continuous space to save data, just save data
    //TODO:add pthread lock
    if (hasContinuousSpace) {
        memcpy(audioBuffer->mData+end, data, dataByteSize);
    }
    else{
        //first, copy part of data to the end of buffer
        memcpy(audioBuffer->mData+end, data, (totalByteCount-end));
        //second, copy remaining of data to the start of buffer
        UInt32 remainingSize = dataByteSize-(totalByteCount-end);
        memcpy(audioBuffer->mData, data+(totalByteCount-end), remainingSize);
    }
    
    OSSpinLockLock(&spinLock);
    currentUsedByteCount += dataByteSize;
    OSSpinLockUnlock(&spinLock);
    LXLog(@"ring buffer status after  enqueue:startIndex:%d     framesUsed:%d",currentByteIndex,currentUsedByteCount);
    return YES;
}

- (BOOL)dequeueData:(void *)data dataByteLength:(UInt32)dataByteSize {
    if (![self hasDataAvailableForDequeue:dataByteSize]) {
        return NO;
    }
    OSSpinLockLock(&spinLock);
    UInt32 start = currentByteIndex;
    OSSpinLockUnlock(&spinLock);
    LXLog(@"ring buffer status before dequeue: startIndex:%d     framesUsed:%d      data size:%d",currentByteIndex,currentUsedByteCount,dataByteSize);
    
    //does the buffer has a continuous data?
    BOOL hasContinuousData = NO;
    OSSpinLockLock(&spinLock);
    if ((totalByteCount-start)>=dataByteSize) {
        hasContinuousData = YES;
    }
    OSSpinLockUnlock(&spinLock);
    
    //if has continuous data, just copy it
    if (hasContinuousData) {
        memcpy(data, audioBuffer->mData+start, dataByteSize);
    }else{
        UInt32 firstPartDataSize = (totalByteCount-start);
        //first copy part of data from currentFrameIndex to end of buffer
        memcpy(data, audioBuffer->mData+start, firstPartDataSize);
        //second copy remaining data from start of buffer
        memcpy(data+firstPartDataSize, audioBuffer->mData, dataByteSize-firstPartDataSize);
    }
    
    OSSpinLockLock(&spinLock);
    currentByteIndex = (currentByteIndex+dataByteSize)%totalByteCount;
    currentUsedByteCount -= dataByteSize;
    OSSpinLockUnlock(&spinLock);
    LXLog(@"ring buffer status after  dequeue: startIndex:%d     framesUsed:%d      data size:%d",currentByteIndex,currentUsedByteCount,dataByteSize);
    
    return NO;
}

@end
