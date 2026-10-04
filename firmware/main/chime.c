/*
 * Short two-tone chime on the ES8311 speaker, generated on the fly.
 * The I2S bus is shared with the mics (duplex, 16 kHz stereo), so the speaker is opened with the same format.
 */
#include <math.h>

#include "bsp/esp-bsp.h"
#include "esp_codec_dev.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/task.h"

#include "app.h"

#define RATE 16000

static QueueHandle_t s_queue;

static void tone(esp_codec_dev_handle_t spk, float freq, int ms)
{
    static int16_t buf[RATE / 100 * 2];   /* 10 ms stereo */
    int blocks = ms / 10;
    for (int b = 0; b < blocks; b++) {
        for (int i = 0; i < RATE / 100; i++) {
            int n = b * (RATE / 100) + i;
            float env = fminf(1.0f, fminf(n / 160.0f, (blocks * RATE / 100 - n) / 480.0f));
            int16_t s = (int16_t)(sinf(2 * (float)M_PI * freq * n / RATE) * 9000 * env);
            buf[2 * i] = buf[2 * i + 1] = s;
        }
        esp_codec_dev_write(spk, buf, sizeof(buf));
    }
}

static void chime_task(void *arg)
{
    esp_codec_dev_handle_t spk = bsp_audio_codec_speaker_init();
    if (!spk) {
        ESP_LOGW("chime", "speaker unavailable");
        vTaskDelete(NULL);
        return;
    }
    chime_t kind;
    while (xQueueReceive(s_queue, &kind, portMAX_DELAY) == pdTRUE) {
        esp_codec_dev_sample_info_t fs = { .sample_rate = RATE, .channel = 2, .bits_per_sample = 16 };
        if (esp_codec_dev_open(spk, &fs) != ESP_CODEC_DEV_OK) {
            continue;
        }
        esp_codec_dev_set_out_vol(spk, 70);
        if (kind == CHIME_REQUEST) {
            tone(spk, 880, 120);
            tone(spk, 1320, 160);
        } else {
            tone(spk, 1320, 120);
            tone(spk, 990, 160);
        }
        esp_codec_dev_close(spk);
    }
}

void chime_start(void)
{
    s_queue = xQueueCreate(4, sizeof(chime_t));
    xTaskCreate(chime_task, "chime", 4096, NULL, 3, NULL);
}

void chime_play(chime_t kind)
{
    if (s_queue) {
        xQueueSend(s_queue, &kind, 0);
    }
}
