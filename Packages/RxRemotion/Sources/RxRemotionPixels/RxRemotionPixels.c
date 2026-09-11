#include "RxRemotionPixels.h"

void RxRemotionRecoverAlpha(uint8_t *black, const uint8_t *white, size_t pixelCount) {
    for (size_t pixel = 0; pixel < pixelCount; ++pixel, black += 4, white += 4) {
        unsigned difference = 0;
        for (unsigned channel = 0; channel < 3; ++channel) {
            difference += white[channel] > black[channel] ? white[channel] - black[channel] : 0;
        }
        const uint8_t alpha = (uint8_t)(255 - difference / 3);
        for (unsigned channel = 0; channel < 3; ++channel) {
            if (black[channel] > alpha) black[channel] = alpha;
        }
        black[3] = alpha;
    }
}
