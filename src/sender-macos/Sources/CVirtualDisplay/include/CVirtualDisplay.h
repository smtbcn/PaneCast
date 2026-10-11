#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

// CoreGraphics'in HERKESE AÇIK OLMAYAN sanal ekran sınıflarının arayüzleri.
// Çalışma anında NSClassFromString ile bulunur (bağlama bağımlılığı yok);
// gelecekte bir macOS güncellemesi bunları kaldırırsa mod kapanır, uygulama çökmez.

@interface CGVirtualDisplayMode : NSObject
@property(readonly, nonatomic) unsigned int width;
@property(readonly, nonatomic) unsigned int height;
@property(readonly, nonatomic) double refreshRate;
- (instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property(nonatomic) unsigned int hiDPI;
@property(retain, nonatomic) NSArray<CGVirtualDisplayMode *> *modes;
@end

@interface CGVirtualDisplayDescriptor : NSObject
@property(retain, nonatomic) NSString *name;
@property(nonatomic) unsigned int maxPixelsHigh;
@property(nonatomic) unsigned int maxPixelsWide;
@property(nonatomic) CGSize sizeInMillimeters;
@property(nonatomic) unsigned int productID;
@property(nonatomic) unsigned int vendorID;
@property(nonatomic) unsigned int serialNum;
@property(retain, nonatomic) dispatch_queue_t queue;
@end

@interface CGVirtualDisplay : NSObject
@property(readonly, nonatomic) unsigned int displayID;
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end

/// Swift'e açılan ince sarmalayıcı. Nesne yaşadıkça ekran vardır; bırakılınca (ya da süreç ölünce) kaybolur.
@interface PCVirtualDisplay : NSObject
/// Özel sınıflar yoksa ya da ekran kurulamazsa nil döner ve `error`a nedeni yazar.
+ (nullable instancetype)createWithName:(NSString *)name
                                  width:(unsigned int)width
                                 height:(unsigned int)height
                            refreshRate:(double)refreshRate
                                  error:(NSString * _Nullable * _Nullable)error;
@property(readonly, nonatomic) CGDirectDisplayID displayID;
@end
