/*
 * CVirtualDisplay.h — Objective-C/C bridge to Apple's private CGVirtualDisplay API.
 *
 * HaloLink creates a *real* extended display (a "virtual monitor" owned by
 * WindowServer) so that the desktop area next to the physical screen is rendered
 * by the GPU and can be captured with ScreenCaptureKit. macOS has no public API
 * for this; the classes `CGVirtualDisplayDescriptor`, `CGVirtualDisplay`,
 * `CGVirtualDisplaySettings` and `CGVirtualDisplayMode` live inside CoreGraphics
 * but are not declared in any public header. We therefore resolve them through
 * the Objective-C runtime (`NSClassFromString`) and drive them with KVC, which
 * keeps the whole thing compile-time dependent on public headers only.
 *
 * This API is private and can change or disappear with any macOS update; every
 * entry point fails gracefully (returns 0 / negative) instead of crashing.
 *
 * Recipe notes (verified empirically on macOS 15.7.5 / Apple Silicon):
 *   - `applySettings:` only *adds* modes; the display starts in the mode whose
 *     pixel size equals `maxPixelsWide/High` (its "physical anchor").
 *   - Declaring BOTH a physical-anchor mode and a logical (half-size) mode with
 *     hiDPI=1 makes macOS pick the logical mode with 2x backing -> the OS renders
 *     a retina desktop into a pixelWidth x pixelHeight framebuffer, and
 *     ScreenCaptureKit reports the *point* size while delivering pixel frames.
 *   - macOS silently omits the 2x variant for a few odd aspect ratios (notably
 *     2800x1840 = 35:23, the MatePad panel size); callers must verify the mode
 *     actually achieved and report it, which `hd_display_mode_info` enables.
 */
#ifndef CVIRTUALDISPLAY_H
#define CVIRTUALDISPLAY_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Returns 1 when the private CGVirtualDisplay classes exist in this process. */
int32_t hd_virtual_display_available(void);

/*
 * Create a virtual display with explicit pixel/logical sizes.
 *
 *   pixelWidth/Height   : framebuffer size in pixels (e.g. 2800x1840)
 *   logicalWidth/Height : desktop size in points; set to pixel/2 for HiDPI.
 *                         Ignored when hiDPI is 0.
 *   refresh             : refresh rate in Hz (60, 120, ...)
 *   hiDPI               : 1 = declare the logical mode with 2x backing
 *   name                : UTF-8 display name (may be NULL)
 *
 * Returns the CGDirectDisplayID, or 0 on failure (see hd_last_error()).
 */
uint32_t hd_create_virtual_display_ex(uint32_t pixelWidth, uint32_t pixelHeight,
                                      uint32_t logicalWidth, uint32_t logicalHeight,
                                      double refresh, int32_t hiDPI, const char *name);

/*
 * Like hd_create_virtual_display_ex() but with an explicit framebuffer *capacity*
 * (maxPixelWidth/Height). Needed for rotation and --scale-match-main: the display
 * is created once with a capacity large enough for every orientation/size it may
 * later be reconfigured to (modes can only be <= this capacity).
 */
uint32_t hd_create_virtual_display_ext(uint32_t pixelWidth, uint32_t pixelHeight,
                                       uint32_t logicalWidth, uint32_t logicalHeight,
                                       uint32_t maxPixelWidth, uint32_t maxPixelHeight,
                                       double refresh, int32_t hiDPI, const char *name);

/*
 * Convenience wrapper: uses logical = pixel/2 + hiDPI when both pixel dimensions
 * are even, otherwise a plain 1x display.
 */
uint32_t hd_create_virtual_display(uint32_t width, uint32_t height, double refresh,
                                   const char *name);

/*
 * Apply new modes to the *existing* virtual display at runtime (used by the
 * adaptive-resolution path when the tablet announces a different panel size).
 * The display object is kept; new modes are added and the default mode follows
 * the new physical-anchor mode. Call hd_configure_display() afterwards to select
 * the desired mode. Returns 1 on success, 0 on failure.
 */
int32_t hd_apply_virtual_display_settings(uint32_t pixelWidth, uint32_t pixelHeight,
                                          uint32_t logicalWidth, uint32_t logicalHeight,
                                          double refresh, int32_t hiDPI);

/* Maximum framebuffer size the display was created with (0 if none). */
int32_t hd_virtual_display_max_pixels(uint32_t *outWidth, uint32_t *outHeight);

/* Destroy the display created by hd_create_virtual_display[_ex](). Safe twice. */
void hd_destroy_virtual_display(void);

/* CGDirectDisplayID of the display we created, 0 if none. */
uint32_t hd_created_virtual_display_id(void);

/* Vendor ID we stamp on our virtual displays ('HL' = 0x484C). */
uint32_t hd_virtual_display_vendor_id(void);

/*
 * Search the online display list for one that matches our virtual display
 * (non-main / non-builtin, matching pixel size). Returns 0 when none matches.
 */
uint32_t hd_find_virtual_display_id(uint32_t width, uint32_t height);

/*
 * Configure a display: switch to the best matching mode unless the current mode
 * already has the requested pixel size, optionally move the display to
 * (originX, originY) and optionally clear any mirroring relationship.
 *
 * All changes are applied in one display-configuration transaction using
 * kCGConfigureForSession. Returns 0 (kCGErrorSuccess) on success, otherwise a
 * negative CGError value, or -1 for parameter errors.
 */
int32_t hd_configure_display(uint32_t displayID, uint32_t width, uint32_t height,
                             double refresh, int32_t originX, int32_t originY,
                             int32_t setOrigin, int32_t clearMirror);

/*
 * Safety net: never let the virtual display become the main display (the menu bar
 * and Dock would move to a screen the user cannot see). If it happened, move the
 * physical display to (0,0) and the virtual one to its right.
 * Returns 1 if a repair was performed.
 */
int32_t hd_ensure_physical_stays_main(uint32_t virtualDisplayID);

/* Fill out the current mode of a display. Returns 1 on success, 0 otherwise. */
int32_t hd_display_mode_info(uint32_t displayID, uint32_t *outPointWidth,
                             uint32_t *outPointHeight, uint32_t *outPixelWidth,
                             uint32_t *outPixelHeight, double *outRefresh);

/*
 * Retained display-mode handles for in-process 1x <-> 2x HiDPI switching.
 * CGDisplaySetDisplayMode() only accepts modes from the public mode list, but the
 * active 2x mode of a CGVirtualDisplay is not listed there; capturing the current
 * mode (+1 handle) before switching to 1x lets us switch back later.
 * Call hd_release_mode() when done.
 */
void *hd_copy_current_mode(uint32_t displayID);
/* Retained 1x mode with exactly `width x height` pixels (point == pixel), or NULL. */
void *hd_copy_1x_mode(uint32_t displayID, uint32_t width, uint32_t height);
int32_t hd_set_mode_ref(uint32_t displayID, void *modeRef);
void hd_release_mode(void *modeRef);

/* Human readable description of the last failure (static buffer, never NULL). */
const char *hd_last_error(void);

#ifdef __cplusplus
}
#endif

#endif /* CVIRTUALDISPLAY_H */
