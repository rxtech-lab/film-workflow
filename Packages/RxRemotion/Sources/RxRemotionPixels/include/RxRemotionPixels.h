#ifndef RX_REMOTION_PIXELS_H
#define RX_REMOTION_PIXELS_H
#include <stddef.h>
#include <stdint.h>
/// Recovers premultiplied RGBA from opaque black/white matte snapshots in-place.
void RxRemotionRecoverAlpha(uint8_t *black, const uint8_t *white, size_t pixelCount);
#endif
