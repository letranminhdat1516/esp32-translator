/*
 * Near-field speech gate for the board mic (pure C, host-tested in firmware/test/test_near_vad.c; audio_in.c feeds
 * it the level of each 20 ms frame of the mixed mic signal).
 *
 * The other person holds the board (mouth 10-40 cm from the mics); the user stands 0.5-1.5 m away. Speech level
 * falls about 6 dB per doubling of distance, so the holder arrives roughly 8-20 dB louder than the user. The old
 * gate opened on anything 10 dB above the background, so the user's own voice streamed too and was recognized as
 * the other person. Here a phrase opens only on frames at the holder's level (NEAR_VAD_OPEN_DB, absolute, as well
 * as NEAR_VAD_MARGIN_DB above the background). Inside a phrase softer frames (down to NEAR_VAD_HOLD_DB) keep it
 * open only while a near-level frame came within NEAR_VAD_SOFT_FRAMES, so the soft end of the holder's sentence
 * is kept but someone farther away who talks right after the holder cannot hold the stream open.
 *
 * Why level and not the two mics: the ES7210's two mics on this board are a few cm apart. For a talker at 20 cm
 * the level difference between them is under 1 dB, below the sensitivity tolerance of the mics themselves, and
 * in a room both talkers are within about the reverberation distance, so inter-mic coherence barely separates
 * them either. The absolute level is the cue that differs by 8-20 dB.
 *
 * Absolute levels assume MIC_GAIN_DB 36 in audio_in.c (the level ring maps -55 dBFS faint/far .. -25 dBFS
 * close/clear). The 5 s log line reports the far frames rejected and each phrase's opening level for tuning.
 */
#pragma once
#include <stdbool.h>

#define NEAR_VAD_START_FRAMES    2       /* 40 ms at the near level to open */
#define NEAR_VAD_HANGOVER_FRAMES 20      /* keep streaming 400 ms after the last held frame (the app pads silence) */
#define NEAR_VAD_MARGIN_DB       10.0f   /* every speech frame stands this far above the background */
#define NEAR_VAD_OPEN_DB         -38.0f  /* opening needs this level: the holder at <= 40 cm (~-31 dBFS and up);
                                            the user at 1 m is about -39 dBFS, at 1.5 m about -43 */
#define NEAR_VAD_HOLD_DB         -50.0f  /* inside a phrase, softer frames down to this level hold it open... */
#define NEAR_VAD_SOFT_FRAMES     25      /* ...while a frame at the open level came within the last 500 ms */
#define NEAR_VAD_FLOOR_MIN_DB    -58.0f  /* below this a frame is room hiss, never speech (the old VAD_MIN_DB) */
#define NEAR_VAD_FLOOR_RISE_DB   0.01f   /* per frame (0.5 dB/s): the floor follows slowly rising noise */

typedef enum {
    NEAR_VAD_QUIET,    /* nothing to stream (keep it as pre-roll) */
    NEAR_VAD_START,    /* a phrase opens with this frame: send the pre-roll, then the frame */
    NEAR_VAD_SPEECH,   /* inside a phrase: stream the frame */
    NEAR_VAD_END,      /* the last frame of a phrase (stream it; the hangover ran out) */
} near_vad_event_t;

typedef struct {
    float floor_db;    /* background: drops at once to quieter frames, rises NEAR_VAD_FLOOR_RISE_DB per frame */
    int above;         /* consecutive frames at the open level while closed */
    int hangover;      /* frames left before the phrase closes */
    int soft;          /* frames left in which softer frames may hold */
    bool speaking;
    unsigned far_frames;   /* frames that stood out like speech but were too quiet to open (diagnostics) */
} near_vad_t;

static inline void near_vad_reset(near_vad_t *v)
{
    v->above = 0;
    v->hangover = 0;
    v->soft = 0;
    v->speaking = false;
}

static inline void near_vad_init(near_vad_t *v, float floor_db)
{
    near_vad_reset(v);
    v->floor_db = floor_db;
    v->far_frames = 0;
}

static inline near_vad_event_t near_vad_step(near_vad_t *v, float db)
{
    if (db < v->floor_db) {
        v->floor_db = db;
    } else {
        v->floor_db += NEAR_VAD_FLOOR_RISE_DB;
    }
    bool stands_out = db > v->floor_db + NEAR_VAD_MARGIN_DB && db > NEAR_VAD_FLOOR_MIN_DB;
    bool near = stands_out && db > NEAR_VAD_OPEN_DB;

    if (!v->speaking) {
        v->above = near ? v->above + 1 : 0;
        if (stands_out && !near) {
            v->far_frames++;
        }
        if (v->above < NEAR_VAD_START_FRAMES) {
            return NEAR_VAD_QUIET;
        }
        v->speaking = true;
        v->above = 0;
        v->hangover = NEAR_VAD_HANGOVER_FRAMES;
        v->soft = NEAR_VAD_SOFT_FRAMES;
        return NEAR_VAD_START;
    }

    if (near) {
        v->soft = NEAR_VAD_SOFT_FRAMES;
    } else if (v->soft > 0) {
        v->soft--;
    }
    bool held = near || (stands_out && db > NEAR_VAD_HOLD_DB && v->soft > 0);
    if (held) {
        v->hangover = NEAR_VAD_HANGOVER_FRAMES;
        return NEAR_VAD_SPEECH;
    }
    if (--v->hangover <= 0) {
        near_vad_reset(v);
        return NEAR_VAD_END;
    }
    return NEAR_VAD_SPEECH;
}
