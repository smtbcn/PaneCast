#import "CVirtualDisplay.h"

@interface PCVirtualDisplay ()
@property(readwrite, nonatomic, copy, nullable) NSString *lastState;
@end

@implementation PCVirtualDisplay {
    CGVirtualDisplay *_display;   // güçlü referans: oturum boyunca ekranı ayakta tutar
    CGVirtualDisplaySettings *_settings;
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

    // Ayarları init'te vermek en temiz yol; bu macOS'ta initWithDescriptor:settings: yok
    // (ölçüldü: instancesRespondToSelector=NO) → selector runtime'da sorulur, tek init'e düşülür.
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
    BOOL applied = [display applySettings:settings];
    if (display.displayID == 0) {
        if (error) *error = @"sanal ekran kipi uygulanamadı (displayID 0)";
        return nil;
    }
    // displayID'nin dolu olması ekranın BAĞLI olduğu anlamına gelmiyor: tek applySettings YES
    // döndürmesine rağmen ekran çevrimiçi kalmıyor (ölçüldü: isOnline=0, SCK listesi boş).
    // İkinci uygulama anında çevrimiçi yapıyor → ekran çevrimiçi olana kadar yeniden denenir.
    applied = [display applySettings:settings];
    for (int tries = 0; tries < 12 && ![self isOnline:display.displayID]; tries++) {
        applied = [display applySettings:settings];
        usleep(20000);
    }
    NSLog(@"PaneCast sanal ekran: displayID=%u applySettings=%d %@",
          (unsigned)display.displayID, applied, [self describeDisplay:display.displayID]);

    PCVirtualDisplay *result = [[PCVirtualDisplay alloc] init];
    result->_display = display;
    result->_settings = settings;
    result.lastState = [NSString stringWithFormat:@"applySettings=%d · %@", applied,
                        [self describeDisplay:display.displayID]];
    return result;
}

- (CGDirectDisplayID)displayID { return _display.displayID; }

/// Kipi yeniden uygular ve çevrimiçi olup olmadığını döner.
- (BOOL)reapply {
    [_display applySettings:_settings];
    return [PCVirtualDisplay isOnline:_display.displayID];
}

/// CGDisplayIsOnline doğrulanmış değer döndürmüyor (uygulama içinde -1 ölçüldü) →
/// tek güvenilir okuma çevrimiçi/aktif listelerinde kimliğin aranması.
+ (BOOL)isOnline:(CGDirectDisplayID)displayID {
    CGDirectDisplayID online[16];
    u_int32_t count = 0;
    CGGetOnlineDisplayList(16, online, &count);
    for (u_int32_t i = 0; i < count; i++) if (online[i] == displayID) return YES;
    return NO;
}

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
    // CGDisplayIsActive/IsOnline uygulama içinde doğrulanamaz değerler döndürüyor
    // (ölçüldü: -1) → teşhiste yalnız listeler ve kip kullanılır.
    return [NSString stringWithFormat:@"aktifListede=%@ cevrimiListede=%@ kip=%zux%zu · %@",
            inActive ? @"EVET" : @"HAYIR", inOnline ? @"EVET" : @"HAYIR", mw, mh, ids];
}

@end
