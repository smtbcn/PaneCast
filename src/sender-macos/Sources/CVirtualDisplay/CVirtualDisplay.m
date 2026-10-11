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

    CGVirtualDisplaySettings *settings = [[settingsClass alloc] init];
    settings.hiDPI = 0;
    settings.modes = @[ [[modeClass alloc] initWithWidth:width height:height refreshRate:refreshRate] ];

    // Ayarı init sırasında vermek, ekranı WindowServer'da "bağlı" olarak yukarı kaldırıyor.
    // initWithDescriptor: + applySettings: yolu ekranı yaratıyor ama çevrimdışı bırakabiliyor;
    // ScreenCaptureKit o durumda ekranı hiç listelemiyor (ölçüldü: displayID 19, SCK listesinde yok).
    CGVirtualDisplay *display = nil;
    SEL initTwo = NSSelectorFromString(@"initWithDescriptor:settings:");
    if ([displayClass instancesRespondToSelector:initTwo]) {
        typedef CGVirtualDisplay *(*InitTwoFn)(id, SEL, CGVirtualDisplayDescriptor *, CGVirtualDisplaySettings *);
        InitTwoFn call = (InitTwoFn)[displayClass instanceMethodForSelector:initTwo];
        if (call) display = call([displayClass alloc], initTwo, descriptor, settings);
    }
    if (!display) {
        display = [[displayClass alloc] initWithDescriptor:descriptor];
    }
    if (!display) {
        if (error) *error = @"sanal ekran oluşturulamadı";
        return nil;
    }
    BOOL applied = (display.displayID != 0);
    if (!applied) {
        applied = [display applySettings:settings];
    }
    if (!applied || display.displayID == 0) {
        if (error) *error = @"sanal ekran kipi uygulanamadı";
        return nil;
    }

    PCVirtualDisplay *result = [[PCVirtualDisplay alloc] init];
    result->_display = display;
    // Ekranın çevrimiçi olması için kısa bir süre beklenir; durum loglanabilir metinle döner.
    result.lastState = [self describeDisplay:display.displayID];
    return result;
}

- (CGDirectDisplayID)displayID { return _display.displayID; }

+ (NSString *)describeDisplay:(CGDirectDisplayID)displayID {
    CGDirectDisplayID active[16], online[16];
    u_int32_t ac = 0, oc = 0;
    CGGetActiveDisplayList(16, active, &ac);
    CGGetOnlineDisplayList(16, online, &oc);
    BOOL inActive = NO, inOnline = NO;
    for (u_int32_t i = 0; i < ac; i++) if (active[i] == displayID) inActive = YES;
    for (u_int32_t i = 0; i < oc; i++) if (online[i] == displayID) inOnline = YES;
    CGDisplayModeRef mode = CGDisplayCopyDisplayMode(displayID);
    size_t mw = 0, mh = 0;
    if (mode) { mw = CGDisplayModeGetPixelWidth(mode); mh = CGDisplayModeGetPixelHeight(mode); CGDisplayModeRelease(mode); }
    NSMutableString *ids = [NSMutableString stringWithString:@"aktifKimlikler="];
    for (u_int32_t i = 0; i < ac; i++) [ids appendFormat:@"%u ", active[i]];
    return [NSString stringWithFormat:@"aktifListede=%@ cevrimiListede=%@ isActive=%d isOnline=%d isAsleep=%d isMain=%d kip=%zux%zu · %@",
            inActive ? @"EVET" : @"HAYIR", inOnline ? @"EVET" : @"HAYIR",
            CGDisplayIsActive(displayID), CGDisplayIsOnline(displayID),
            CGDisplayIsAsleep(displayID), CGDisplayIsMain(displayID), mw, mh, ids];
}

@end
