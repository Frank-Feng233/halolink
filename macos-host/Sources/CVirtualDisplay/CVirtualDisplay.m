/*
 * CVirtualDisplay.m — private CGVirtualDisplay bridge, see CVirtualDisplay.h.
 *
 * Written with manual retain/release semantics so it builds identically with or
 * without -fobjc-arc. All Objective-C message sends to private classes go through
 * objc_msgSend with explicit function-pointer casts; properties are set with KVC.
 */
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>
#import <objc/message.h>

#include <math.h>
#include <stdarg.h>
#include <string.h>

#include "include/CVirtualDisplay.h"

/* ------------------------------------------------------------------------- */
#pragma mark - Globals

static char gLastError[512] = "";

/* Kept alive for the lifetime of the process. The virtual display's lifetime is
 * tied to the CGVirtualDisplay instance. */
static id gDisplay = nil;
static id gDescriptor = nil;
static id gSettings = nil;
static dispatch_queue_t gDisplayQueue = NULL; /* OS object; nil until created */

static const uint32_t kHaloLinkVendorID = 0x484C; /* 'HL' */
static uint32_t gMaxPixelsWide = 0;
static uint32_t gMaxPixelsHigh = 0;

static void hd_set_error(NSString *format, ...) {
    @autoreleasepool {
        va_list args;
        va_start(args, format);
        NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
        va_end(args);
        const char *utf8 = [msg UTF8String];
        if (utf8 != NULL) {
            strncpy(gLastError, utf8, sizeof(gLastError) - 1);
            gLastError[sizeof(gLastError) - 1] = '\0';
        } else {
            gLastError[0] = '\0';
        }
    }
}

static NSString *hd_cgerror_name(CGError err) {
    switch (err) {
        case kCGErrorSuccess: return @"success";
        case kCGErrorFailure: return @"failure";
        case kCGErrorIllegalArgument: return @"illegal argument";
        case kCGErrorInvalidConnection: return @"invalid connection";
        case kCGErrorInvalidContext: return @"invalid context";
        case kCGErrorCannotComplete: return @"cannot complete";
        case kCGErrorNotImplemented: return @"not implemented";
        case kCGErrorRangeCheck: return @"range check";
        case kCGErrorTypeCheck: return @"type check";
        default: return [NSString stringWithFormat:@"CGError(%d)", (int)err];
    }
}

/* ------------------------------------------------------------------------- */
#pragma mark - Runtime class lookup

typedef struct {
    Class descriptorClass;
    Class displayClass;
    Class settingsClass;
    Class modeClass;
} HDClasses;

static HDClasses hd_lookup_classes(void) {
    HDClasses c;
    c.descriptorClass = NSClassFromString(@"CGVirtualDisplayDescriptor");
    c.displayClass = NSClassFromString(@"CGVirtualDisplay");
    c.settingsClass = NSClassFromString(@"CGVirtualDisplaySettings");
    c.modeClass = NSClassFromString(@"CGVirtualDisplayMode");
    return c;
}

static inline BOOL hd_classes_ok(HDClasses c) {
    return c.descriptorClass != Nil && c.displayClass != Nil &&
           c.settingsClass != Nil && c.modeClass != Nil;
}

typedef id (*HDInitWithDescriptorFn)(id, SEL, id);
typedef id (*HDInitModeFn)(id, SEL, NSUInteger, NSUInteger, double);
typedef BOOL (*HDApplySettingsFn)(id, SEL, id);

/* ------------------------------------------------------------------------- */
#pragma mark - Public API

int32_t hd_virtual_display_available(void) {
    return hd_classes_ok(hd_lookup_classes()) ? 1 : 0;
}

const char *hd_last_error(void) {
    return gLastError;
}

uint32_t hd_virtual_display_vendor_id(void) {
    return kHaloLinkVendorID;
}

const char *hd_virtual_display_vendor_hex(void) {
    return "0x484C";
}

uint32_t hd_created_virtual_display_id(void) {
    if (gDisplay == nil) {
        return 0;
    }
    @try {
        NSNumber *n = [gDisplay valueForKey:@"displayID"];
        return n != nil ? (uint32_t)[n unsignedIntValue] : 0;
    } @catch (NSException *e) {
        hd_set_error(@"reading displayID failed: %@", [e reason]);
        return 0;
    }
}

static id hd_make_mode(Class modeClass, NSUInteger width, NSUInteger height,
                       double refresh);

/* Serial override for tests (allows a second virtual display while the real app is
 * running, which is otherwise blocked by the fixed display signature). */
static uint32_t hd_descriptor_serial(void) {
    const char *override = getenv("HALOLINK_TEST_SERIAL");
    if (override != NULL && strlen(override) > 0) {
        return (uint32_t)atoi(override);
    }
    return 0x0001;
}

/* Builds the CGVirtualDisplayMode list for a request.
 *
 * HiDPI requests use a *rich* declaration: the physical anchor is (width, height+8)
 * and several half-size logical modes are declared, among them the exact
 * (width/2, height/2). Empirically this makes macOS expose the exact 2x mode
 * (e.g. 1400x920 pt / 2800x1840 px) which a plain anchor+logical pair does NOT get
 * for the 35:23 MatePad aspect ratio; if the exact mode is unavailable the system
 * falls back to the +8 px variant (tablet crops 8 px). 1x requests declare a single
 * native mode. */
static NSArray *hd_make_modes(Class modeClass, uint32_t width, uint32_t height,
                              uint32_t maxWidth, uint32_t maxHeight, double refresh,
                              int32_t hiDPI) {
    NSMutableArray *modes = [NSMutableArray arrayWithCapacity:6];
    if (hiDPI) {
        uint32_t anchorH = height + 8;
        if (maxHeight > 0 && anchorH > maxHeight) anchorH = height;
        id anchor = hd_make_mode(modeClass, width, anchorH, refresh);
        if (anchor) [modes addObject:anchor];
        uint32_t lw = width / 2;
        uint32_t lh = height / 2;
        uint32_t candidates[5][2] = {
            {lw, lh},
            {lw, lh + 1},
            {lw, lh + 2},
            {(lw > 4 ? lw - 4 : lw), lh},
            {(lw > 10 ? lw - 10 : lw), lh},
        };
        for (int i = 0; i < 5; i++) {
            if (candidates[i][0] < 64 || candidates[i][1] < 64) continue;
            id mode = hd_make_mode(modeClass, candidates[i][0], candidates[i][1], refresh);
            if (mode) [modes addObject:mode];
        }
    } else {
        id native = hd_make_mode(modeClass, width, height, refresh);
        if (native) [modes addObject:native];
    }
    return modes;
}

static id hd_make_mode(Class modeClass, NSUInteger width, NSUInteger height,
                       double refresh) {
    return ((HDInitModeFn)objc_msgSend)(
        ((id (*)(id, SEL))objc_msgSend)(modeClass, sel_registerName("alloc")),
        sel_registerName("initWithWidth:height:refreshRate:"), width, height, refresh);
}

uint32_t hd_create_virtual_display_ex(uint32_t pixelWidth, uint32_t pixelHeight,
                                      uint32_t logicalWidth, uint32_t logicalHeight,
                                      double refresh, int32_t hiDPI, const char *name) {
    return hd_create_virtual_display_ext(pixelWidth, pixelHeight, logicalWidth, logicalHeight,
                                         pixelWidth, pixelHeight, refresh, hiDPI, name);
}

uint32_t hd_create_virtual_display_ext(uint32_t pixelWidth, uint32_t pixelHeight,
                                       uint32_t logicalWidth, uint32_t logicalHeight,
                                       uint32_t maxPixelWidth, uint32_t maxPixelHeight,
                                       double refresh, int32_t hiDPI, const char *name) {
    @autoreleasepool {
        HDClasses cls = hd_lookup_classes();
        if (!hd_classes_ok(cls)) {
            hd_set_error(@"private CGVirtualDisplay classes not found in this macOS "
                         @"build (CoreGraphics). Virtual displays are unsupported.");
            return 0;
        }
        if (pixelWidth < 64 || pixelHeight < 64) {
            hd_set_error(@"invalid virtual display size %ux%u", pixelWidth, pixelHeight);
            return 0;
        }
        if (maxPixelWidth < pixelWidth) maxPixelWidth = pixelWidth;
        if (maxPixelHeight < pixelHeight) maxPixelHeight = pixelHeight;
        if (gDisplay != nil) {
            hd_set_error(@"a virtual display already exists (displayID=%u)",
                         hd_created_virtual_display_id());
            return 0;
        }
        if (refresh <= 1.0 || refresh > 240.0) {
            refresh = 60.0;
        }
        if (hiDPI && (logicalWidth < 64 || logicalHeight < 64 ||
                      logicalWidth >= pixelWidth || logicalHeight >= pixelHeight)) {
            hiDPI = 0; /* nonsense logical size -> plain 1x */
        }

        /* Physical size: pretend a ~220 PPI panel so macOS classifies the display
         * as retina-capable and generates a HiDPI mode ladder. macOS 26.1+
         * additionally requires the declared area to be >= ~200 cm^2 (208x96 mm)
         * or the display never comes online; enforce that floor. */
        double ppi = 220.0;
        double mmW = (double)pixelWidth / ppi * 25.4;
        double mmH = (double)pixelHeight / ppi * 25.4;
        double area = mmW * mmH;
        const double minArea = 208.0 * 96.0;
        if (area < minArea) {
            double f = sqrt(minArea / area);
            mmW *= f;
            mmH *= f;
        }

        NSString *displayName = (name != NULL && strlen(name) > 0)
                                    ? [NSString stringWithUTF8String:name]
                                    : @"HaloLink Display";

        gDescriptor = [[cls.descriptorClass alloc] init];
        if (gDescriptor == nil) {
            hd_set_error(@"failed to allocate CGVirtualDisplayDescriptor");
            return 0;
        }

        @try {
            [gDescriptor setValue:displayName forKey:@"name"];
            [gDescriptor setValue:@(maxPixelWidth) forKey:@"maxPixelsWide"];
            [gDescriptor setValue:@(maxPixelHeight) forKey:@"maxPixelsHigh"];
            [gDescriptor setValue:[NSValue valueWithSize:NSMakeSize(mmW, mmH)]
                           forKey:@"sizeInMillimeters"];
            [gDescriptor setValue:@(kHaloLinkVendorID) forKey:@"vendorID"];
            /* Product id derived from the pixel size so that different sizes do
             * not collide in the system's per-display preferences. */
            [gDescriptor setValue:@((pixelWidth * 10000u + pixelHeight) & 0xFFFFFFFFu)
                           forKey:@"productID"];
            /* Stable serial (macOS remembers arrangement/mode per display);
             * HALOLINK_TEST_SERIAL overrides it for side-by-side test displays. */
            [gDescriptor setValue:@(hd_descriptor_serial()) forKey:@"serialNum"];

            if (gDisplayQueue == nil) {
                gDisplayQueue = dispatch_queue_create("com.halolink.virtualdisplay", NULL);
            }
            [gDescriptor setValue:(id)gDisplayQueue forKey:@"queue"];
        } @catch (NSException *e) {
            hd_set_error(@"configuring descriptor failed: %@", [e reason]);
            gDescriptor = nil;
            return 0;
        }

        @try {
            gDisplay = ((HDInitWithDescriptorFn)objc_msgSend)(
                ((id (*)(id, SEL))objc_msgSend)(cls.displayClass, sel_registerName("alloc")),
                sel_registerName("initWithDescriptor:"), gDescriptor);
        } @catch (NSException *e) {
            hd_set_error(@"CGVirtualDisplay initWithDescriptor failed: %@", [e reason]);
            gDisplay = nil;
        }
        if (gDisplay == nil) {
            hd_set_error(@"could not instantiate CGVirtualDisplay (init returned nil)");
            return 0;
        }

        @try {
            gSettings = [[cls.settingsClass alloc] init];
            if (gSettings == nil) {
                hd_set_error(@"failed to allocate CGVirtualDisplaySettings");
                gDisplay = nil;
                return 0;
            }
            [gSettings setValue:@(hiDPI ? 1 : 0) forKey:@"hiDPI"];

            NSArray *modes = hd_make_modes(cls.modeClass, pixelWidth, pixelHeight,
                                                  maxPixelWidth, maxPixelHeight, refresh,
                                                  hiDPI);
            (void)logicalWidth;
            (void)logicalHeight;
            if (modes.count == 0) {
                hd_set_error(@"failed to allocate CGVirtualDisplayMode");
                gDisplay = nil;
                gSettings = nil;
                return 0;
            }
            [gSettings setValue:modes forKey:@"modes"];
        } @catch (NSException *e) {
            hd_set_error(@"configuring settings failed: %@", [e reason]);
            gDisplay = nil;
            gSettings = nil;
            return 0;
        }

        BOOL applied = NO;
        @try {
            applied = ((HDApplySettingsFn)objc_msgSend)(gDisplay,
                                                        sel_registerName("applySettings:"),
                                                        gSettings);
        } @catch (NSException *e) {
            hd_set_error(@"applySettings: failed: %@", [e reason]);
            applied = NO;
        }
        if (!applied) {
            hd_set_error(@"CGVirtualDisplay applySettings: returned NO");
            gDisplay = nil;
            gSettings = nil;
            return 0;
        }

        uint32_t displayID = hd_created_virtual_display_id();
        if (displayID == 0) {
            hd_set_error(@"virtual display was created but displayID is 0");
            return 0;
        }
        gMaxPixelsWide = maxPixelWidth;
        gMaxPixelsHigh = maxPixelHeight;
        gLastError[0] = '\0';
        return displayID;
    }
}

uint32_t hd_create_virtual_display(uint32_t width, uint32_t height, double refresh,
                                   const char *name) {
    BOOL canHiDPI = (width % 2u == 0u) && (height % 2u == 0u) && width >= 128 &&
                    height >= 128;
    return hd_create_virtual_display_ex(width, height,
                                        canHiDPI ? width / 2 : width,
                                        canHiDPI ? height / 2 : height, refresh,
                                        canHiDPI ? 1 : 0, name);
}

int32_t hd_virtual_display_max_pixels(uint32_t *outWidth, uint32_t *outHeight) {
    if (outWidth) *outWidth = gMaxPixelsWide;
    if (outHeight) *outHeight = gMaxPixelsHigh;
    return (gDisplay != nil) ? 1 : 0;
}

int32_t hd_apply_virtual_display_settings(uint32_t pixelWidth, uint32_t pixelHeight,
                                          uint32_t logicalWidth, uint32_t logicalHeight,
                                          double refresh, int32_t hiDPI) {
    @autoreleasepool {
        HDClasses cls = hd_lookup_classes();
        if (!hd_classes_ok(cls) || gDisplay == nil) {
            hd_set_error(@"no virtual display to reconfigure");
            return 0;
        }
        if (pixelWidth < 64 || pixelHeight < 64) {
            hd_set_error(@"invalid reconfiguration size %ux%u", pixelWidth, pixelHeight);
            return 0;
        }
        if (gMaxPixelsWide > 0 &&
            (pixelWidth > gMaxPixelsWide || pixelHeight > gMaxPixelsHigh)) {
            hd_set_error(@"reconfiguration %ux%u exceeds the display's max framebuffer %ux%u",
                         pixelWidth, pixelHeight, gMaxPixelsWide, gMaxPixelsHigh);
            return 0;
        }
        if (refresh <= 1.0 || refresh > 240.0) {
            refresh = 60.0;
        }
        if (hiDPI && (logicalWidth < 64 || logicalHeight < 64 ||
                      logicalWidth >= pixelWidth || logicalHeight >= pixelHeight)) {
            hiDPI = 0;
        }

        id settings = [[cls.settingsClass alloc] init];
        if (settings == nil) {
            hd_set_error(@"failed to allocate CGVirtualDisplaySettings");
            return 0;
        }
        @try {
            [settings setValue:@(hiDPI ? 1 : 0) forKey:@"hiDPI"];
            NSArray *modes = hd_make_modes(cls.modeClass, pixelWidth, pixelHeight,
                                                  gMaxPixelsWide, gMaxPixelsHigh, refresh,
                                                  hiDPI);
            (void)logicalWidth;
            (void)logicalHeight;
            if (modes.count == 0) {
                hd_set_error(@"failed to allocate CGVirtualDisplayMode for reconfiguration");
                return 0;
            }
            [settings setValue:modes forKey:@"modes"];
        } @catch (NSException *e) {
            hd_set_error(@"reconfiguration settings failed: %@", [e reason]);
            return 0;
        }

        BOOL applied = NO;
        @try {
            applied = ((HDApplySettingsFn)objc_msgSend)(gDisplay,
                                                        sel_registerName("applySettings:"),
                                                        settings);
        } @catch (NSException *e) {
            hd_set_error(@"applySettings: (reconfigure) failed: %@", [e reason]);
            applied = NO;
        }
        if (!applied) {
            hd_set_error(@"CGVirtualDisplay applySettings: (reconfigure) returned NO");
            return 0;
        }
        gSettings = settings;
        return 1;
    }
}

void hd_destroy_virtual_display(void) {
    @autoreleasepool {
        if (gDisplay == nil) {
            return;
        }
        uint32_t displayID = hd_created_virtual_display_id();
        /* There is no public teardown. Clearing displayID is best-effort; in
         * practice WindowServer drops the virtual display when this process exits,
         * which is the normal path during shutdown. */
        @try {
            [gDisplay setValue:@0 forKey:@"displayID"];
        } @catch (NSException *e) {
            /* ignore */
        }
        gSettings = nil;
        gDisplay = nil;
        gDescriptor = nil;
        gMaxPixelsWide = 0;
        gMaxPixelsHigh = 0;
        NSLog(@"[halolink] virtual display %u destroyed", displayID);
    }
}

uint32_t hd_find_virtual_display_id(uint32_t width, uint32_t height) {
    @autoreleasepool {
        uint32_t created = hd_created_virtual_display_id();
        CGDirectDisplayID displays[32];
        uint32_t count = 0;
        if (CGGetOnlineDisplayList(32, displays, &count) != kCGErrorSuccess) {
            return 0;
        }
        if (created != 0) {
            for (uint32_t i = 0; i < count; i++) {
                if (displays[i] == created) {
                    return created;
                }
            }
        }
        for (uint32_t i = 0; i < count; i++) {
            CGDirectDisplayID did = displays[i];
            if (did == CGMainDisplayID() || CGDisplayIsBuiltin(did)) {
                continue;
            }
            if (CGDisplayPixelsWide(did) == width && CGDisplayPixelsHigh(did) == height) {
                return did;
            }
        }
        return 0;
    }
}

typedef struct {
    uint32_t pointW;
    uint32_t pointH;
    uint32_t pixelW;
    uint32_t pixelH;
    double refresh;
} HDModeInfo;

/* Pick the mode that best matches the requested *pixel* size.
 * Preference: exact pixel size (prefer 2x/HiDPI when sizes tie), then exact point
 * size, then closest pixel area with a compatible aspect ratio. */
static CGDisplayModeRef hd_copy_best_mode(CGDirectDisplayID displayID, uint32_t width,
                                          uint32_t height, double refresh,
                                          HDModeInfo *outInfo) {
    CFArrayRef modes = CGDisplayCopyAllDisplayModes(displayID, NULL);
    if (modes == NULL) {
        return NULL;
    }
    CGDisplayModeRef best = NULL;
    double bestScore = 1e30;
    CFIndex count = CFArrayGetCount(modes);
    for (CFIndex i = 0; i < count; i++) {
        CGDisplayModeRef mode = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, i);
        size_t pw = CGDisplayModeGetPixelWidth(mode);
        size_t ph = CGDisplayModeGetPixelHeight(mode);
        size_t lw = CGDisplayModeGetWidth(mode);
        size_t lh = CGDisplayModeGetHeight(mode);
        if (pw == 0 || ph == 0) {
            continue;
        }
        double rate = CGDisplayModeGetRefreshRate(mode);
        double score;
        if (pw == width && ph == height) {
            score = (lw != pw) ? 0.0 : 0.25; /* prefer the 2x variant on a tie */
        } else if (lw == width && lh == height) {
            score = 1.0;
        } else {
            double aspect =
                fabs((double)pw / (double)ph - (double)width / (double)height);
            if (aspect > 0.05) {
                continue;
            }
            double areaDelta =
                fabs((double)pw * (double)ph - (double)width * (double)height);
            score = 10.0 + areaDelta / ((double)width * (double)height);
        }
        if (refresh > 0 && rate > 0) {
            score += fabs(rate - refresh) / 1000.0;
        }
        if (score < bestScore) {
            bestScore = score;
            best = mode;
        }
    }
    if (best != NULL && outInfo != NULL) {
        outInfo->pointW = (uint32_t)CGDisplayModeGetWidth(best);
        outInfo->pointH = (uint32_t)CGDisplayModeGetHeight(best);
        outInfo->pixelW = (uint32_t)CGDisplayModeGetPixelWidth(best);
        outInfo->pixelH = (uint32_t)CGDisplayModeGetPixelHeight(best);
        outInfo->refresh = CGDisplayModeGetRefreshRate(best);
    }
    if (best != NULL) {
        CGDisplayModeRetain(best);
    }
    CFRelease(modes);
    return best;
}

int32_t hd_display_mode_info(uint32_t displayID, uint32_t *outPointWidth,
                             uint32_t *outPointHeight, uint32_t *outPixelWidth,
                             uint32_t *outPixelHeight, double *outRefresh) {
    @autoreleasepool {
        CGDisplayModeRef mode = CGDisplayCopyDisplayMode(displayID);
        if (mode == NULL) {
            return 0;
        }
        if (outPointWidth) *outPointWidth = (uint32_t)CGDisplayModeGetWidth(mode);
        if (outPointHeight) *outPointHeight = (uint32_t)CGDisplayModeGetHeight(mode);
        if (outPixelWidth) *outPixelWidth = (uint32_t)CGDisplayModeGetPixelWidth(mode);
        if (outPixelHeight) *outPixelHeight = (uint32_t)CGDisplayModeGetPixelHeight(mode);
        if (outRefresh) *outRefresh = CGDisplayModeGetRefreshRate(mode);
        CGDisplayModeRelease(mode);
        return 1;
    }
}

int32_t hd_configure_display(uint32_t displayID, uint32_t width, uint32_t height,
                             double refresh, int32_t originX, int32_t originY,
                             int32_t setOrigin, int32_t clearMirror) {
    @autoreleasepool {
        if (displayID == 0) {
            hd_set_error(@"configure display: displayID is 0");
            return -1;
        }

        /* Keep the current mode when it already has the requested pixel size (this
         * preserves a HiDPI mode that is not re-selectable through the public
         * CGDisplayMode list). */
        BOOL needModeChange = YES;
        uint32_t curPW = 0, curPH = 0;
        if (hd_display_mode_info(displayID, NULL, NULL, &curPW, &curPH, NULL)) {
            needModeChange = !(curPW == width && curPH == height);
        }

        CGDisplayModeRef mode = NULL;
        if (needModeChange) {
            mode = hd_copy_best_mode(displayID, width, height, refresh, NULL);
            if (mode == NULL) {
                hd_set_error(@"configure display %u: no usable display mode for %ux%u",
                             displayID, width, height);
                return -1;
            }
        }

        CGDisplayConfigRef config = NULL;
        CGError err = CGBeginDisplayConfiguration(&config);
        if (err != kCGErrorSuccess) {
            hd_set_error(@"CGBeginDisplayConfiguration failed: %@", hd_cgerror_name(err));
            if (mode) CGDisplayModeRelease(mode);
            return (int32_t)err;
        }
        if (mode != NULL) {
            err = CGConfigureDisplayWithDisplayMode(config, displayID, mode, NULL);
            if (err != kCGErrorSuccess) {
                hd_set_error(@"CGConfigureDisplayWithDisplayMode failed: %@",
                             hd_cgerror_name(err));
                CGCancelDisplayConfiguration(config);
                CGDisplayModeRelease(mode);
                return (int32_t)err;
            }
        }
        if (setOrigin) {
            err = CGConfigureDisplayOrigin(config, displayID, originX, originY);
            if (err != kCGErrorSuccess) {
                /* Not fatal: the mode change is still useful. */
                hd_set_error(@"CGConfigureDisplayOrigin failed: %@ (display keeps its "
                             @"current origin)", hd_cgerror_name(err));
            }
        }
        if (clearMirror) {
            CGError mirrorErr =
                CGConfigureDisplayMirrorOfDisplay(config, displayID, kCGNullDirectDisplay);
            if (mirrorErr != kCGErrorSuccess) {
                /* Not fatal either. */
                hd_set_error(@"CGConfigureDisplayMirrorOfDisplay failed: %@",
                             hd_cgerror_name(mirrorErr));
            }
        }
        err = CGCompleteDisplayConfiguration(config, kCGConfigureForSession);
        if (mode) CGDisplayModeRelease(mode);
        if (err != kCGErrorSuccess) {
            hd_set_error(@"CGCompleteDisplayConfiguration failed: %@",
                         hd_cgerror_name(err));
            return (int32_t)err;
        }
        return 0;
    }
}

void *hd_copy_current_mode(uint32_t displayID) {
    if (displayID == 0) return NULL;
    CGDisplayModeRef mode = CGDisplayCopyDisplayMode(displayID);
    return (void *)mode; /* +1, caller releases */
}

void *hd_copy_1x_mode(uint32_t displayID, uint32_t width, uint32_t height) {
    CFArrayRef modes = CGDisplayCopyAllDisplayModes(displayID, NULL);
    if (modes == NULL) return NULL;
    void *result = NULL;
    for (CFIndex i = 0; i < CFArrayGetCount(modes); i++) {
        CGDisplayModeRef mode = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, i);
        if (CGDisplayModeGetPixelWidth(mode) == width &&
            CGDisplayModeGetPixelHeight(mode) == height &&
            CGDisplayModeGetWidth(mode) == width &&
            CGDisplayModeGetHeight(mode) == height) {
            CGDisplayModeRetain(mode);
            result = (void *)mode;
            break;
        }
    }
    CFRelease(modes);
    return result;
}

int32_t hd_set_mode_ref(uint32_t displayID, void *modeRef) {
    if (displayID == 0 || modeRef == NULL) return -1;
    CGError err = CGDisplaySetDisplayMode(displayID, (CGDisplayModeRef)modeRef, NULL);
    return (int32_t)err;
}

void hd_release_mode(void *modeRef) {
    if (modeRef != NULL) {
        CGDisplayModeRelease((CGDisplayModeRef)modeRef);
    }
}

int32_t hd_ensure_physical_stays_main(uint32_t virtualDisplayID) {
    @autoreleasepool {
        if (virtualDisplayID == 0) {
            return 0;
        }
        CGDirectDisplayID mainID = CGMainDisplayID();
        if (mainID != virtualDisplayID) {
            return 0;
        }
        /* The virtual display stole the main-display role: find a physical display
         * and move it back to (0,0), virtual display to its right. */
        CGDirectDisplayID displays[32];
        uint32_t count = 0;
        if (CGGetOnlineDisplayList(32, displays, &count) != kCGErrorSuccess) {
            return 0;
        }
        CGDirectDisplayID physical = kCGNullDirectDisplay;
        for (uint32_t i = 0; i < count; i++) {
            if (displays[i] == virtualDisplayID) continue;
            if (CGDisplayVendorNumber(displays[i]) == kHaloLinkVendorID) continue;
            physical = displays[i];
            break;
        }
        if (physical == kCGNullDirectDisplay) {
            return 0;
        }
        CGDisplayConfigRef config = NULL;
        if (CGBeginDisplayConfiguration(&config) != kCGErrorSuccess) {
            return 0;
        }
        CGConfigureDisplayOrigin(config, physical, 0, 0);
        CGConfigureDisplayOrigin(config, virtualDisplayID,
                                 (int32_t)CGDisplayBounds(physical).size.width, 0);
        CGError err = CGCompleteDisplayConfiguration(config, kCGConfigureForSession);
        if (err != kCGErrorSuccess) {
            hd_set_error(@"main-display repair failed: %@", hd_cgerror_name(err));
            return 0;
        }
        return 1;
    }
}
