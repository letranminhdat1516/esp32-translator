/*
 * Voice capture on the board (Phase 3), pure C, host-tested in firmware/test/test_voice.c.
 * Endpointing (audio task, one call per 20 ms frame): an energy VAD ends a capture
 *   1.5 s after speech stops, after 5 s without any speech (the Mac then returns an empty transcript), or at 30 s.
 * Flow (voice_ui.c, display lock): recording -> finishing -> confirm -> sending -> result. Each step returns the
 *   board -> Mac input bytes to send (claude_proto.h); nothing leaves confirm except through voice_send().
 *   Mac updates (kind 8) apply only to the current voice id and only in the states that expect them.
 */
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "claude_proto.h"

#define VOICE_START_FRAMES   2       /* 40 ms above threshold = speech */
#define VOICE_SILENCE_FRAMES 75      /* 1.5 s of silence after speech ends the capture */
#define VOICE_NOTHING_FRAMES 250     /* 5 s without speech ends it */
#define VOICE_MAX_FRAMES     1500    /* 30 s cap */
#define VOICE_MARGIN_DB      10.0f   /* speech must be this far above the noise floor (the 1.5 s minimum) */
#define VOICE_MIN_DB         -58.0f  /* and above this absolute level */
#define VOICE_FLOOR_BLOCK    5       /* the floor window is kept as minima of 5-frame blocks */
#define VOICE_FLOOR_BLOCKS   15      /* the current block and the 14 before it: the last 71..75 frames */
#define VOICE_FLOOR_WINDOW_FRAMES (VOICE_FLOOR_BLOCK * VOICE_FLOOR_BLOCKS)   /* 1.5 s */
#define VOICE_FLOOR_MIN_DB   -75.0f  /* floor never below this: one near-silent frame must not pin it */

typedef enum { VOICE_VAD_GO = 0, VOICE_VAD_SILENCE, VOICE_VAD_NOTHING, VOICE_VAD_MAX } voice_vad_result_t;

typedef struct {
    float floor_db;                       /* quietest frame of the last 1.5 s, at least VOICE_FLOOR_MIN_DB */
    float block_min[VOICE_FLOOR_BLOCKS];  /* ring of block minima; block_min[block] is the current one */
    int block;
    int frames;
    int above;    /* consecutive voiced frames */
    int quiet;    /* consecutive unvoiced frames */
    bool heard;   /* speech seen in this capture */
} voice_vad_t;

void voice_vad_init(voice_vad_t *v);
voice_vad_result_t voice_vad_step(voice_vad_t *v, float db);

typedef enum {
    VOICE_IDLE = 0,
    VOICE_RECORDING,   /* mic streaming to the Mac, partials shown */
    VOICE_FINISHING,   /* stop sent, waiting for the final transcript */
    VOICE_CONFIRM,     /* final shown: Say again / Cancel / Send (Use) */
    VOICE_SENDING,     /* send sent, waiting for done / error */
    VOICE_RESULT,      /* done or error shown */
} voice_state_t;

typedef struct {
    voice_state_t state;
    uint8_t purpose;                  /* CLAUDE_VOICE_FOR_* */
    uint8_t question;                 /* page, for CLAUDE_VOICE_FOR_OTHER */
    uint32_t target;                  /* session handle or request id */
    uint32_t id;                      /* voice id, never 0 while active */
    bool ok;                          /* RESULT: done (true) or error (false) */
    bool empty;                       /* CONFIRM: nothing was heard */
    char text[CLAUDE_TEXT_MAX + 1];   /* live, then final transcript */
    char note[CLAUDE_TEXT_MAX + 1];   /* RESULT line */
} voice_flow_t;

void voice_reset(voice_flow_t *f);
bool voice_active(const voice_flow_t *f);   /* recording .. sending */
/* The start bytes and RECORDING, or 0 (busy, id or target 0, bad purpose / question) */
size_t voice_begin(voice_flow_t *f, uint32_t id, uint8_t purpose, uint8_t question, uint32_t target,
                   uint8_t out[CLAUDE_INPUT_MAX]);
/* The audio task sent the stop for `id`: RECORDING -> FINISHING. False if it no longer applies. */
bool voice_captured(voice_flow_t *f, uint32_t id);
/* Back to IDLE; the cancel bytes while active (recording .. sending), else 0 */
size_t voice_cancel(voice_flow_t *f, uint8_t out[CLAUDE_INPUT_MAX]);
/* CONFIRM with a non-empty transcript: the send bytes and SENDING; else 0 */
size_t voice_send(voice_flow_t *f, uint8_t out[CLAUDE_INPUT_MAX]);
/* Applies a kind-8 update; true when the screen must be redrawn */
bool voice_on_update(voice_flow_t *f, const claude_voice_t *u);
/* Board-side failure (link lost, no answer in time, start not sent): RESULT with `note` */
void voice_fail(voice_flow_t *f, const char *note);
