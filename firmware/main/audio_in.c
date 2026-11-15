/*
 * Captures both ES7210 mics at 16 kHz, mixes to mono, IMA ADPCM encodes and streams to the iPhone over BLE (audio
 * characteristic) while the board mic is on, gated by an energy VAD. The codec is open only while streaming.
 * Every packet carries its own ADPCM state, so a lost packet never corrupts the following ones.
 * Encoding and sending happen only in this task, never in the NimBLE host task (its stack is 6 KB).
 *
 * Translator power: silence costs no radio time on the board and no recognition work on the iPhone.
 * A 300 ms pre-roll keeps the first syllable; a 400 ms hangover keeps pauses inside a sentence.
 *
 * Near field only: the other person holds the board, so only speech at the holder's level opens a phrase and the
 * user's own voice, from farther away, is not streamed as theirs (near_vad.h has the rule and its thresholds).
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
#include "near_vad.h"

static const char *TAG = "audio";

#define SAMPLE_RATE   16000
#define FRAME_SAMPLES 320          /* 20 ms */
#define HEADER_BYTES  5
#define MIC_GAIN_DB   36.0f
#define WARMUP_FRAMES 10           /* drop the first 200 ms: codec start-up pop */

#define VAD_PREROLL_FRAMES  15     /* 300 ms sent before the detected start */
/* Start, hangover (400 ms; latency harness: the app pads silence, so 800 ms only cost airtime), margin and the
 * near-field levels: near_vad.h */

/* Level ring: -55 dBFS (faint, far) .. -25 dBFS (close, clear) → 1..100 */
#define RING_MIN_DB   -55.0f
#define RING_MAX_DB   -25.0f
#define RING_EVERY    6          /* update every 120 ms */

typedef struct {
    adpcm_state_t st;
    uint16_t seq;
    uint32_t sent, dropped;
} stream_t;

/* Translator VAD (the iPhone stream) */
typedef struct {
    near_vad_t vad;
    float open_db;     /* level of the frame that opened the last phrase (diagnostics) */
    unsigned phrases;
} translator_t;

static int16_t s_preroll[VAD_PREROLL_FRAMES][FRAME_SAMPLES];
static int s_preroll_head;
static int s_preroll_count;

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
    uint16_t payload = ble_link_payload_max();
    int chunk = (payload - HEADER_BYTES) * 2;
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

static int ring_percent(float db)
{
    float pct = (db - RING_MIN_DB) * 100.0f / (RING_MAX_DB - RING_MIN_DB);
    return pct < 1 ? 1 : pct > 100 ? 100 : (int)pct;
}

/* A fresh phrase: nothing held back, nothing half sent */
static void translator_reset(translator_t *t)
{
    near_vad_reset(&t->vad);
    s_preroll_count = s_preroll_head = 0;
}

static void translator_step(translator_t *t, stream_t *phone, const int16_t *mono, float db, uint32_t frames)
{
    near_vad_event_t ev = near_vad_step(&t->vad, db);

    if (ev == NEAR_VAD_START) {
        t->open_db = db;
        t->phrases++;
        app_on_speech_activity();
        /* Flush the pre-roll oldest first, then continue live */
        int start = (s_preroll_head - s_preroll_count + VAD_PREROLL_FRAMES) % VAD_PREROLL_FRAMES;
        for (int i = 0; i < s_preroll_count; i++) {
            send_frame(phone, s_preroll[(start + i) % VAD_PREROLL_FRAMES]);
        }
        s_preroll_count = 0;
    }

    if (ev != NEAR_VAD_QUIET) {
        send_frame(phone, mono);
        if (ev == NEAR_VAD_END) {
            ui_set_level(0);
        } else if (frames % RING_EVERY == 0) {
            ui_set_level(ring_percent(db));
        }
    } else {
        memcpy(s_preroll[s_preroll_head], mono, sizeof(int16_t) * FRAME_SAMPLES);
        s_preroll_head = (s_preroll_head + 1) % VAD_PREROLL_FRAMES;
        if (s_preroll_count < VAD_PREROLL_FRAMES) {
            s_preroll_count++;
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
    stream_t phone = { 0 };
    translator_t tr = { 0 };
    near_vad_init(&tr.vad, -60.0f);
    uint32_t frames = 0, warmup = 0;
    float peak_db = -100.0f;

    while (true) {
        bool translating = app_get_recording() != REC_NONE && ble_link_audio_ready();
        if (translating != open) {
            if (translating) {
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
                memset(&phone, 0, sizeof(phone));
                frames = 0;
                warmup = WARMUP_FRAMES;
                translator_reset(&tr);
                ESP_LOGI(TAG, "recording started");
            } else {
                esp_codec_dev_close(mic);
                ui_set_level(0);
                ESP_LOGI(TAG, "recording stopped");
            }
            open = translating;
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

        if (translating) {
            translator_step(&tr, &phone, mono, db, frames);
        }

        if (++frames % 250 == 0) {   /* every 5 s */
            /* far: frames that stood out like speech but stayed under NEAR_VAD_OPEN_DB (the user, others nearby);
             * open: the level that opened the last phrase. Both are for tuning the near-field levels. */
            ESP_LOGI(TAG, "peak %.0f dB, floor %.0f dB, far %u, phrases %u (last opened at %.0f dB), sent %lu, dropped %lu",
                     peak_db, tr.vad.floor_db, tr.vad.far_frames, tr.phrases, tr.open_db,
                     (unsigned long)phone.sent, (unsigned long)phone.dropped);
            tr.vad.far_frames = 0;
            peak_db = -100.0f;
        }
    }
}

void audio_in_start(void)
{
    xTaskCreatePinnedToCore(audio_task, "audio_in", 6144, NULL, 6, NULL, 1);
}
