/*
 * Captures both ES7210 mics at 16 kHz, mixes to mono, IMA ADPCM encodes and streams over BLE:
 *   translator: to the iPhone (audio characteristic) while the board mic is on, gated by an energy VAD
 *   voice     : to the Mac (Claude voice characteristic) for one capture at a time (voice_ui.c): every frame from
 *               the start until voice.c's endpointing, Stop, an abort, or the Mac voice link going away
 * A voice capture pauses the translator stream (nothing goes to the iPhone meanwhile); the translator VAD starts
 * fresh afterwards, so no half phrase is sent. The codec is open only while one of them needs it.
 * Every packet carries its own ADPCM state, so a lost packet never corrupts the following ones.
 * Encoding and sending happen only in this task, never in the NimBLE host task (its stack is 6 KB).
 *
 * Translator power: silence costs no radio time on the board and no recognition work on the iPhone.
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
#include "voice.h"

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

/* Level ring: -55 dBFS (faint, far) .. -25 dBFS (close, clear) → 1..100 */
#define RING_MIN_DB   -55.0f
#define RING_MAX_DB   -25.0f
#define RING_EVERY    6          /* update every 120 ms */

typedef enum { SINK_PHONE = 0, SINK_MAC } sink_t;

typedef struct {
    adpcm_state_t st;
    uint16_t seq;
    uint32_t sent, dropped;
} stream_t;

/* Translator VAD (the iPhone stream) */
typedef struct {
    float floor_db;
    int above;
    int hangover;
    bool speaking;
} translator_t;

static int16_t s_preroll[VAD_PREROLL_FRAMES][FRAME_SAMPLES];
static int s_preroll_head;
static int s_preroll_count;

/* Voice capture requests from voice_ui.c (LVGL or NimBLE host task); everything else belongs to this task */
#define VOICE_CMD_NONE  0
#define VOICE_CMD_STOP  1
#define VOICE_CMD_ABORT 2
static portMUX_TYPE s_voice_mux = portMUX_INITIALIZER_UNLOCKED;
static uint32_t s_voice_id;   /* requested capture, 0 = none */
static uint8_t s_voice_cmd;

static void put_header(uint8_t *pkt, uint16_t seq, const adpcm_state_t *st)
{
    pkt[0] = seq & 0xff;
    pkt[1] = seq >> 8;
    pkt[2] = (uint16_t)st->predictor & 0xff;
    pkt[3] = (uint16_t)st->predictor >> 8;
    pkt[4] = st->index;
}

static void send_frame(stream_t *s, const int16_t *mono, sink_t sink)
{
    static uint8_t pkt[HEADER_BYTES + FRAME_SAMPLES / 2];

    /* Split by negotiated MTU (iPhones usually give >= 185, enough for a full 20 ms frame) */
    uint16_t payload = sink == SINK_MAC ? ble_link_voice_payload_max() : ble_link_payload_max();
    int chunk = (payload - HEADER_BYTES) * 2;
    if (chunk > FRAME_SAMPLES) {
        chunk = FRAME_SAMPLES;
    }
    chunk &= ~1;
    for (int off = 0; off < FRAME_SAMPLES; off += chunk) {
        int n = FRAME_SAMPLES - off < chunk ? FRAME_SAMPLES - off : chunk;
        put_header(pkt, s->seq++, &s->st);
        adpcm_encode(&s->st, mono + off, n, pkt + HEADER_BYTES);
        bool ok = sink == SINK_MAC ? ble_link_send_voice(pkt, HEADER_BYTES + n / 2)
                                   : ble_link_send_audio(pkt, HEADER_BYTES + n / 2);
        if (ok) {
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
    t->above = 0;
    t->hangover = 0;
    t->speaking = false;
    s_preroll_count = s_preroll_head = 0;
}

static void translator_step(translator_t *t, stream_t *phone, const int16_t *mono, float db, uint32_t frames)
{
    /* Noise floor: drops immediately to quieter frames, rises slowly so speech doesn't lift it */
    if (db < t->floor_db) {
        t->floor_db = db;
    } else {
        t->floor_db += FLOOR_RISE_DB;
    }
    bool voiced = db > t->floor_db + VAD_MARGIN_DB && db > VAD_MIN_DB;
    t->above = voiced ? t->above + 1 : 0;

    if (!t->speaking && t->above >= VAD_START_FRAMES) {
        t->speaking = true;
        app_on_speech_activity();
        /* Flush the pre-roll oldest first, then continue live */
        int start = (s_preroll_head - s_preroll_count + VAD_PREROLL_FRAMES) % VAD_PREROLL_FRAMES;
        for (int i = 0; i < s_preroll_count; i++) {
            send_frame(phone, s_preroll[(start + i) % VAD_PREROLL_FRAMES], SINK_PHONE);
        }
        s_preroll_count = 0;
    }

    if (t->speaking) {
        send_frame(phone, mono, SINK_PHONE);
        if (voiced) {
            t->hangover = VAD_HANGOVER_FRAMES;
        } else if (--t->hangover <= 0) {
            t->speaking = false;
            ui_set_level(0);
        }
        if (t->speaking && frames % RING_EVERY == 0) {
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

bool audio_in_voice_start(uint32_t voice_id)
{
    if (voice_id == 0 || !ble_link_voice_ready()) {
        return false;
    }
    taskENTER_CRITICAL(&s_voice_mux);
    s_voice_id = voice_id;
    s_voice_cmd = VOICE_CMD_NONE;
    taskEXIT_CRITICAL(&s_voice_mux);
    return true;
}

static void voice_command(uint8_t cmd)
{
    taskENTER_CRITICAL(&s_voice_mux);
    if (s_voice_id != 0) {
        s_voice_cmd = cmd;
    }
    taskEXIT_CRITICAL(&s_voice_mux);
}

void audio_in_voice_stop(void)
{
    voice_command(VOICE_CMD_STOP);
}

void audio_in_voice_abort(void)
{
    voice_command(VOICE_CMD_ABORT);
}

/* Ends capture `id` in this task. stop_input: tell the Mac the audio is complete (after the last packet, on the
 * same link, so it never overtakes it) and let the UI wait for the final transcript. */
static void end_voice(uint32_t id, bool stop_input, const char *why, const stream_t *mac)
{
    taskENTER_CRITICAL(&s_voice_mux);
    if (s_voice_id == id) {   /* a newer capture may already be requested: leave it */
        s_voice_id = 0;
        s_voice_cmd = VOICE_CMD_NONE;
    }
    taskEXIT_CRITICAL(&s_voice_mux);
    voice_ui_level(0);
    /* Debug: audio task stack headroom (bytes never used), once per capture */
    ESP_LOGI(TAG, "voice %lu ended (%s): sent %lu, dropped %lu; stack headroom audio_in: %u bytes", (unsigned long)id,
             why, (unsigned long)mac->sent, (unsigned long)mac->dropped, (unsigned)uxTaskGetStackHighWaterMark(NULL));
    if (stop_input) {
        uint8_t buf[CLAUDE_INPUT_MAX];
        size_t n = claude_encode_voice(id, CLAUDE_INPUT_VOICE_STOP, buf);
        if (!ble_link_send_claude_input(buf, n)) {
            ESP_LOGW(TAG, "voice %lu: stop not sent", (unsigned long)id);
        }
        voice_ui_capture_ended(id);
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
    stream_t mac = { 0 };
    translator_t tr = { .floor_db = -60.0f };
    voice_vad_t vad;
    voice_vad_init(&vad);
    uint32_t voice = 0;   /* capture this task is streaming, 0 = none */
    uint32_t frames = 0, warmup = 0;
    float peak_db = -100.0f;

    while (true) {
        uint32_t want_voice;
        uint8_t cmd;
        taskENTER_CRITICAL(&s_voice_mux);
        want_voice = s_voice_id;
        cmd = s_voice_cmd;
        taskEXIT_CRITICAL(&s_voice_mux);

        if (voice != 0 && want_voice != voice) {
            /* Replaced by a newer capture (Say again): the UI already sent the cancel */
            ESP_LOGI(TAG, "voice %lu replaced", (unsigned long)voice);
            voice = 0;
            voice_ui_level(0);
        }
        if (want_voice != 0 && cmd == VOICE_CMD_ABORT) {
            end_voice(want_voice, false, "aborted", &mac);
            voice = 0;
            continue;
        }
        if (voice == 0 && want_voice != 0) {
            voice = want_voice;
            memset(&mac, 0, sizeof(mac));
            voice_vad_init(&vad);
            translator_reset(&tr);   /* the iPhone stream pauses: no half phrase before or after */
            ui_set_level(0);
            ESP_LOGI(TAG, "voice %lu started", (unsigned long)voice);
        }

        bool translating = app_get_recording() != REC_NONE && ble_link_audio_ready();
        bool want = voice != 0 || translating;
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
                memset(&phone, 0, sizeof(phone));
                frames = 0;
                warmup = WARMUP_FRAMES;
                translator_reset(&tr);
                ESP_LOGI(TAG, "recording started");
            } else {
                esp_codec_dev_close(mic);
                ui_set_level(0);
                voice_ui_level(0);
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

        if (voice != 0) {
            send_frame(&mac, mono, SINK_MAC);
            voice_vad_result_t r = voice_vad_step(&vad, db);
            if (frames % RING_EVERY == 0) {
                voice_ui_level(db > RING_MIN_DB ? ring_percent(db) : 0);
            }
            const char *why = cmd == VOICE_CMD_STOP          ? "stop"
                              : r == VOICE_VAD_SILENCE       ? "silence"
                              : r == VOICE_VAD_NOTHING       ? "nothing said"
                              : r == VOICE_VAD_MAX           ? "30 s"
                              : !ble_link_voice_ready()      ? "Mac voice link gone"
                                                             : NULL;
            if (why != NULL) {
                end_voice(voice, true, why, &mac);
                voice = 0;
            }
        } else if (translating) {
            translator_step(&tr, &phone, mono, db, frames);
        }

        if (++frames % 250 == 0) {   /* every 5 s */
            ESP_LOGI(TAG, "peak %.0f dB, floor %.0f dB, sent %lu, dropped %lu", peak_db, tr.floor_db,
                     (unsigned long)phone.sent, (unsigned long)phone.dropped);
            peak_db = -100.0f;
        }
    }
}

void audio_in_start(void)
{
    xTaskCreatePinnedToCore(audio_task, "audio_in", 6144, NULL, 6, NULL, 1);
}
