//
//  ASImageNode.mm
//  AsyncDisplayKit
//
//  Copyright (c) 2014-present, Facebook, Inc.  All rights reserved.
//  This source code is licensed under the BSD-style license found in the
//  LICENSE file in the root directory of this source tree. An additional grant
//  of patent rights can be found in the PATENTS file in the same directory.
//

#import "ASImageNode.h"

#import "_ASDisplayLayer.h"
#import "ASAssert.h"
#import "ASDisplayNode+Subclasses.h"
#import "ASDisplayNodeInternal.h"
#import "ASDisplayNodeExtras.h"
#import "ASDisplayNode+Beta.h"
#import "ASTextNode.h"
#import "ASImageNode+AnimatedImagePrivate.h"

#import "ASImageNode+CGExtras.h"
#import "AsyncDisplayKit+Debug.h"

#import "ASInternalHelpers.h"
#import "ASEqualityHelpers.h"
#import "ASEqualityHashHelpers.h"
#import "ASWeakMap.h"

#include <functional>

struct ASImageNodeDrawParameters {
  BOOL opaque;
  CGRect bounds;
  CGFloat contentsScale;
  UIColor *backgroundColor;
  UIViewContentMode contentMode;
  BOOL cropEnabled;
  BOOL forceUpscaling;
  CGRect cropRect;
  CGRect cropDisplayBounds;
  asimagenode_modification_block_t imageModificationBlock;
};

/**
 * Contains all data that is needed to generate the content bitmap.
 */
@interface ASImageNodeContentsKey : NSObject {}

@property (nonatomic, strong) UIImage *image;
@property CGSize backingSize;
@property CGRect imageDrawRect;
@property BOOL isOpaque;
@property (nonatomic, strong) UIColor *backgroundColor;
@property ASDisplayNodeContextModifier preContextBlock;
@property ASDisplayNodeContextModifier postContextBlock;
@property asimagenode_modification_block_t imageModificationBlock;

@end

@implementation ASImageNodeContentsKey

- (BOOL)isEqual:(id)object
{
  if (self == object) {
    return YES;
  }

  // Optimization opportunity: The `isKindOfClass` call here could be avoided by not using the NSObject `isEqual:`
  // convention and instead using a custom comparison function that assumes all items are heterogeneous.
  // However, profiling shows that our entire `isKindOfClass` expression is only ~1/40th of the total
  // overheard of our caching, so it's likely not high-impact.
  if ([object isKindOfClass:[ASImageNodeContentsKey class]]) {
    ASImageNodeContentsKey *other = (ASImageNodeContentsKey *)object;
    return [_image isEqual:other.image]
      && CGSizeEqualToSize(_backingSize, other.backingSize)
      && CGRectEqualToRect(_imageDrawRect, other.imageDrawRect)
      && _isOpaque == other.isOpaque
      && [_backgroundColor isEqual:other.backgroundColor]
      && _preContextBlock == other.preContextBlock
      && _postContextBlock == other.postContextBlock
      && _imageModificationBlock == other.imageModificationBlock;
  } else {
    return NO;
  }
}

- (NSUInteger)hash
{
  NSUInteger subhashes[] = {
    // Profiling shows that the work done in UIImage's `hash` is on the order of 0.005ms on an A5 processor
    // and isn't proportional to the size of the image.
    [_image hash],
    
    // TODO: Hashing the floats in a CGRect or CGSize is tricky.  Equality of floats is
    // fuzzy, but it's a 100% requirement that two equal values must produce an identical hash value.
    // Until there's a robust solution for hashing floats, leave all float values out of the hash.
    // This may lead to a greater number of isEqual comparisons but does not comprimise correctness.
    //AS::hash<CGRect>()(_backingSize),
    //AS::hash<CGRect>()(_imageDrawRect),

    AS::hash<BOOL>()(_isOpaque),
    [_backgroundColor hash],
    AS::hash<void *>()((void*)_preContextBlock),
    AS::hash<void *>()((void*)_postContextBlock),
    AS::hash<void *>()((void*)_imageModificationBlock),
  };
  return ASIntegerArrayHash(subhashes, sizeof(subhashes) / sizeof(subhashes[0]));
}

@end


@implementation ASImageNode
{
@private
  UIImage *_image;
  ASWeakMapEntry *_weakCacheEntry;  // Holds a reference that keeps our contents in cache.


  void (^_displayCompletionBlock)(BOOL canceled);
  
  // Drawing
  ASImageNodeDrawParameters _drawParameter;
  ASTextNode *_debugLabelNode;
  
  // Cropping.
  BOOL _cropEnabled; // Defaults to YES.
  BOOL _forceUpscaling; //Defaults to NO.
  CGRect _cropRect; // Defaults to CGRectMake(0.5, 0.5, 0, 0)
  CGRect _cropDisplayBounds; // Defaults to CGRectNull
}

@synthesize image = _image;
@synthesize imageModificationBlock = _imageModificationBlock;

#pragma mark - NSObject

+ (void)initialize
{
  [super initialize];
  
  if (self != [ASImageNode class]) {
    // Prevent custom drawing in subclasses
    ASDisplayNodeAssert(!ASSubclassOverridesClassSelector([ASImageNode class], self, @selector(displayWithParameters:isCancelled:)), @"Subclass %@ must not override displayWithParameters:isCancelled: method. Custom drawing in %@ subclass is not supported.", NSStringFromClass(self), NSStringFromClass([ASImageNode class]));
  }
}

- (instancetype)init
{
  if (!(self = [super init]))
    return nil;

  // TODO can this be removed?
  self.contentsScale = ASScreenScale();
  self.contentMode = UIViewContentModeScaleAspectFill;
  self.opaque = NO;
  
  // If no backgroundColor is set to the image node and it's a subview of UITableViewCell, UITableView is setting
  // the opaque value of all subviews to YES if highlighting / selection is happening and does not set it back to the
  // initial value. With setting a explicit backgroundColor we can prevent that change.
  self.backgroundColor = [UIColor clearColor];

  _cropEnabled = YES;
  _forceUpscaling = NO;
  _cropRect = CGRectMake(0.5, 0.5, 0, 0);
  _cropDisplayBounds = CGRectNull;
  _placeholderColor = ASDisplayNodeDefaultPlaceholderColor();
  _animatedImageRunLoopMode = ASAnimatedImageDefaultRunLoopMode;
  
  return self;
}

- (instancetype)initWithLayerBlock:(ASDisplayNodeLayerBlock)viewBlock didLoadBlock:(ASDisplayNodeDidLoadBlock)didLoadBlock
{
  ASDisplayNodeAssertNotSupported();
  return nil;
}

- (instancetype)initWithViewBlock:(ASDisplayNodeViewBlock)viewBlock didLoadBlock:(ASDisplayNodeDidLoadBlock)didLoadBlock
{
  ASDisplayNodeAssertNotSupported();
  return nil;
}

- (void)dealloc
{
  // Invalidate all components around animated images
  [self invalidateAnimatedImage];
}

#pragma mark - Layout and Sizing

- (CGSize)calculateSizeThatFits:(CGSize)constrainedSize
{
  ASDN::MutexLocker l(__instanceLock__);
  // if a preferredFrameSize is set, call the superclass to return that instead of using the image size.
  if (CGSizeEqualToSize(self.preferredFrameSize, CGSizeZero) == NO)
    return [super calculateSizeThatFits:constrainedSize];
  else if (_image)
    return _image.size;
  else
    return CGSizeZero;
}

#pragma mark - Setter / Getter

- (void)setImage:(UIImage *)image
{
  ASDN::MutexLocker l(__instanceLock__);
  if (!ASObjectIsEqual(_image, image)) {
    _image = image;
    
    [self invalidateCalculatedLayout];
    if (image) {
      [self setNeedsDisplay];
      
      if ([ASImageNode shouldShowImageScalingOverlay] && _debugLabelNode == nil) {
        ASPerformBlockOnMainThread(^{
          _debugLabelNode = [[ASTextNode alloc] init];
          _debugLabelNode.layerBacked = YES;
          [self addSubnode:_debugLabelNode];
        });
      }
    } else {
      self.contents = nil;
    }
  }
}

- (UIImage *)image
{
  ASDN::MutexLocker l(__instanceLock__);
  return _image;
}

- (void)setPlaceholderColor:(UIColor *)placeholderColor
{
  _placeholderColor = placeholderColor;

  // prevent placeholders if we don't have a color
  self.placeholderEnabled = placeholderColor != nil;
}

#pragma mark - Drawing

- (NSObject *)drawParametersForAsyncLayer:(_ASDisplayLayer *)layer
{
  ASDN::MutexLocker l(__instanceLock__);
  
  _drawParameter = {
    .bounds = self.bounds,
    .opaque = self.opaque,
    .contentsScale = _contentsScaleForDisplay,
    .backgroundColor = self.backgroundColor,
    .contentMode = self.contentMode,
    .cropEnabled = _cropEnabled,
    .forceUpscaling = _forceUpscaling,
    .cropRect = _cropRect,
    .cropDisplayBounds = _cropDisplayBounds,
    .imageModificationBlock = _imageModificationBlock
  };
  
  return nil;
}

- (NSDictionary *)debugLabelAttributes
{
  return @{
    NSFontAttributeName: [UIFont systemFontOfSize:15.0],
    NSForegroundColorAttributeName: [UIColor redColor]
  };
}

- (UIImage *)displayWithParameters:(id<NSObject> *)parameter isCancelled:(asdisplaynode_iscancelled_block_t)isCancelled
{
  UIImage *image = self.image;
  if (image == nil) {
    return nil;
  }
  
  CGRect drawParameterBounds    = CGRectZero;
  BOOL forceUpscaling           = NO;
  BOOL cropEnabled              = YES;
  BOOL isOpaque                 = NO;
  UIColor *backgroundColor      = nil;
  UIViewContentMode contentMode = UIViewContentModeScaleAspectFill;
  CGFloat contentsScale         = 0.0;
  CGRect cropDisplayBounds      = CGRectZero;
  CGRect cropRect               = CGRectZero;
  asimagenode_modification_block_t imageModificationBlock;

  {
    ASDN::MutexLocker l(__instanceLock__);
    ASImageNodeDrawParameters drawParameter = _drawParameter;
    
    drawParameterBounds       = drawParameter.bounds;
    forceUpscaling            = drawParameter.forceUpscaling;
    cropEnabled               = drawParameter.cropEnabled;
    isOpaque                  = drawParameter.opaque;
    backgroundColor           = drawParameter.backgroundColor;
    contentMode               = drawParameter.contentMode;
    contentsScale             = drawParameter.contentsScale;
    cropDisplayBounds         = drawParameter.cropDisplayBounds;
    cropRect                  = drawParameter.cropRect;
    imageModificationBlock    = drawParameter.imageModificationBlock;
  }
  
  BOOL hasValidCropBounds = cropEnabled && !CGRectIsNull(cropDisplayBounds) && !CGRectIsEmpty(cropDisplayBounds);
  CGRect bounds = (hasValidCropBounds ? cropDisplayBounds : drawParameterBounds);
  
  ASDisplayNodeContextModifier preContextBlock = self.willDisplayNodeContentWithRenderingContext;
  ASDisplayNodeContextModifier postContextBlock = self.didDisplayNodeContentWithRenderingContext;
  
  ASDisplayNodeAssert(contentsScale > 0, @"invalid contentsScale at display time");
  
  // if the image is resizable, bail early since the image has likely already been configured
  BOOL stretchable = !UIEdgeInsetsEqualToEdgeInsets(image.capInsets, UIEdgeInsetsZero);
  if (stretchable) {
    if (imageModificationBlock != NULL) {
      image = imageModificationBlock(image);
    }
    return image;
  }
  
  CGSize imageSize = image.size;
  CGSize imageSizeInPixels = CGSizeMake(imageSize.width * image.scale, imageSize.height * image.scale);
  CGSize boundsSizeInPixels = CGSizeMake(floorf(bounds.size.width * contentsScale), floorf(bounds.size.height * contentsScale));
  
  if (_debugLabelNode) {
    CGFloat pixelCountRatio            = (imageSizeInPixels.width * imageSizeInPixels.height) / (boundsSizeInPixels.width * boundsSizeInPixels.height);
    if (pixelCountRatio != 1.0) {
      NSString *scaleString            = [NSString stringWithFormat:@"%.2fx", pixelCountRatio];
      _debugLabelNode.attributedString = [[NSAttributedString alloc] initWithString:scaleString attributes:[self debugLabelAttributes]];
      _debugLabelNode.hidden           = NO;
      [self setNeedsLayout];
    } else {
      _debugLabelNode.hidden           = YES;
      _debugLabelNode.attributedString = nil;
    }
  }
  
  BOOL contentModeSupported = contentMode == UIViewContentModeScaleAspectFill ||
                              contentMode == UIViewContentModeScaleAspectFit ||
                              contentMode == UIViewContentModeCenter;
  
  CGSize backingSize   = CGSizeZero;
  CGRect imageDrawRect = CGRectZero;
  
  if (boundsSizeInPixels.width * contentsScale < 1.0f || boundsSizeInPixels.height * contentsScale < 1.0f ||
      imageSizeInPixels.width < 1.0f                  || imageSizeInPixels.height < 1.0f) {
    return nil;
  }
  
  // If we're not supposed to do any cropping, just decode image at original size
  if (!cropEnabled || !contentModeSupported || stretchable) {
    backingSize = imageSizeInPixels;
    imageDrawRect = (CGRect){.size = backingSize};
  } else {
    ASCroppedImageBackingSizeAndDrawRectInBounds(imageSizeInPixels,
                                                 boundsSizeInPixels,
                                                 contentMode,
                                                 cropRect,
                                                 forceUpscaling,
                                                 &backingSize,
                                                 &imageDrawRect);
  }
  
  if (backingSize.width <= 0.0f        || backingSize.height <= 0.0f ||
      imageDrawRect.size.width <= 0.0f || imageDrawRect.size.height <= 0.0f) {
    return nil;
  }

    ASImageNodeContentsKey *contentsKey = [[ASImageNodeContentsKey alloc] init];
    contentsKey.image = image;
    contentsKey.backingSize = backingSize;
    contentsKey.imageDrawRect = imageDrawRect;
    contentsKey.isOpaque = isOpaque;
    contentsKey.backgroundColor = backgroundColor;
    contentsKey.preContextBlock = preContextBlock;
    contentsKey.postContextBlock = postContextBlock;
    contentsKey.imageModificationBlock = imageModificationBlock;

    if (isCancelled()) {
        return nil;
    }

    ASWeakMapEntry<UIImage *> *entry = [self.class contentsForkey:contentsKey isCancelled:(asdisplaynode_iscancelled_block_t)isCancelled];
    if (entry == nil) {  // If nil, we were cancelled.
        return nil;
    }
    _weakCacheEntry = entry; // Retain so that the entry remains in the weak cache
    return entry.value;
}

static ASWeakMap<ASImageNodeContentsKey *, UIImage *> *cache = nil;
static ASDN::Mutex cacheLock;

+ (ASWeakMapEntry *)contentsForkey:(ASImageNodeContentsKey *)key isCancelled:(asdisplaynode_iscancelled_block_t)isCancelled
{
  {
    ASDN::MutexLocker l(cacheLock);
    if (!cache) {
      cache = [[ASWeakMap alloc] init];
    }
    ASWeakMapEntry *entry = [cache entryForKey:key];
    if (entry != nil) {
      // cache hit
      return entry;
    }
  }

  // cache miss
  UIImage *contents = [self createContentsForkey:key isCancelled:isCancelled];
  if (contents == nil) { // If nil, we were cancelled
    return nil;
  }

  {
    ASDN::MutexLocker l(cacheLock);
    return [cache setObject:contents forKey:key];
  }
}

+ (UIImage *)createContentsForkey:(ASImageNodeContentsKey *)key isCancelled:(asdisplaynode_iscancelled_block_t)isCancelled
{
  // The following `UIGraphicsBeginImageContextWithOptions` call will sometimes take take longer than 5ms on an
  // A5 processor for a 400x800 backingSize.
  // Check for cancellation before we call it.
  if (isCancelled()) {
    return nil;
  }

  // Use contentsScale of 1.0 and do the contentsScale handling in boundsSizeInPixels so ASCroppedImageBackingSizeAndDrawRectInBounds
  // will do its rounding on pixel instead of point boundaries
  UIGraphicsBeginImageContextWithOptions(key.backingSize, key.isOpaque, 1.0);
  
  CGContextRef context = UIGraphicsGetCurrentContext();
  if (context && key.preContextBlock) {
    key.preContextBlock(context);
  }
  
  // if view is opaque, fill the context with background color
  if (key.isOpaque && key.backgroundColor) {
    [key.backgroundColor setFill];
    UIRectFill({ .size = key.backingSize });
  }
  
  // iOS 9 appears to contain a thread safety regression when drawing the same CGImageRef on
  // multiple threads concurrently.  In fact, instead of crashing, it appears to deadlock.
  // The issue is present in Mac OS X El Capitan and has been seen hanging Pro apps like Adobe Premiere,
  // as well as iOS games, and a small number of ASDK apps that provide the same image reference
  // to many separate ASImageNodes.  A workaround is to set .displaysAsynchronously = NO for the nodes
  // that may get the same pointer for a given UI asset image, etc.
  // FIXME: We should replace @synchronized here, probably using a global, locked NSMutableSet, and
  // only if the object already exists in the set we should create a semaphore to signal waiting threads
  // upon removal of the object from the set when the operation completes.
  // Another option is to have ASDisplayNode+AsyncDisplay coordinate these cases, and share the decoded buffer.
  // Details tracked in https://github.com/facebook/AsyncDisplayKit/issues/1068
  
  @synchronized(key.image) {
    [key.image drawInRect:key.imageDrawRect];
  }
  
  if (context && key.postContextBlock) {
    key.postContextBlock(context);
  }

  // The following `UIGraphicsGetImageFromCurrentImageContext` call will commonly take more than 20ms on an
  // A5 processor.  Check for cancellation before we call it.
  if (isCancelled()) {
    UIGraphicsEndImageContext();
    return nil;
  }

  UIImage *result = UIGraphicsGetImageFromCurrentImageContext();
  
  UIGraphicsEndImageContext();
  
  if (key.imageModificationBlock != NULL) {
    result = key.imageModificationBlock(result);
  }
  
  return result;
}

- (void)displayDidFinish
{
  [super displayDidFinish];

  __instanceLock__.lock();
    void (^displayCompletionBlock)(BOOL canceled) = _displayCompletionBlock;
    UIImage *image = _image;
  __instanceLock__.unlock();
  
  // If we've got a block to perform after displaying, do it.
  if (image && displayCompletionBlock) {

    displayCompletionBlock(NO);

    __instanceLock__.lock();
      _displayCompletionBlock = nil;
    __instanceLock__.unlock();
  }
}

- (void)setNeedsDisplayWithCompletion:(void (^ _Nullable)(BOOL canceled))displayCompletionBlock
{
  if (self.displaySuspended) {
    if (displayCompletionBlock)
      displayCompletionBlock(YES);
    return;
  }

  // Stash the block and call-site queue. We'll invoke it in -displayDidFinish.
  ASDN::MutexLocker l(__instanceLock__);
  if (_displayCompletionBlock != displayCompletionBlock) {
    _displayCompletionBlock = [displayCompletionBlock copy];
  }

  [self setNeedsDisplay];
}

#pragma mark Interface State

- (void)clearContents
{
    [super clearContents];
    
    _weakCacheEntry = nil;  // release contents from the cache.
}

#pragma mark - Cropping

- (BOOL)isCropEnabled
{
  ASDN::MutexLocker l(__instanceLock__);
  return _cropEnabled;
}

- (void)setCropEnabled:(BOOL)cropEnabled
{
  [self setCropEnabled:cropEnabled recropImmediately:NO inBounds:self.bounds];
}

- (void)setCropEnabled:(BOOL)cropEnabled recropImmediately:(BOOL)recropImmediately inBounds:(CGRect)cropBounds
{
  ASDN::MutexLocker l(__instanceLock__);
  if (_cropEnabled == cropEnabled)
    return;

  _cropEnabled = cropEnabled;
  _cropDisplayBounds = cropBounds;

  // If we have an image to display, display it, respecting our recrop flag.
  if (self.image)
  {
    ASPerformBlockOnMainThread(^{
      if (recropImmediately)
        [self displayImmediately];
      else
        [self setNeedsDisplay];
    });
  }
}

- (CGRect)cropRect
{
  ASDN::MutexLocker l(__instanceLock__);
  return _cropRect;
}

- (void)setCropRect:(CGRect)cropRect
{
  ASDN::MutexLocker l(__instanceLock__);
  if (CGRectEqualToRect(_cropRect, cropRect))
    return;

  _cropRect = cropRect;

  // TODO: this logic needs to be updated to respect cropRect.
  CGSize boundsSize = self.bounds.size;
  CGSize imageSize = self.image.size;

  BOOL isCroppingImage = ((boundsSize.width < imageSize.width) || (boundsSize.height < imageSize.height));

  // Re-display if we need to.
  ASPerformBlockOnMainThread(^{
    if (self.nodeLoaded && self.contentMode == UIViewContentModeScaleAspectFill && isCroppingImage)
      [self setNeedsDisplay];
  });
}

- (BOOL)forceUpscaling
{
  ASDN::MutexLocker l(__instanceLock__);
  return _forceUpscaling;
}

- (void)setForceUpscaling:(BOOL)forceUpscaling
{
  ASDN::MutexLocker l(__instanceLock__);
  _forceUpscaling = forceUpscaling;
}

- (asimagenode_modification_block_t)imageModificationBlock
{
  ASDN::MutexLocker l(__instanceLock__);
  return _imageModificationBlock;
}

- (void)setImageModificationBlock:(asimagenode_modification_block_t)imageModificationBlock
{
  ASDN::MutexLocker l(__instanceLock__);
  _imageModificationBlock = imageModificationBlock;
}

#pragma mark - Debug

- (void)layout
{
  [super layout];
  
  if (_debugLabelNode) {
    CGSize boundsSize        = self.bounds.size;
    CGSize debugLabelSize    = [_debugLabelNode measure:boundsSize];
    CGPoint debugLabelOrigin = CGPointMake(boundsSize.width - debugLabelSize.width,
                                           boundsSize.height - debugLabelSize.height);
    _debugLabelNode.frame    = (CGRect) {debugLabelOrigin, debugLabelSize};
  }
}
@end

#pragma mark - Extras

extern asimagenode_modification_block_t ASImageNodeRoundBorderModificationBlock(CGFloat borderWidth, UIColor *borderColor)
{
  return ^(UIImage *originalImage) {
    UIGraphicsBeginImageContextWithOptions(originalImage.size, NO, originalImage.scale);
    UIBezierPath *roundOutline = [UIBezierPath bezierPathWithOvalInRect:(CGRect){CGPointZero, originalImage.size}];

    // Make the image round
    [roundOutline addClip];

    // Draw the original image
    [originalImage drawAtPoint:CGPointZero];

    // Draw a border on top.
    if (borderWidth > 0.0) {
      [borderColor setStroke];
      [roundOutline setLineWidth:borderWidth];
      [roundOutline stroke];
    }

    UIImage *modifiedImage = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return modifiedImage;
  };
}

extern asimagenode_modification_block_t ASImageNodeTintColorModificationBlock(UIColor *color)
{
  return ^(UIImage *originalImage) {
    UIGraphicsBeginImageContextWithOptions(originalImage.size, NO, originalImage.scale);
    
    // Set color and render template
    [color setFill];
    UIImage *templateImage = [originalImage imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    [templateImage drawAtPoint:CGPointZero];
    
    UIImage *modifiedImage = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();

    // if the original image was stretchy, keep it stretchy
    if (!UIEdgeInsetsEqualToEdgeInsets(originalImage.capInsets, UIEdgeInsetsZero)) {
      modifiedImage = [modifiedImage resizableImageWithCapInsets:originalImage.capInsets resizingMode:originalImage.resizingMode];
    }

    return modifiedImage;
  };
}
