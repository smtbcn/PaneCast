#import "CVirtualDisplay.h"

@implementation PCVirtualDisplay {
    CGVirtualDisplay *_display;   // güçlü referans: oturum boyunca ekranı ayakta tutar
}

+ (instancetype)createWithName:(NSString *)name
                         width:(unsigned int)width
                        height:(unsigned int)height
                   refreshRate:(double)refreshRate
                         error:(NSString **)error {
    Class descriptorClass = NSClassFromString(@"CGVirtualDisplayDescriptor");
    Class settingsClass = NSClassFromString(@"CGVirtualDisplaySettings");
    Class modeClass = NSClassFromString(@"CGVirtualDisplayMode");
    Class displayClass = NSClassFromString(@"CGVirtualDisplay");
    if (!descriptorClass || !settingsClass || !modeClass || !displayClass) {
        if (error) *error = @"bu macOS sürümünde sanal ekran sınıfları yok (özel API kaldırılmış olabilir)";
        return nil;
    }

    CGVirtualDisplayDescriptor *descriptor = [[descriptorClass alloc] init];
    descriptor.name = name;
    descriptor.maxPixelsWide = width;
    descriptor.maxPixelsHigh = height;
    // 55" TV (~1220x690 mm): macOS ekranı TV boyutunda bir monitör sayar.
    descriptor.sizeInMillimeters = CGSizeMake(1220, 690);
    descriptor.vendorID = 0x5043;     // "PC"
    descriptor.productID = 0x0001;
    descriptor.serialNum = 1;
    descriptor.queue = dispatch_get_main_queue();

    CGVirtualDisplay *display = [[displayClass alloc] initWithDescriptor:descriptor];
    if (!display) {
        if (error) *error = @"sanal ekran oluşturulamadı";
        return nil;
    }
    CGVirtualDisplaySettings *settings = [[settingsClass alloc] init];
    settings.hiDPI = 0;
    settings.modes = @[ [[modeClass alloc] initWithWidth:width height:height refreshRate:refreshRate] ];
    if (![display applySettings:settings] || display.displayID == 0) {
        if (error) *error = @"sanal ekran kipi uygulanamadı";
        return nil;
    }

    PCVirtualDisplay *result = [[PCVirtualDisplay alloc] init];
    result->_display = display;
    return result;
}

- (CGDirectDisplayID)displayID { return _display.displayID; }

@end
