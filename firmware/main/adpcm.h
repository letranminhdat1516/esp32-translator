#pragma once
#include <stddef.h>
#include <stdint.h>

/* IMA ADPCM, 4 bits/sample, low nibble first. The iOS app decodes in exactly this order. */
typedef struct {
    int16_t predictor;
    uint8_t index;
} adpcm_state_t;

/* n must be even; out needs n/2 bytes */
void adpcm_encode(adpcm_state_t *st, const int16_t *in, size_t n, uint8_t *out);
