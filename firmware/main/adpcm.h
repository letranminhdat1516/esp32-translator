#pragma once
#include <stddef.h>
#include <stdint.h>

/* IMA ADPCM, 4 bit/mẫu, nibble thấp trước. App iOS giải mã theo đúng thứ tự này. */
typedef struct {
    int16_t predictor;
    uint8_t index;
} adpcm_state_t;

/* n phải chẵn; out cần n/2 byte */
void adpcm_encode(adpcm_state_t *st, const int16_t *in, size_t n, uint8_t *out);
