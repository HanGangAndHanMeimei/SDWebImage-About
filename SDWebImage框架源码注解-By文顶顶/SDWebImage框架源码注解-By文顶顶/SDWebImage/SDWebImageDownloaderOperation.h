/*
 * This file is part of the SDWebImage package.
 * (c) Olivier Poitrey <rs@dailymotion.com>
 *
 * For the full copyright and license information, please view the LICENSE
 * file that was distributed with this source code.
 */

#import <Foundation/Foundation.h>
#import "SDWebImageDownloader.h"
#import "SDWebImageOperation.h"

//使用extern关键字标识 使用SDWebImageDownloadStartNotification等全局变量
extern NSString *const SDWebImageDownloadStartNotification;
extern NSString *const SDWebImageDownloadReceiveResponseNotification;
extern NSString *const SDWebImageDownloadStopNotification;
extern NSString *const SDWebImageDownloadFinishNotification;

@interface SDWebImageDownloaderOperation : NSOperation <SDWebImageOperation, NSURLSessionTaskDelegate, NSURLSessionDataDelegate>

/**
 * The request used by the operation's task.
 * 请求对象
 */
@property (strong, nonatomic, readonly) NSURLRequest *request;

/**
 * The operation's task
 * 请求的Task
 */
@property (strong, nonatomic, readonly) NSURLSessionTask *dataTask;

//图片是否需要进行解码操作
@property (assign, nonatomic) BOOL shouldDecompressImages;

/**
 *  Was used to determine whether the URL connection should consult the credential storage for authenticating the connection.
 *  @deprecated Not used for a couple of versions
 */
@property (nonatomic, assign) BOOL shouldUseCredentialStorage __deprecated_msg("Property deprecated. Does nothing. Kept only for backwards compatibility");

/**
 * The credential used for authentication challenges in `-connection:didReceiveAuthenticationChallenge:`.
 *
 * This will be overridden by any shared credentials that exist for the username or password of the request URL, if present.
 * 在 `-connection:didReceiveAuthenticationChallenge:` 方法中身份验证使用的凭据
 * 如果存在请求 URL 的用户名或密码的共享凭据，此凭据会被覆盖
 */
@property (nonatomic, strong) NSURLCredential *credential;

/**
 * The SDWebImageDownloaderOptions for the receiver.
 * 下载时的选项枚举
 */
@property (assign, nonatomic, readonly) SDWebImageDownloaderOptions options;

/**
 * The expected size of data.
 * 请求数据的期望大小（图片的大小）
 */
@property (assign, nonatomic) NSInteger expectedSize;

/**
 * The response returned by the operation's connection.
 * 网络请求的响应头信息
 */
@property (strong, nonatomic) NSURLResponse *response;

/**
 *  Initializes a `SDWebImageDownloaderOperation` object
 *  初始化一个 `SDWebImageDownloaderOperation` 对象
 *
 *  @see SDWebImageDownloaderOperation
 *
 *  @param request        the URL request 请求对象
 *  @param session        the URL session in which this operation will run 会话对象
 *  @param options        downloader options    下载选项
 *  @param progressBlock  the block executed when a new chunk of data arrives. 
 *                        @note the progress block is executed on a background queue 新的数据块到达时执行的 block(下载进度)，即进度回调
 *  @param completedBlock the block executed when the download is done. 
 *                        @note the completed block is executed on the main queue for success. If errors are found, there is a chance the block will be executed on a background queue
 *   1）下载结束后执行的 block
 *   2）注意：如果下载成功，completion block 在主队列执行。如果出现错误，block 可能会在后台队列执行
 *
 *  @param cancelBlock    the block executed if the download (operation) is cancelled 如果下载(操作)被取消，执行的 block
 *
 *  @return the initialized instance
 */
- (id)initWithRequest:(NSURLRequest *)request
            inSession:(NSURLSession *)session
              options:(SDWebImageDownloaderOptions)options
             progress:(SDWebImageDownloaderProgressBlock)progressBlock
            completed:(SDWebImageDownloaderCompletedBlock)completedBlock
            cancelled:(SDWebImageNoParamsBlock)cancelBlock;

//使用上面的方法来替代
/**
 *  Initializes a `SDWebImageDownloaderOperation` object
 *
 *  @see SDWebImageDownloaderOperation
 *
 *  @param request        the URL request
 *  @param options        downloader options
 *  @param progressBlock  the block executed when a new chunk of data arrives.
 *                        @note the progress block is executed on a background queue
 *  @param completedBlock the block executed when the download is done.
 *                        @note the completed block is executed on the main queue for success. If errors are found, there is a chance the block will be executed on a background queue
 *  @param cancelBlock    the block executed if the download (operation) is cancelled
 *
 *  @return the initialized instance. The operation will run in a separate session created for this operation
 */
- (id)initWithRequest:(NSURLRequest *)request
              options:(SDWebImageDownloaderOptions)options
             progress:(SDWebImageDownloaderProgressBlock)progressBlock
            completed:(SDWebImageDownloaderCompletedBlock)completedBlock
            cancelled:(SDWebImageNoParamsBlock)cancelBlock
__deprecated_msg("Method deprecated. Use `initWithRequest:inSession:options:progress:completed:cancelled`");

@end
