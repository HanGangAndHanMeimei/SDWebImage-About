/*
 * This file is part of the SDWebImage package.
 * (c) Olivier Poitrey <rs@dailymotion.com>
 *
 * For the full copyright and license information, please view the LICENSE
 * file that was distributed with this source code.
 */

#import "SDImageCache.h"
#import "SDWebImageDecoder.h"
#import "UIImage+MultiFormat.h"
#import <CommonCrypto/CommonDigest.h>

// See https://github.com/rs/SDWebImage/pull/1141 for discussion
// 请查看https://github.com/rs/SDWebImage/pull/1141 的讨论

#pragma mark --------------------
#pragma mark AutoPurgeCache

#warning SDWebImage框架内部使用NSCache进行内存缓存处理
//AutoPurgeCache 类继承自NSCache
/*
 1. NSCache简单说明
     1）NSCache是苹果官方提供的缓存类，具体使用和NSMutableDictionary类似，在AFN和SDWebImage框架中被使用来管理缓存
     2）苹果官方解释NSCache在系统内存很低时，会自动释放对象（但模拟器演示不会释放）
     建议：接收到内存警告时主动调用removeAllObject方法释放对象
     3）NSCache是线程安全的，在多线程操作中，不需要对NSCache加锁
     4）NSCache的Key只是对对象进行Strong引用，不是拷贝，在清理的时候计算的是实际大小而不是引用的大小

 2. NSCache属性和方法介绍
     1）属性介绍
         name:名称
         delegete:设置代理
         totalCostLimit：缓存空间的最大总成本，超出上限会自动回收对象。默认值为0，表示没有限制
         countLimit：能够缓存的对象的最大数量。默认值为0，表示没有限制
         evictsObjectsWithDiscardedContent：标识缓存是否回收废弃的内容
    2）方法介绍
         - (void)setObject:(ObjectType)obj forKey:(KeyType)key;//在缓存中设置指定键名对应的值，0成本
         - (void)setObject:(ObjectType)obj forKey:(KeyType)keycost:(NSUInteger)g;
         //在缓存中设置指定键名对应的值，并且指定该键值对的成本，用于计算记录在缓存中的所有对象的总成本
         //当出现内存警告或者超出缓存总成本上限的时候，缓存会开启一个回收过程，删除部分元素
         - (void)removeObjectForKey:(KeyType)key;//删除缓存中指定键名的对象
         - (void)removeAllObjects;//删除缓存中所有的对象
 */
@interface AutoPurgeCache : NSCache
@end

@implementation AutoPurgeCache

#pragma mark --------------------
#pragma mark AutoPurgeCache Life Cycle
- (id)init
{
    self = [super init];
    if (self) {

        //监听UIApplicationDidReceiveMemoryWarningNotification（系统内存警告）的通知，调用removeAllObjects方法清空所有的内存缓存
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(removeAllObjects) name:UIApplicationDidReceiveMemoryWarningNotification object:nil];
    }
    return self;
}

- (void)dealloc
{
    //移除监听
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationDidReceiveMemoryWarningNotification object:nil];

}

@end

//默认的最大缓存时间为1周
static const NSInteger kDefaultCacheMaxCacheAge = 60 * 60 * 24 * 7; // 1 week
// PNG signature bytes and data (below)
// PNG 签名字节和数据(PNG文件开始的8个字节是固定的)
static unsigned char kPNGSignatureBytes[8] = {0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A};
static NSData *kPNGSignatureData = nil;

//C语言的方法声明（判断传入的二进制数据是不是Png图片）
BOOL ImageDataHasPNGPreffix(NSData *data);

//方法的实现
BOOL ImageDataHasPNGPreffix(NSData *data) {

    //计算PNG签名数据的长度
    NSUInteger pngSignatureLength = [kPNGSignatureData length];
    //比较传入数据和PNG签名数据的长度，如果比签名数据长度更长，那么就只比较前面几个字节
    if ([data length] >= pngSignatureLength) {
        //比较前面的字节，如果内容一样则判定该图片是PNG格式的，返回YES，否则返回NO
        if ([[data subdataWithRange:NSMakeRange(0, pngSignatureLength)] isEqualToData:kPNGSignatureData]) {
            return YES;
        }
    }

    return NO;
}

//计算图片成本？= 图片的宽度*高度*缩放*缩放
FOUNDATION_STATIC_INLINE NSUInteger SDCacheCostForImage(UIImage *image) {
    return image.size.height * image.size.width * image.scale * image.scale;
}


#pragma mark --------------------
#pragma mark SDImageCache

//SDImageCache 继承自NSObject
//SDImageCache 类内部的_memCache属性为AutoPurgeCache类对象

@interface SDImageCache ()

@property (strong, nonatomic) NSCache *memCache;        //图片的内存缓存
@property (strong, nonatomic) NSString *diskCachePath;  //图片的磁盘缓存路径
@property (strong, nonatomic) NSMutableArray *customPaths; //自定义路径（可变数据）
@property (SDDispatchQueueSetterSementics, nonatomic) dispatch_queue_t ioQueue; //处理IO操作的队列

@end


@implementation SDImageCache {
    NSFileManager *_fileManager;    //文件管理者
}

#pragma mark --------------------
#pragma mark SDImageCache SingleMethods

//单例类方法，该方法提供一个全局的SDImageCache实例
+ (SDImageCache *)sharedImageCache {
    static dispatch_once_t once;
    static id instance;
    dispatch_once(&once, ^{
        instance = [self new];
    });
    return instance;
}

#pragma mark --------------------
#pragma mark SDImageCache Life Cycle

//初始化方法，默认的缓存空间名称为default
- (id)init {
    return [self initWithNamespace:@"default"];
}

//使用指定的命名空间实例化一个新的缓存存储
- (id)initWithNamespace:(NSString *)ns {
    //根据传入的命名空间设置磁盘缓存路径
    NSString *path = [self makeDiskCachePath:ns];
    return [self initWithNamespace:ns diskCacheDirectory:path];
}

//使用指定的命名空间实例化一个新的缓存存储和目录
//拼接完成的结果为：沙盒--》caches路径--》default--》com.hackemist.SDWebImageCache.default
- (id)initWithNamespace:(NSString *)ns diskCacheDirectory:(NSString *)directory {
    if ((self = [super init])) {

        //拼接默认的磁盘缓存目录
        NSString *fullNamespace = [@"com.hackemist.SDWebImageCache." stringByAppendingString:ns];

        // initialise PNG signature data
        // 初始化PNG数据签名 8字节
        kPNGSignatureData = [NSData dataWithBytes:kPNGSignatureBytes length:8];

        // Create IO serial queue
        // 创建处理IO操作的串行队列
        _ioQueue = dispatch_queue_create("com.hackemist.SDWebImageCache", DISPATCH_QUEUE_SERIAL);

        // Init default values
        // 初始化默认的最大缓存时间 == 1周
        _maxCacheAge = kDefaultCacheMaxCacheAge;

        // Init the memory cache
        // 初始化内存缓存，使用NSCache(AutoPurgeCache)
        _memCache = [[AutoPurgeCache alloc] init];

        //设置默认的缓存磁盘目录
        _memCache.name = fullNamespace;

        // Init the disk cache
        //初始化磁盘缓存，如果磁盘缓存路径不存在则设置为默认值，否则根据命名空间重新设置
        if (directory != nil) {
            //以默认值得方式拼接
            _diskCachePath = [directory stringByAppendingPathComponent:fullNamespace];
        } else {
            //根据命名空间重新设置
            NSString *path = [self makeDiskCachePath:ns];
            _diskCachePath = path;
        }

        // Set decompression to YES
        // 设置图片是否解压缩，默认为YES
        _shouldDecompressImages = YES;

        // memory cache enabled
        // 是否进行内存缓存（默认为YES）
        _shouldCacheImagesInMemory = YES;

        // Disable iCloud
        // 是否禁用iCloud备份,默认为YES
        _shouldDisableiCloud = YES;

        //同步函数+串行队列：在当前线程中同步的初始化文件管理者
        dispatch_sync(_ioQueue, ^{
            _fileManager = [NSFileManager new];
        });

#if TARGET_OS_IOS
        // Subscribe to app events
        //监听应用程序通知
        //当监听到UIApplicationDidReceiveMemoryWarningNotification（系统级内存警告）调用clearMemory方法
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(clearMemory)
                                                     name:UIApplicationDidReceiveMemoryWarningNotification
                                                   object:nil];

        //当监听到UIApplicationWillTerminateNotification（程序将终止）调用cleanDisk方法
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(cleanDisk)
                                                     name:UIApplicationWillTerminateNotification
                                                   object:nil];

        //当监听到UIApplicationDidEnterBackgroundNotification（进入后台），调用backgroundCleanDisk方法
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(backgroundCleanDisk)
                                                     name:UIApplicationDidEnterBackgroundNotification
                                                   object:nil];
#endif
    }

    return self;
}

//移除通知
- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    SDDispatchQueueRelease(_ioQueue);
}

#pragma mark --------------------
#pragma mark Methods
/**
* 如果希望在 bundle 中存储预加载的图像，可以添加一个只读的缓存路径
* 让 SDImageCache 从 Bundle 中搜索预先缓存的图像
* 只读缓存路径(mainBundle中的全路径)
*/
- (void)addReadOnlyCachePath:(NSString *)path {
    //如果自定义路径数组为空，那么先初始化
    if (!self.customPaths) {
        self.customPaths = [NSMutableArray new];
    }

    //如果之前没有该path，那么添加到数组中去
    if (![self.customPaths containsObject:path]) {
        [self.customPaths addObject:path];
    }
}

//获得指定 key 对应的缓存路径
- (NSString *)cachePathForKey:(NSString *)key inPath:(NSString *)path {
    //获得缓存文件的名称
    NSString *filename = [self cachedFileNameForKey:key];
    //返回拼接后的全路径
    return [path stringByAppendingPathComponent:filename];
}

//获得指定 key 的默认缓存路径
- (NSString *)defaultCachePathForKey:(NSString *)key {
    return [self cachePathForKey:key inPath:self.diskCachePath];
}

//对key(通常为URL)进行MD5加密，加密后的密文作为图片的名称
- (NSString *)cachedFileNameForKey:(NSString *)key {
    const char *str = [key UTF8String];
    if (str == NULL) {
        str = "";
    }

    //写数据：拿到图片的url作为key,对url进行md5加密，当图片下载完成后，传入url作为key计算得到加密后的32位字符密文作为图片的名称，调用下面的方法执行写文件到磁盘的操作
    /*- storeImage:(UIImage *)image recalculateFromImage:(BOOL)recalculate imageData:(NSData *)imageData forKey:(NSString *)key toDisk:(BOOL)toDisk*/
    //读数据：先判断是否有内存缓存，再判断是否有磁盘缓存（在判断的时候需要对该url进行MD5加密）拼接得到文件路径后，使用[NSData dataWithContentsOfFile...方法）加载对应的二进制数据。

    unsigned char r[CC_MD5_DIGEST_LENGTH];
    CC_MD5(str, (CC_LONG)strlen(str), r);
    NSString *filename = [NSString stringWithFormat:@"%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%@",
                          r[0], r[1], r[2], r[3], r[4], r[5], r[6], r[7], r[8], r[9], r[10],
                          r[11], r[12], r[13], r[14], r[15], [[key pathExtension] isEqualToString:@""] ? @"" : [NSString stringWithFormat:@".%@", [key pathExtension]]];

    return filename;
}

// Init the disk cache
//设置磁盘缓存路径
-(NSString *)makeDiskCachePath:(NSString*)fullNamespace{
    //获得caches路径，该框架内部对图片进行磁盘缓存，设置的缓存目录为沙盒中Library的caches目录下
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    //在caches目录下，新建一个名为【fullNamespace】的文件，沙盒缓存就保存在此处
    return [paths[0] stringByAppendingPathComponent:fullNamespace];
}

//使用指定的键将图像保存到内存和可选的磁盘缓存
- (void)storeImage:(UIImage *)image recalculateFromImage:(BOOL)recalculate imageData:(NSData *)imageData forKey:(NSString *)key toDisk:(BOOL)toDisk {

     //如果图片或对应的key为空，那么就直接返回
    if (!image || !key) {
        return;
    }
    // if memory cache is enabled
     //判断是否需要进行内存缓存，如果需要那么先计算图片成本，再保存到self.memCache中
    if (self.shouldCacheImagesInMemory) {
        //计算图片的Cost
        NSUInteger cost = SDCacheCostForImage(image);
        //把该图片保存到内存缓存中
        [self.memCache setObject:image forKey:key cost:cost];
    }

    //判断是否需要沙盒缓存
    if (toDisk) {

        //异步函数+串行队列：开子线程异步处理block中的任务
        dispatch_async(self.ioQueue, ^{
            //拿到服务器返回的图片二进制数据
            NSData *data = imageData;

            //如果图片存在且（直接使用imageData||imageData为空）
            if (image && (recalculate || !data)) {
#if TARGET_OS_IPHONE
                // We need to determine if the image is a PNG or a JPEG
                // PNGs are easier to detect because they have a unique signature (http://www.w3.org/TR/PNG-Structure.html)
                // The first eight bytes of a PNG file always contain the following (decimal) values:
                // 137 80 78 71 13 10 26 10

                // If the imageData is nil (i.e. if trying to save a UIImage directly or the image was transformed on download)
                // and the image has an alpha channel, we will consider it PNG to avoid losing the transparency
                //获得该图片的alpha信息
                int alphaInfo = CGImageGetAlphaInfo(image.CGImage);
                BOOL hasAlpha = !(alphaInfo == kCGImageAlphaNone ||
                                  alphaInfo == kCGImageAlphaNoneSkipFirst ||
                                  alphaInfo == kCGImageAlphaNoneSkipLast);
                //判断该图片是否是PNG图片
                BOOL imageIsPng = hasAlpha;

                // But if we have an image data, we will look at the preffix
                if ([imageData length] >= [kPNGSignatureData length]) {
                    imageIsPng = ImageDataHasPNGPreffix(imageData);
                }

                //如果判定是PNG图片，那么把图片转变为NSData压缩
                if (imageIsPng) {
                    data = UIImagePNGRepresentation(image);
                }
                else {
                     //否则采用JPEG的方式
                    data = UIImageJPEGRepresentation(image, (CGFloat)1.0);
                }
#else
                data = [NSBitmapImageRep representationOfImageRepsInArray:image.representations usingType: NSJPEGFileType properties:nil];
#endif
            }

            //对图片的二进制数据进行磁盘缓存
            [self storeImageDataToDisk:data forKey:key];
        });
    }
}

//使用指定的键将图像保存到内存和磁盘缓存
- (void)storeImage:(UIImage *)image forKey:(NSString *)key {
    [self storeImage:image recalculateFromImage:YES imageData:nil forKey:key toDisk:YES];
}

//使用指定的键将图像保存到内存和可选的磁盘缓存
- (void)storeImage:(UIImage *)image forKey:(NSString *)key toDisk:(BOOL)toDisk {
    [self storeImage:image recalculateFromImage:YES imageData:nil forKey:key toDisk:toDisk];
}

 //对图片的二进制数据进行磁盘缓存
- (void)storeImageDataToDisk:(NSData *)imageData forKey:(NSString *)key {

    //如果为空，那么直接返回
    if (!imageData) {
        return;
    }

    //确定_diskCachePath路径是否有效，如果无效则创建
    if (![_fileManager fileExistsAtPath:_diskCachePath]) {
        [_fileManager createDirectoryAtPath:_diskCachePath withIntermediateDirectories:YES attributes:nil error:NULL];
    }
    
    // get cache Path for image key
    // 根据key获得缓存路径
    NSString *cachePathForKey = [self defaultCachePathForKey:key];
    // transform to NSUrl
    //把路径转换为NSURL类型
    NSURL *fileURL = [NSURL fileURLWithPath:cachePathForKey];

    ////使用文件管理者在缓存路径创建文件，并设置数据
    [_fileManager createFileAtPath:cachePathForKey contents:imageData attributes:nil];
    
    // disable iCloud backup
    //判断是否禁用了iCloud备份
    if (self.shouldDisableiCloud) {
         //标记沙盒中不备份文件（标记该文件不备份）
        [fileURL setResourceValue:[NSNumber numberWithBool:YES] forKey:NSURLIsExcludedFromBackupKey error:nil];
    }
}

//检查图像是否已经在磁盘缓存中存在（不加载图像）
- (BOOL)diskImageExistsWithKey:(NSString *)key {

    //初始设置为NO
    BOOL exists = NO;
    
    // this is an exception to access the filemanager on another queue than ioQueue, but we are using the shared instance
    // from apple docs on NSFileManager: The methods of the shared NSFileManager object can be called from multiple threads safely.
    // 共享的 NSFileManager 对象可以保证在多线程运行时是安全的
    // 检查文件是否存在
    exists = [[NSFileManager defaultManager] fileExistsAtPath:[self defaultCachePathForKey:key]];
#warning 新增加了判断
    // fallback because of https://github.com/rs/SDWebImage/pull/976 that added the extension to the disk file name
    // checking the key with and without the extension
    if (!exists) {
        exists = [[NSFileManager defaultManager] fileExistsAtPath:[[self defaultCachePathForKey:key] stringByDeletingPathExtension]];
    }
    
    return exists;
}

//异步检查图像是否已经在磁盘缓存中存在（不加载图像）
- (void)diskImageExistsWithKey:(NSString *)key completion:(SDWebImageCheckCacheCompletionBlock)completionBlock {

    //异步函数+串行队列：开子线程异步检查文件是否存在
    dispatch_async(_ioQueue, ^{

        //同diskImageExistsWithKey方法
        BOOL exists = [_fileManager fileExistsAtPath:[self defaultCachePathForKey:key]];

        // fallback because of https://github.com/rs/SDWebImage/pull/976 that added the extension to the disk file name
        // checking the key with and without the extension
        if (!exists) {
            exists = [_fileManager fileExistsAtPath:[[self defaultCachePathForKey:key] stringByDeletingPathExtension]];
        }

        //在主线程回调completionBlock块
        if (completionBlock) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completionBlock(exists);
            });
        }
    });
}

//获取该key对应的图片缓存数据
- (UIImage *)imageFromMemoryCacheForKey:(NSString *)key {
    return [self.memCache objectForKey:key];
}

//查询内存缓存之后同步查询磁盘缓存
- (UIImage *)imageFromDiskCacheForKey:(NSString *)key {

    // First check the in-memory cache...
    //首先检查内存缓存，如果存在则直接返回
    UIImage *image = [self imageFromMemoryCacheForKey:key];
    if (image) {
        return image;
    }

    // Second check the disk cache...
    //接下来检查磁盘缓存，如果图片存在，且需要保存到内存缓存，则保存一份到内存缓存中
    UIImage *diskImage = [self diskImageForKey:key];
    if (diskImage && self.shouldCacheImagesInMemory) {
        //计算图片Cost
        NSUInteger cost = SDCacheCostForImage(diskImage);
        //把图片保存到内存缓存中
        [self.memCache setObject:diskImage forKey:key cost:cost];
    }

    //返回图片
    return diskImage;
}

//搜索AllPaths下是否存在图片的磁盘缓存
- (NSData *)diskImageDataBySearchingAllPathsForKey:(NSString *)key {
     //获得给key对应的默认的缓存路径
    NSString *defaultPath = [self defaultCachePathForKey:key];
    //加载该路径下面的二进制数据
    NSData *data = [NSData dataWithContentsOfFile:defaultPath];
    //如果有值，那么就直接返回
    if (data) {
        return data;
    }

    // fallback because of https://github.com/rs/SDWebImage/pull/976 that added the extension to the disk file name
    // checking the key with and without the extension
    // 检查Key 是否扩展（多次一次检查）
    data = [NSData dataWithContentsOfFile:[defaultPath stringByDeletingPathExtension]];
    if (data) {
        return data;
    }

    NSArray *customPaths = [self.customPaths copy];

    //遍历customPaths，若有值，则直接返回
    for (NSString *path in customPaths) {
        //得到缓存文件的全路径
        NSString *filePath = [self cachePathForKey:key inPath:path];
        //根据文件的全路径加载二进制数据
        NSData *imageData = [NSData dataWithContentsOfFile:filePath];
        //判断图片的二进制数据是否存在，如果有值那么久直接返回
        if (imageData) {
            return imageData;
        }

        //同上
        // fallback because of https://github.com/rs/SDWebImage/pull/976 that added the extension to the disk file name
        // checking the key with and without the extension
        imageData = [NSData dataWithContentsOfFile:[filePath stringByDeletingPathExtension]];
        if (imageData) {
            return imageData;
        }
    }

    return nil;
}

//获取指定Key对应的磁盘缓存，如果不存在则直接返回nil
- (UIImage *)diskImageForKey:(NSString *)key {
    //得到二进制数据
    NSData *data = [self diskImageDataBySearchingAllPathsForKey:key];
    if (data) {
        //把对应的二进制数据转换为图片
        UIImage *image = [UIImage sd_imageWithData:data];
         //处理图片的缩放
        image = [self scaledImageForKey:key image:image];
        //判断是否需要解压缩（解码）并进行相应的处理
        if (self.shouldDecompressImages) {
            image = [UIImage decodedImageWithImage:image];
        }
        //返回图片
        return image;
    }
    else {
        return nil;
    }
}

//处理图片的缩放等，2倍尺寸|3倍尺寸？
- (UIImage *)scaledImageForKey:(NSString *)key image:(UIImage *)image {
    return SDScaledImageForKey(key, image);
}

//检查要下载图片的缓存情况
/*
 1.先检查是否有内存缓存
 2.如果没有内存缓存则检查是否有沙盒缓存
 3.如果有沙盒缓存，则对该图片进行内存缓存处理并执行doneBlock回调
 */
- (NSOperation *)queryDiskCacheForKey:(NSString *)key done:(SDWebImageQueryCompletedBlock)doneBlock {

    //如果回调不存在，则直接返回
    if (!doneBlock) {
        return nil;
    }

    //如果缓存对应的key为空，则直接返回，并把存储方式（无缓存）通过block块以参数的形式传递
    if (!key) {
        doneBlock(nil, SDImageCacheTypeNone);
        return nil;
    }

    // First check the in-memory cache...
    //检查该KEY对应的内存缓存，如果存在内存缓存，则直接返回，并把图片和存储方式（内存缓存）通过block块以参数的形式传递
    UIImage *image = [self imageFromMemoryCacheForKey:key];
    if (image) {
        doneBlock(image, SDImageCacheTypeMemory);
        return nil;
    }

     //创建一个操作
    NSOperation *operation = [NSOperation new];
    //使用异步函数，添加任务到串行队列中（会开启一个子线程处理block块中的任务）
    dispatch_async(self.ioQueue, ^{
         //如果当前的操作被取消，则直接返回
        if (operation.isCancelled) {
            return;
        }

        @autoreleasepool {
            //检查该KEY对应的磁盘缓存
            UIImage *diskImage = [self diskImageForKey:key];
            //如果存在磁盘缓存，且应该把该图片保存一份到内存缓存中，则先计算该图片的cost(成本）并把该图片保存到内存缓存中
            if (diskImage && self.shouldCacheImagesInMemory) {
                //计算图片的Cost
                NSUInteger cost = SDCacheCostForImage(diskImage);
                //对该图片进行内存缓存处理
                [self.memCache setObject:diskImage forKey:key cost:cost];
            }

             //线程间通信，在主线程中回调doneBlock，并把图片和存储方式（磁盘缓存）通过block块以参数的形式传递
            dispatch_async(dispatch_get_main_queue(), ^{
                doneBlock(diskImage, SDImageCacheTypeDisk);
            });
        }
    });

    return operation;
}

//移除key对应的缓存，默认移除沙盒缓存
- (void)removeImageForKey:(NSString *)key {
    [self removeImageForKey:key withCompletion:nil];
}

//移除key对应的缓存，默认移除沙盒缓存
- (void)removeImageForKey:(NSString *)key withCompletion:(SDWebImageNoParamsBlock)completion {
    [self removeImageForKey:key fromDisk:YES withCompletion:completion];
}

//异步从内存和可选磁盘缓存删除图像
- (void)removeImageForKey:(NSString *)key fromDisk:(BOOL)fromDisk {
    [self removeImageForKey:key fromDisk:fromDisk withCompletion:nil];
}

//异步的从内存和可选磁盘缓存中删除图片
- (void)removeImageForKey:(NSString *)key fromDisk:(BOOL)fromDisk withCompletion:(SDWebImageNoParamsBlock)completion {

    //如果Key为空，则直接返回
    if (key == nil) {
        return;
    }

    //如果有内存缓存，则移除
    if (self.shouldCacheImagesInMemory) {
        [self.memCache removeObjectForKey:key];
    }

    //移除沙盒缓存操作处理
    if (fromDisk) {
        //开子线程异步执行，使用文件管理者移除指定路径的文件
        dispatch_async(self.ioQueue, ^{
            [_fileManager removeItemAtPath:[self defaultCachePathForKey:key] error:nil];

            //回到主线程中处理completion回调
            if (completion) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion();
                });
            }
        });
    } else if (completion){
        completion();
    }
    
}

//设置内存缓存（NSCache）能保存的最大成本
- (void)setMaxMemoryCost:(NSUInteger)maxMemoryCost {
    self.memCache.totalCostLimit = maxMemoryCost;
}

//最大内存缓存成本
- (NSUInteger)maxMemoryCost {
    return self.memCache.totalCostLimit;
}

//最大缓存的文件数量
- (NSUInteger)maxMemoryCountLimit {
    return self.memCache.countLimit;
}

//设置内存缓存（NSCache）的最大文件数量
- (void)setMaxMemoryCountLimit:(NSUInteger)maxCountLimit {
    self.memCache.countLimit = maxCountLimit;
}

//清除内存缓存
- (void)clearMemory {
     //把所有的内存缓存都删除
    [self.memCache removeAllObjects];
}

//清除磁盘缓存
- (void)clearDisk {
    [self clearDiskOnCompletion:nil];
}

//清除磁盘缓存（简单粗暴_直接全部删除）
- (void)clearDiskOnCompletion:(SDWebImageNoParamsBlock)completion
{
     //开子线程异步处理 清理磁盘缓存的操作
    dispatch_async(self.ioQueue, ^{
        //删除缓存文件夹
        [_fileManager removeItemAtPath:self.diskCachePath error:nil];
        //重新创建缓存目录
        [_fileManager createDirectoryAtPath:self.diskCachePath
                withIntermediateDirectories:YES
                                 attributes:nil
                                      error:NULL];

         //在主线程中处理completion回调
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion();
            });
        }
    });
}

//清除过期的磁盘缓存
- (void)cleanDisk {
    [self cleanDiskWithCompletionBlock:nil];
}

//清除过期的磁盘缓存
- (void)cleanDiskWithCompletionBlock:(SDWebImageNoParamsBlock)completionBlock {
    dispatch_async(self.ioQueue, ^{
        NSURL *diskCacheURL = [NSURL fileURLWithPath:self.diskCachePath isDirectory:YES];
        NSArray *resourceKeys = @[NSURLIsDirectoryKey, NSURLContentModificationDateKey, NSURLTotalFileAllocatedSizeKey];

        // This enumerator prefetches useful properties for our cache files.
        NSDirectoryEnumerator *fileEnumerator = [_fileManager enumeratorAtURL:diskCacheURL
                                                   includingPropertiesForKeys:resourceKeys
                                                                      options:NSDirectoryEnumerationSkipsHiddenFiles
                                                                 errorHandler:NULL];

        // 计算过期日期
        NSDate *expirationDate = [NSDate dateWithTimeIntervalSinceNow:-self.maxCacheAge];

        //初始化可变的缓存文件字典
        NSMutableDictionary *cacheFiles = [NSMutableDictionary dictionary];
        //初始化当前缓存的大小为0
        NSUInteger currentCacheSize = 0;

        // Enumerate all of the files in the cache directory.  This loop has two purposes:
        //
        //  1. Removing files that are older than the expiration date.
        //  2. Storing file attributes for the size-based cleanup pass.
        // 遍历缓存路径中的所有文件，此循环要实现两个目的
        //  1. 删除早于过期日期的文件
        //  2. 保存文件属性以计算磁盘缓存占用空间

        NSMutableArray *urlsToDelete = [[NSMutableArray alloc] init];
        for (NSURL *fileURL in fileEnumerator) {
            NSDictionary *resourceValues = [fileURL resourceValuesForKeys:resourceKeys error:NULL];

            // Skip directories.
            // 跳过目录
            if ([resourceValues[NSURLIsDirectoryKey] boolValue]) {
                continue;
            }

            // Remove files that are older than the expiration date;
            // 记录要删除的过期文件
            NSDate *modificationDate = resourceValues[NSURLContentModificationDateKey];
            if ([[modificationDate laterDate:expirationDate] isEqualToDate:expirationDate]) {
                [urlsToDelete addObject:fileURL];
                continue;
            }

            // Store a reference to this file and account for its total size.
            // 保存文件引用，以计算总大小
            NSNumber *totalAllocatedSize = resourceValues[NSURLTotalFileAllocatedSizeKey];
            currentCacheSize += [totalAllocatedSize unsignedIntegerValue];
            [cacheFiles setObject:resourceValues forKey:fileURL];
        }

        // 删除过期的文件
        for (NSURL *fileURL in urlsToDelete) {
            [_fileManager removeItemAtURL:fileURL error:nil];
        }

        // If our remaining disk cache exceeds a configured maximum size, perform a second
        // size-based cleanup pass.  We delete the oldest files first.

        //如果剩余磁盘缓存空间超出最大限额，再次执行清理操作，删除最早的文件
        if (self.maxCacheSize > 0 && currentCacheSize > self.maxCacheSize) {
            // Target half of our maximum cache size for this cleanup pass.
            const NSUInteger desiredCacheSize = self.maxCacheSize / 2;

            // Sort the remaining cache files by their last modification time (oldest first).
            NSArray *sortedFiles = [cacheFiles keysSortedByValueWithOptions:NSSortConcurrent
                                                            usingComparator:^NSComparisonResult(id obj1, id obj2) {
                                                                return [obj1[NSURLContentModificationDateKey] compare:obj2[NSURLContentModificationDateKey]];
                                                            }];

            // Delete files until we fall below our desired cache size.
             // 循环依次删除文件，直到低于期望的缓存限额
            for (NSURL *fileURL in sortedFiles) {
                if ([_fileManager removeItemAtURL:fileURL error:nil]) {
                    NSDictionary *resourceValues = cacheFiles[fileURL];
                    NSNumber *totalAllocatedSize = resourceValues[NSURLTotalFileAllocatedSizeKey];
                    currentCacheSize -= [totalAllocatedSize unsignedIntegerValue];

                    if (currentCacheSize < desiredCacheSize) {
                        break;
                    }
                }
            }
        }

        //在主线程中处理完成回调
        if (completionBlock) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completionBlock();
            });
        }
    });
}

//当进入后台后，处理的磁盘缓存清理工作
- (void)backgroundCleanDisk {
    Class UIApplicationClass = NSClassFromString(@"UIApplication");
    if(!UIApplicationClass || ![UIApplicationClass respondsToSelector:@selector(sharedApplication)]) {
        return;
    }

    //得到UIApplication单例对象
    UIApplication *application = [UIApplication performSelector:@selector(sharedApplication)];
    __block UIBackgroundTaskIdentifier bgTask = [application beginBackgroundTaskWithExpirationHandler:^{
        // Clean up any unfinished task business by marking where you
        // stopped or ending the task outright.

        // 清理任何未完成的任务
        [application endBackgroundTask:bgTask];
        bgTask = UIBackgroundTaskInvalid;
    }];

    // Start the long-running task and return immediately.
    // 启动长期运行的任务，并立即返回
    [self cleanDiskWithCompletionBlock:^{
        [application endBackgroundTask:bgTask];
        bgTask = UIBackgroundTaskInvalid;
    }];
}

//获得磁盘缓存文件的总大小
- (NSUInteger)getSize {
    __block NSUInteger size = 0;

    //同步+串行队列:在当前线程中执行block中的代码
    dispatch_sync(self.ioQueue, ^{
         //得到diskCachePath路径下面的所有子路径
        NSDirectoryEnumerator *fileEnumerator = [_fileManager enumeratorAtPath:self.diskCachePath];
        //遍历得到所有子路径对应文件的大小，并累加以计算所有文件的总大小
        for (NSString *fileName in fileEnumerator) {
            //拼接文件的全路径
            NSString *filePath = [self.diskCachePath stringByAppendingPathComponent:fileName];
            //获得指定文件的属性字典
            NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:filePath error:nil];
            //累加文件的大小 调用fileSize 获得文件的大小 == attrs["NSFileSzie"]
            size += [attrs fileSize];
        }
    });
    return size;
}

//获得磁盘缓存文件的数量
- (NSUInteger)getDiskCount {
    __block NSUInteger count = 0;
    dispatch_sync(self.ioQueue, ^{
        //根据计算该路径下面的子路径的数量得到
        NSDirectoryEnumerator *fileEnumerator = [_fileManager enumeratorAtPath:self.diskCachePath];
        count = [[fileEnumerator allObjects] count];
    });
    return count;
}

//异步计算磁盘缓存的大小
- (void)calculateSizeWithCompletionBlock:(SDWebImageCalculateSizeBlock)completionBlock {

     //把文件路径转换为URL
    NSURL *diskCacheURL = [NSURL fileURLWithPath:self.diskCachePath isDirectory:YES];

    //开子线程异步处理block块中的任务
    dispatch_async(self.ioQueue, ^{
        NSUInteger fileCount = 0;   //初始化文件的数量为0
        NSUInteger totalSize = 0;   //初始化缓存的总大小为0

        NSDirectoryEnumerator *fileEnumerator = [_fileManager enumeratorAtURL:diskCacheURL
                                                   includingPropertiesForKeys:@[NSFileSize]
                                                                      options:NSDirectoryEnumerationSkipsHiddenFiles
                                                                 errorHandler:NULL];

        for (NSURL *fileURL in fileEnumerator) {
            NSNumber *fileSize;
            [fileURL getResourceValue:&fileSize forKey:NSURLFileSizeKey error:NULL];
            totalSize += [fileSize unsignedIntegerValue];    //累加缓存的大小
            fileCount += 1;                                  //累加缓存文件的数量
        }

        //在主线程中处理completionBlock回调
        if (completionBlock) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completionBlock(fileCount, totalSize);
            });
        }
    });
}

@end
