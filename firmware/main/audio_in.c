/*
 * Captures both ES7210 mics at 16 kHz, mixes to mono, IMA ADPCM encodes and streams over BLE.
 * Every packet carries its own ADPCM state, so a lost packet never corrupts the following ones.
 *
 * Power: an energy VAD with an adaptive noise floor only streams while someone is speaking.
 * Silence costs no radio time on the board and no recognition work on the iPhone.
 * A 300 ms pre-roll keeps the first syllable; an 800 ms hangover keeps pauses inside a sentence.
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
#define WARMUP_FRAMES 10           /* drop the first 200 ms: codec start-up pop */

#define VAD_PREROLL_FRAMES  15     /* 300 ms sent before the detected start */
#define VAD_HANGOVER_FRAMES 40     /* keep streaming 800 ms after the last speech frame */
#define VAD_START_FRAMES    2      /* 40 ms above threshold to open */
#define VAD_MARGIN_DB       10.0f  /* speech must be this far above the noise floor */
#define VAD_MIN_DB          -58.0f /* and above this absolute level */
#define FLOOR_RISE_DB       0.01f  /* per frame (0.5 dB/s): floor follows slowly rising noise */

static int16_t s_preroll[VAD_PREROLL_FRAMES][FRAME_SAMPLES];
static int s_preroll_head;
static int s_preroll_count;

typedef struct {
    adpcm_state_t st;
    uint16_t seq;
    uint32_t sent, dropped;
} stream_t;

static void put_header(uint8_t *pkt, uint16_t seq, const adpcm_state_t *st)
{
    pkt[0] = seq & 0xff;
    pkt[1] = seq >> 8;
    pkt[2] = (uint16_t)st->predictor & 0xff;
    pkt[3] = (uint16_t)st->predictor >> 8;
    pkt[4] = st->index;
}

static void send_frame(stream_t *s, const int16_t *mono)
{
    static uint8_t pkt[HEADER_BYTES + FRAME_SAMPLES / 2];

    /* Split by negotiated MTU (iPhones usually give >= 185, enough for a full 20 ms frame) */
    int chunk = (ble_link_payload_max() - HEADER_BYTES) * 2;
    if (chunk > FRAME_SAMPLES) {
        chunk = FRAME_SAMPLES;
    }
    chunk &= ~1;
    for (int off = 0; off < FRAME_SAMPLES; off += chunk) {
        int n = FRAME_SAMPLES - off < chunk ? FRAME_SAMPLES - off : chunk;
        put_header(pkt, s->seq++, &s->st);
        adpcm_encode(&s->st, mono + off, n, pkt + HEADER_BYTES);
        if (ble_link_send_audio(pkt, HEADER_BYTES + n / 2)) {
            s->sent++;
        } else {
            s->dropped++;
        }
    }
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

    bool open = false;
    stream_t stream = { 0 };
    uint32_t frames = 0, warmup = 0;
    float floor_db = -60.0f, peak_db = -100.0f;
    int above = 0, hangover = 0;
    bool speaking = false;

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
                memset(&stream, 0, sizeof(stream));
                frames = 0;
                warmup = WARMUP_FRAMES;
                speaking = false;
                above = hangover = 0;
                s_preroll_count = s_preroll_head = 0;
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

        double energy = 0;
        for (int i = 0; i < FRAME_SAMPLES; i++) {
            int32_t s = ((int32_t)raw[2 * i] + raw[2 * i + 1]) / 2;
            mono[i] = (int16_t)s;
            energy += (double)s * s;
        }
        float db = 10.0f * log10f((float)(energy / FRAME_SAMPLES) / (32768.0f * 32768.0f) + 1e-10f);
        if (db > peak_db) {
            peak_db = db;
        }

        /* Noise floor: drops immediately to quieter frames, rises slowly so speech doesn't lift it */
        if (db < floor_db) {
            floor_db = db;
        } else {
            floor_db += FLOOR_RISE_DB;
        }

        bool voiced = db > floor_db + VAD_MARGIN_DB && db > VAD_MIN_DB;
        above = voiced ? above + 1 : 0;

        if (!speaking && above >= VAD_START_FRAMES) {
            speaking = true;
            app_on_speech_activity();
            /* Flush the pre-roll oldest first, then continue live */
            int start = (s_preroll_head - s_preroll_count + VAD_PREROLL_FRAMES) % VAD_PREROLL_FRAMES;
            for (int i = 0; i < s_preroll_count; i++) {
                send_frame(&stream, s_preroll[(start + i) % VAD_PREROLL_FRAMES]);
            }
            s_preroll_count = 0;
        }

        if (speaking) {
            send_frame(&stream, mono);
            if (voiced) {
                hangover = VAD_HANGOVER_FRAMES;
            } else if (--hangover <= 0) {
                speaking = false;
            }
        } else {
            memcpy(s_preroll[s_preroll_head], mono, sizeof(mono));
            s_preroll_head = (s_preroll_head + 1) % VAD_PREROLL_FRAMES;
            if (s_preroll_count < VAD_PREROLL_FRAMES) {
                s_preroll_count++;
            }
        }

        if (++frames % 250 == 0) {   /* every 5 s */
            ESP_LOGI(TAG, "peak %.0f dB, floor %.0f dB, sent %lu, dropped %lu",
                     peak_db, floor_db, (unsigned long)stream.sent, (unsigned long)stream.dropped);
            peak_db = -100.0f;
        }
    }
}

void audio_in_start(void)
{
    xTaskCreatePinnedToCore(audio_task, "audio_in", 6144, NULL, 6, NULL, 1);
}
