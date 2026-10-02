/*
 * Thu 2 mic ES7210 ở 16 kHz, trộn thành mono, nén IMA ADPCM rồi gửi qua BLE.
 * Mỗi gói tự chứa trạng thái ADPCM nên mất một gói cũng không làm hỏng các gói sau.
 */
#include <math.h>
#include <string.h>

#include "bsp/esp-bsp.h"
#include "esp_codec_dev.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#include "adpcm.h"
#include "app.h"

static const char *TAG = "audio";

#define SAMPLE_RATE   16000
#define FRAME_SAMPLES 320          /* 20 ms */
#define HEADER_BYTES  5
#define MIC_GAIN_DB   36.0f
#define WARMUP_FRAMES 10           /* bỏ 200 ms đầu: tiếng "bụp" khi codec vừa mở */

static void put_header(uint8_t *pkt, uint16_t seq, const adpcm_state_t *st)
{
    pkt[0] = seq & 0xff;
    pkt[1] = seq >> 8;
    pkt[2] = (uint16_t)st->predictor & 0xff;
    pkt[3] = (uint16_t)st->predictor >> 8;
    pkt[4] = st->index;
}

static void audio_task(void *arg)
{
    esp_codec_dev_handle_t mic = bsp_audio_codec_microphone_init();
    if (mic == NULL) {
        ESP_LOGE(TAG, "microphone init failed");
        vTaskDelete(NULL);
        return;
    }

    static int16_t raw[FRAME_SAMPLES * 2];
    static int16_t mono[FRAME_SAMPLES];
    static uint8_t pkt[HEADER_BYTES + FRAME_SAMPLES / 2];

    bool open = false;
    adpcm_state_t st = { 0 };
    uint16_t seq = 0;
    uint32_t frames = 0, dropped = 0, warmup = 0;
    double energy = 0;

    while (true) {
        bool want = app_get_recording() != REC_NONE && ble_link_audio_ready();
        if (want != open) {
            if (want) {
                esp_codec_dev_sample_info_t fs = {
                    .sample_rate = SAMPLE_RATE,
                    .channel = 2,
                    .bits_per_sample = 16,
                };
                if (esp_codec_dev_open(mic, &fs) != ESP_CODEC_DEV_OK) {
                    ESP_LOGE(TAG, "open failed");
                    vTaskDelay(pdMS_TO_TICKS(500));
                    continue;
                }
                esp_codec_dev_set_in_gain(mic, MIC_GAIN_DB);
                memset(&st, 0, sizeof(st));
                seq = 0;
                frames = dropped = 0;
                energy = 0;
                warmup = WARMUP_FRAMES;
                ESP_LOGI(TAG, "recording started");
            } else {
                esp_codec_dev_close(mic);
                ESP_LOGI(TAG, "recording stopped");
            }
            open = want;
        }
        if (!open) {
            vTaskDelay(pdMS_TO_TICKS(30));
            continue;
        }

        if (esp_codec_dev_read(mic, raw, sizeof(raw)) != ESP_CODEC_DEV_OK) {
            continue;
        }
        if (warmup > 0) {
            warmup--;
            continue;
        }
        for (int i = 0; i < FRAME_SAMPLES; i++) {
            int32_t s = ((int32_t)raw[2 * i] + raw[2 * i + 1]) / 2;
            mono[i] = (int16_t)s;
            energy += (double)s * s;
        }

        /* Chia khung theo MTU đã thoả thuận (iPhone thường cho MTU >= 185, đủ cả khung 20 ms) */
        int chunk = (ble_link_payload_max() - HEADER_BYTES) * 2;
        if (chunk > FRAME_SAMPLES) {
            chunk = FRAME_SAMPLES;
        }
        chunk &= ~1;
        for (int off = 0; off < FRAME_SAMPLES; off += chunk) {
            int n = FRAME_SAMPLES - off < chunk ? FRAME_SAMPLES - off : chunk;
            put_header(pkt, seq++, &st);
            adpcm_encode(&st, mono + off, n, pkt + HEADER_BYTES);
            if (!ble_link_send_audio(pkt, HEADER_BYTES + n / 2)) {
                dropped++;
            }
        }

        if (++frames % 50 == 0) {   /* mỗi giây log mức âm để kiểm tra mic */
            double rms = sqrt(energy / (50.0 * FRAME_SAMPLES));
            ESP_LOGI(TAG, "level %.1f dBFS, dropped %lu, chunk %d",
                     20 * log10(rms / 32768.0 + 1e-9), (unsigned long)dropped, chunk);
            energy = 0;
        }
    }
}

void audio_in_start(void)
{
    xTaskCreatePinnedToCore(audio_task, "audio_in", 6144, NULL, 6, NULL, 1);
}
