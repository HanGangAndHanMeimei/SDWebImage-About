/*
 * This file is part of the SDWebImage package.
 * (c) Olivier Poitrey <rs@dailymotion.com>
 *
 * For the full copyright and license information, please view the LICENSE
 * file that was distributed with this source code.
 */

#import "SDWebImageDownloaderOperation.h"
#import "SDWebImageDecoder.h"
#import "UIImage+MultiFormat.h"
#import <ImageIO/ImageIO.h>
#import "SDWebImageManager.h"

//开始下载
NSString *const SDWebImageDownloadStartNotification = @"SDWebImageDownloadStartNotification";
//接受到响应
NSString *const SDWebImageDownloadReceiveResponseNotification = @"SDWebImageDownloadReceiveResponseNotification";
//下载停止
NSString *const SDWebImageDownloadStopNotification = @"SDWebImageDownloadStopNotification";
//下载完成
NSString *const SDWebImageDownloadFinishNotification = @"SDWebImageDownloadFinishNotification";

@interface SDWebImageDownloaderOperation ()

//进度回调
@property (copy, nonatomic) SDWebImageDownloaderProgressBlock progressBlock;
//完成后的回调
@property (copy, nonatomic) SDWebImageDownloaderCompletedBlock completedBlock;
//取消操作的回调
@property (copy, nonatomic) SDWebImageNoParamsBlock cancelBlock;

//是否正在执行
@property (assign, nonatomic, getter = isExecuting) BOOL executing;
//是否已经完成
@property (assign, nonatomic, getter = isFinished) BOOL finished;
//图片的二进制数据
@property (strong, nonatomic) NSMutableData *imageData;

// This is weak because it is injected by whoever manages this session. If this gets nil-ed out, we won't be able to run
// the task associated with this operation
@property (weak, nonatomic) NSURLSession *unownedSession;
// This is set if we're using not using an injected NSURLSession. We're responsible of invalidating this one
@property (strong, nonatomic) NSURLSession *ownedSession;

@property (strong, nonatomic, readwrite) NSURLSessionTask *dataTask;

//线程对象
@property (strong, atomic) NSThread *thread;

#if TARGET_OS_IPHONE && __IPHONE_OS_VERSION_MAX_ALLOWED >= __IPHONE_4_0
//通过UIBackgroundTaskIdentifier可以实现有限时间内在后台运行程序
@property (assign, nonatomic) UIBackgroundTaskIdentifier backgroundTaskId;
#endif

@end

@implementation SDWebImageDownloaderOperation {
    size_t width, height;           //宽度和高度，用来处理渐进式下载
    UIImageOrientation orientation;
    BOOL responseFromCached;
}

@synthesize executing = _executing;
@synthesize finished = _finished;

#pragma mark --------------------
#pragma mark Life Cycle
//初始化operation的方法
- (id)initWithRequest:(NSURLRequest *)request
              options:(SDWebImageDownloaderOptions)options
             progress:(SDWebImageDownloaderProgressBlock)progressBlock
            completed:(SDWebImageDownloaderCompletedBlock)completedBlock
            cancelled:(SDWebImageNoParamsBlock)cancelBlock {

    return [self initWithRequest:request
                       inSession:nil
                         options:options
                        progress:progressBlock
                       completed:completedBlock
                       cancelled:cancelBlock];
}

- (id)initWithRequest:(NSURLRequest *)request
            inSession:(NSURLSession *)session
              options:(SDWebImageDownloaderOptions)options
             progress:(SDWebImageDownloaderProgressBlock)progressBlock
            completed:(SDWebImageDownloaderCompletedBlock)completedBlock
            cancelled:(SDWebImageNoParamsBlock)cancelBlock {
    if ((self = [super init])) {
        _request = request;
        _shouldDecompressImages = YES;
        _options = options;
        _progressBlock = [progressBlock copy];
        _completedBlock = [completedBlock copy];
        _cancelBlock = [cancelBlock copy];
        _executing = NO;
        _finished = NO;
        _expectedSize = 0;
        _unownedSession = session;
        responseFromCached = YES; // Initially wrong until `- URLSession:dataTask:willCacheResponse:completionHandler: is called or not called
    }
    return self;
}

//addOperation--->start--->main
//核心方法：在该方法中处理图片下载操作
- (void)start {
    @synchronized (self) {
         //判断当前操作是否被取消，如果被取消了，则标记任务结束，并处理后续的block和清理操作
        if (self.isCancelled) {
            self.finished = YES;
            [self reset];
            return;
        }

        //条件编译，如果是iphone设备且大于4.0
#if TARGET_OS_IPHONE && __IPHONE_OS_VERSION_MAX_ALLOWED >= __IPHONE_4_0
        Class UIApplicationClass = NSClassFromString(@"UIApplication");
        BOOL hasApplication = UIApplicationClass && [UIApplicationClass respondsToSelector:@selector(sharedApplication)];
        //程序即将进入后台
        if (hasApplication && [self shouldContinueWhenAppEntersBackground]) {
            __weak __typeof__ (self) wself = self;
            //获得UIApplication单例对象
            UIApplication * app = [UIApplicationClass performSelector:@selector(sharedApplication)];
            //UIBackgroundTaskIdentifier：通过UIBackgroundTaskIdentifier可以实现有限时间内在后台运行程序
            //在后台获取一定的时间去指行我们的代码
            self.backgroundTaskId = [app beginBackgroundTaskWithExpirationHandler:^{
                __strong __typeof (wself) sself = wself;

                if (sself) {
                    [sself cancel]; //取消当前下载操作

                    [app endBackgroundTask:sself.backgroundTaskId];//结束后台任务
                    sself.backgroundTaskId = UIBackgroundTaskInvalid;
                }
            }];
        }
#endif
        NSURLSession *session = self.unownedSession;
        if (!self.unownedSession) {
            //创建会话对象的配置信息
            NSURLSessionConfiguration *sessionConfig = [NSURLSessionConfiguration defaultSessionConfiguration];
             //同一设置请求超时的时间为15m
            sessionConfig.timeoutIntervalForRequest = 15;
            
            /**
             *  Create the session for this task
             *  We send nil as delegate queue so that the session creates a serial operation queue for performing all delegate
             *  method calls and completion handler calls.
             */
            //根据配置信息来创建一个会话对象
            self.ownedSession = [NSURLSession sessionWithConfiguration:sessionConfig
                                                              delegate:self
                                                         delegateQueue:nil];
            session = self.ownedSession;
        }

        //根据会话对象来创建请求的dataTask
        self.dataTask = [session dataTaskWithRequest:self.request];
        //设置是否正在执行的属性为YES
        self.executing = YES;
        //获得当前线程
        self.thread = [NSThread currentThread];
    }

    //发送网络请求下载图片
    [self.dataTask resume];

    //处理进度回调
    if (self.dataTask) {
        if (self.progressBlock) {
            self.progressBlock(0, NSURLResponseUnknownLength);
        }

         //注册通知中心，在主线程中发送通知SDWebImageDownloadStartNotification【任务开始下载】
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:SDWebImageDownloadStartNotification object:self];
        });
    }
    else {
        //处理执行完毕之后的回调
        if (self.completedBlock) {
            self.completedBlock(nil, nil, [NSError errorWithDomain:NSURLErrorDomain code:0 userInfo:@{NSLocalizedDescriptionKey : @"Connection can't be initialized"}], YES);
        }
    }

#if TARGET_OS_IPHONE && __IPHONE_OS_VERSION_MAX_ALLOWED >= __IPHONE_4_0
    Class UIApplicationClass = NSClassFromString(@"UIApplication");
    if(!UIApplicationClass || ![UIApplicationClass respondsToSelector:@selector(sharedApplication)]) {
        return;
    }
    if (self.backgroundTaskId != UIBackgroundTaskInvalid) {
        UIApplication * app = [UIApplication performSelector:@selector(sharedApplication)];
        [app endBackgroundTask:self.backgroundTaskId];
        self.backgroundTaskId = UIBackgroundTaskInvalid;
    }
#endif
}

//取消的方法
- (void)cancel {
    @synchronized (self) {
        if (self.thread) {
            //如果当前线程存在，那么调用cancelInternalAndStop方法
            [self performSelector:@selector(cancelInternalAndStop) onThread:self.thread withObject:nil waitUntilDone:NO];
        }
        else {
            [self cancelInternal];
        }
    }
}
//取消和停止
- (void)cancelInternalAndStop {
    //如果已经完成则直接返回
    if (self.isFinished) return;
     //处理取消操作
    [self cancelInternal];
}

//取消网络请求
- (void)cancelInternal {
    //如果请求已经结束，那么久直接返回
    if (self.isFinished) return;
    [super cancel];
    //如果取消了，那么就调用cancel回调
    if (self.cancelBlock) self.cancelBlock();

    //如果连接对象存在，则取消网络请求
    if (self.dataTask) {
        [self.dataTask cancel];
         //注册通知中心，在主线程中发送通知SDWebImageDownloadStopNotification【下载任务停止】
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:SDWebImageDownloadStopNotification object:self];
        });

        //处理当前正在执行和是否已经完成
        // As we cancelled the connection, its callback won't be called and thus won't
        // maintain the isFinished and isExecuting flags.
        if (self.isExecuting) self.executing = NO;
        if (!self.isFinished) self.finished = YES;
    }

    //执行清理操作
    [self reset];
}

//任务执行完毕之后，修改当前任务的结束状态（YES）和执行状态（NO），执行清理操作
- (void)done {
    self.finished = YES;
    self.executing = NO;
    [self reset];
}

//清理操作
- (void)reset {
    self.cancelBlock = nil;
    self.completedBlock = nil;
    self.progressBlock = nil;
    self.dataTask = nil;
    self.imageData = nil;
    self.thread = nil;
    if (self.ownedSession) {
        [self.ownedSession invalidateAndCancel];
        self.ownedSession = nil;
    }
}

- (void)setFinished:(BOOL)finished {
    [self willChangeValueForKey:@"isFinished"];
    _finished = finished;
    [self didChangeValueForKey:@"isFinished"];
}

- (void)setExecuting:(BOOL)executing {
    [self willChangeValueForKey:@"isExecuting"];
    _executing = executing;
    [self didChangeValueForKey:@"isExecuting"];
}

- (BOOL)isConcurrent {
    return YES;
}

#pragma mark --------------------
#pragma mark NSURLSessionDataDelegate
//当接收到服务器响应的时候调用该方法
- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition disposition))completionHandler {
    
    //'304 Not Modified' is an exceptional one
    if (![response respondsToSelector:@selector(statusCode)] || ([((NSHTTPURLResponse *)response) statusCode] < 400 && [((NSHTTPURLResponse *)response) statusCode] != 304)) {
        NSInteger expected = response.expectedContentLength > 0 ? (NSInteger)response.expectedContentLength : 0;
        self.expectedSize = expected;
        if (self.progressBlock) {
            self.progressBlock(0, expected);
        }

        //初始化可变的data,用来拼接数据
        self.imageData = [[NSMutableData alloc] initWithCapacity:expected];
        self.response = response;

        //在主线程中发出通知：接收到响应
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:SDWebImageDownloadReceiveResponseNotification object:self];
        });
    }
    else {
        NSUInteger code = [((NSHTTPURLResponse *)response) statusCode];
        
        //This is the case when server returns '304 Not Modified'. It means that remote image is not changed.
        //In case of 304 we need just cancel the operation and return cached image from the cache.
        if (code == 304) {
            [self cancelInternal];  //如果服务器返回的响应状态码为304，那么直接取消请求
        } else {
            [self.dataTask cancel]; //取消网络请求
        }

        //主线程中发出通知，下载任务取消
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:SDWebImageDownloadStopNotification object:self];
        });

        //执行完成后的回调
        if (self.completedBlock) {
            self.completedBlock(nil, nil, [NSError errorWithDomain:NSURLErrorDomain code:[((NSHTTPURLResponse *)response) statusCode] userInfo:nil], YES);
        }
        [self done];
    }

    //告诉系统应该如何处理服务器返回的数据（接收）
    if (completionHandler) {
        completionHandler(NSURLSessionResponseAllow);
    }
}

//当接收到服务器返回数据的时候调用该方法（该方法可能会被调用多次）
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data {
    //使用可变的data来不断的拼接服务器返回的二进制数据
    [self.imageData appendData:data];

    //处理渐进式显示图片相关任务
    if ((self.options & SDWebImageDownloaderProgressiveDownload) && self.expectedSize > 0 && self.completedBlock) {
        // The following code is from http://www.cocoaintheshell.com/2011/05/progressive-images-download-imageio/
        // Thanks to the author @Nyx0uf

        // Get the total bytes downloaded
        //获得当前已经接收到的二进制数据大小
        const NSInteger totalSize = self.imageData.length;

        // Update the data source, we must pass ALL the data, not just the new bytes
         // 把图片的二进制数据转换为CGImageSourceRef
        CGImageSourceRef imageSource = CGImageSourceCreateWithData((__bridge CFDataRef)self.imageData, NULL);

        //如果是第一次（即接收到第一部分的图片数据）
        if (width + height == 0) {
            CFDictionaryRef properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, NULL);
            if (properties) {
                NSInteger orientationValue = -1;
                CFTypeRef val = CFDictionaryGetValue(properties, kCGImagePropertyPixelHeight);
                if (val) CFNumberGetValue(val, kCFNumberLongType, &height);
                val = CFDictionaryGetValue(properties, kCGImagePropertyPixelWidth);
                if (val) CFNumberGetValue(val, kCFNumberLongType, &width);
                val = CFDictionaryGetValue(properties, kCGImagePropertyOrientation);
                if (val) CFNumberGetValue(val, kCFNumberNSIntegerType, &orientationValue);
                CFRelease(properties);

                // When we draw to Core Graphics, we lose orientation information,
                // which means the image below born of initWithCGIImage will be
                // oriented incorrectly sometimes. (Unlike the image born of initWithData
                // in didCompleteWithError.) So save it here and pass it on later.
                orientation = [[self class] orientationFromPropertyValue:(orientationValue == -1 ? 1 : orientationValue)];
            }

        }

         //接收数据中期（之前接收过一部分，但为完全）
        if (width + height > 0 && totalSize < self.expectedSize) {
            // Create the image
            CGImageRef partialImageRef = CGImageSourceCreateImageAtIndex(imageSource, 0, NULL);

#ifdef TARGET_OS_IPHONE
            // Workaround for iOS anamorphic image
            if (partialImageRef) {
                const size_t partialHeight = CGImageGetHeight(partialImageRef);
                CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
                CGContextRef bmContext = CGBitmapContextCreate(NULL, width, height, 8, width * 4, colorSpace, kCGBitmapByteOrderDefault | kCGImageAlphaPremultipliedFirst);
                CGColorSpaceRelease(colorSpace);
                if (bmContext) {
                    CGContextDrawImage(bmContext, (CGRect){.origin.x = 0.0f, .origin.y = 0.0f, .size.width = width, .size.height = partialHeight}, partialImageRef);
                    CGImageRelease(partialImageRef);
                    partialImageRef = CGBitmapContextCreateImage(bmContext);
                    CGContextRelease(bmContext);
                }
                else {
                    CGImageRelease(partialImageRef);
                    partialImageRef = nil;
                }
            }
#endif

            if (partialImageRef) {
                UIImage *image = [UIImage imageWithCGImage:partialImageRef scale:1 orientation:orientation];
                NSString *key = [[SDWebImageManager sharedManager] cacheKeyForURL:self.request.URL];
                UIImage *scaledImage = [self scaledImageForKey:key image:image];
                if (self.shouldDecompressImages) {
                    image = [UIImage decodedImageWithImage:scaledImage];
                }
                else {
                    image = scaledImage;
                }
                //释放imageSource对象
                CGImageRelease(partialImageRef);
                dispatch_main_sync_safe(^{
                    if (self.completedBlock) {
                        self.completedBlock(image, nil, nil, NO);
                    }
                });
            }
        }

        CFRelease(imageSource);
    }

    //执行progressBlock，不断更新进度信息
    if (self.progressBlock) {
        self.progressBlock(self.imageData.length, self.expectedSize);
    }
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
 willCacheResponse:(NSCachedURLResponse *)proposedResponse
 completionHandler:(void (^)(NSCachedURLResponse *cachedResponse))completionHandler {

    responseFromCached = NO; // If this method is called, it means the response wasn't read from cache
    NSCachedURLResponse *cachedResponse = proposedResponse;

    if (self.request.cachePolicy == NSURLRequestReloadIgnoringLocalCacheData) {
        // Prevents caching of responses
        cachedResponse = nil;
    }
    if (completionHandler) {
        completionHandler(cachedResponse);
    }
}

#pragma mark --------------------
#pragma mark NSURLSessionTaskDelegate
//当请求完成或者是失败的时候调用该方法
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    @synchronized(self) {
        // 清空线程和请求task指针
        self.thread = nil;
        self.dataTask = nil;
        //在主线程中发出通知：下载任务停止|下载任务结束
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:SDWebImageDownloadStopNotification object:self];
            if (!error) {
                [[NSNotificationCenter defaultCenter] postNotificationName:SDWebImageDownloadFinishNotification object:self];
            }
        });
    }
    
    if (error) {
        if (self.completedBlock) {
            self.completedBlock(nil, nil, error, YES);
        }
    } else {
        SDWebImageDownloaderCompletedBlock completionBlock = self.completedBlock;
        
        if (![[NSURLCache sharedURLCache] cachedResponseForRequest:_request]) {
            responseFromCached = NO;
        }
        
        if (completionBlock) {
            if (self.options & SDWebImageDownloaderIgnoreCachedResponse && responseFromCached) {
                completionBlock(nil, nil, nil, YES);
            } else if (self.imageData) {
                //把二进制数据转换为图片
                UIImage *image = [UIImage sd_imageWithData:self.imageData];
                //得到图片的key
                NSString *key = [[SDWebImageManager sharedManager] cacheKeyForURL:self.request.URL];
                //处理缩放
                image = [self scaledImageForKey:key image:image];
                
                // Do not force decoding animated GIFs
                if (!image.images) {
                    //判断是否需要对图片进行解码操作
                    if (self.shouldDecompressImages) {
                        //对图片进行解码
                        image = [UIImage decodedImageWithImage:image];
                    }
                }
                if (CGSizeEqualToSize(image.size, CGSizeZero)) {
                    completionBlock(nil, nil, [NSError errorWithDomain:SDWebImageErrorDomain code:0 userInfo:@{NSLocalizedDescriptionKey : @"Downloaded image has 0 pixels"}], YES);
                }
                else {
                    completionBlock(image, self.imageData, nil, YES);
                }
            } else {
                completionBlock(nil, nil, [NSError errorWithDomain:SDWebImageErrorDomain code:0 userInfo:@{NSLocalizedDescriptionKey : @"Image data is nil"}], YES);
            }
        }
    }
    
    self.completionBlock = nil;
    [self done];
}

//如果发送的请求是一个HTTPS请求，则会调用该方法（接收到质询）
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition disposition, NSURLCredential *credential))completionHandler {
    
    NSURLSessionAuthChallengeDisposition disposition = NSURLSessionAuthChallengePerformDefaultHandling;
    __block NSURLCredential *credential = nil;
    
    if ([challenge.protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust]) {
        if (!(self.options & SDWebImageDownloaderAllowInvalidSSLCertificates)) {
            disposition = NSURLSessionAuthChallengePerformDefaultHandling;
        } else {
            credential = [NSURLCredential credentialForTrust:challenge.protectionSpace.serverTrust];
            disposition = NSURLSessionAuthChallengeUseCredential;
        }
    } else {
        if ([challenge previousFailureCount] == 0) {
            if (self.credential) {
                credential = self.credential;
                disposition = NSURLSessionAuthChallengeUseCredential;
            } else {
                disposition = NSURLSessionAuthChallengeCancelAuthenticationChallenge;
            }
        } else {
            disposition = NSURLSessionAuthChallengeCancelAuthenticationChallenge;
        }
    }

    //应该如何处理服务器发还的质询？认证信息
    if (completionHandler) {
        completionHandler(disposition, credential);
    }
}
#pragma mark --------------------
#pragma mark Helper methods
//处理渐进式显示图片的方法
+ (UIImageOrientation)orientationFromPropertyValue:(NSInteger)value {
    switch (value) {
        case 1:
            return UIImageOrientationUp;
        case 3:
            return UIImageOrientationDown;
        case 8:
            return UIImageOrientationLeft;
        case 6:
            return UIImageOrientationRight;
        case 2:
            return UIImageOrientationUpMirrored;
        case 4:
            return UIImageOrientationDownMirrored;
        case 5:
            return UIImageOrientationLeftMirrored;
        case 7:
            return UIImageOrientationRightMirrored;
        default:
            return UIImageOrientationUp;
    }
}

- (UIImage *)scaledImageForKey:(NSString *)key image:(UIImage *)image {
    return SDScaledImageForKey(key, image);
}

- (BOOL)shouldContinueWhenAppEntersBackground {
    return self.options & SDWebImageDownloaderContinueInBackground;
}

@end
