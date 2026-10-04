// firmware/test/test_voice.c — build: cc -Wall -Wextra -Werror -I../main -o /tmp/test_voice test_voice.c ../main/voice.c ../main/claude_proto.c && /tmp/test_voice
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "voice.h"

/* Feeds n frames at db; the capture may only end on the last one */
static voice_vad_result_t feed(voice_vad_t *v, float db, int n)
{
    voice_vad_result_t r = VOICE_VAD_GO;
    for (int i = 0; i < n; i++) {
        r = voice_vad_step(v, db);
        assert(r == VOICE_VAD_GO || i == n - 1);
    }
    return r;
}

static void vad_ends_after_silence_following_speech(void)
{
    voice_vad_t v;
    voice_vad_init(&v);
    assert(feed(&v, -70.0f, 10) == VOICE_VAD_GO);                      /* room before speaking */
    assert(feed(&v, -30.0f, 20) == VOICE_VAD_GO);                      /* 400 ms of speech */
    assert(feed(&v, -70.0f, VOICE_SILENCE_FRAMES - 1) == VOICE_VAD_GO);
    assert(voice_vad_step(&v, -70.0f) == VOICE_VAD_SILENCE);           /* 1.5 s of silence */
}

static void vad_pause_inside_a_sentence_keeps_going(void)
{
    voice_vad_t v;
    voice_vad_init(&v);
    assert(feed(&v, -30.0f, 20) == VOICE_VAD_GO);
    assert(feed(&v, -70.0f, 50) == VOICE_VAD_GO);                      /* 1 s pause */
    assert(feed(&v, -30.0f, 20) == VOICE_VAD_GO);
    assert(feed(&v, -70.0f, VOICE_SILENCE_FRAMES) == VOICE_VAD_SILENCE);
}

static void vad_ends_when_nothing_is_said(void)
{
    voice_vad_t v;
    voice_vad_init(&v);
    assert(feed(&v, -70.0f, VOICE_NOTHING_FRAMES - 1) == VOICE_VAD_GO);
    assert(voice_vad_step(&v, -70.0f) == VOICE_VAD_NOTHING);
}

static void vad_click_is_not_speech(void)
{
    voice_vad_t v;
    voice_vad_init(&v);
    assert(voice_vad_step(&v, -20.0f) == VOICE_VAD_GO);                /* one loud frame: a tap on the case */
    assert(feed(&v, -70.0f, VOICE_NOTHING_FRAMES - 1) == VOICE_VAD_NOTHING);
}

static void vad_caps_a_long_capture(void)
{
    voice_vad_t v;
    voice_vad_init(&v);
    /* Talking without a 1.5 s pause: 200 ms of speech, 100 ms between words */
    voice_vad_result_t r = VOICE_VAD_GO;
    int n = 0;
    while (r == VOICE_VAD_GO) {
        r = voice_vad_step(&v, n % 15 < 10 ? -30.0f : -60.0f);
        n++;
    }
    assert(r == VOICE_VAD_MAX && n == VOICE_MAX_FRAMES);
}

static void vad_floor_is_clamped_after_a_near_silent_frame(void)
{
    voice_vad_t v;
    voice_vad_init(&v);
    assert(voice_vad_step(&v, -110.0f) == VOICE_VAD_GO);               /* one near-silent frame (codec start) */
    assert(v.floor_db == VOICE_FLOOR_MIN_DB);                          /* not pinned near -100 dB */
    /* It leaves the floor window after 1.5 s: a steady hum after it is room noise again, not speech */
    voice_vad_result_t r = VOICE_VAD_GO;
    int n = 1;
    while (r == VOICE_VAD_GO) {
        r = voice_vad_step(&v, -56.0f);
        n++;
    }
    assert(n <= VOICE_FLOOR_WINDOW_FRAMES + VOICE_SILENCE_FRAMES + 1);   /* ~3 s, not the 30 s cap */
}

static void vad_steady_noise_is_nothing(void)
{
    /* A loud room (fan, traffic) well above VOICE_MIN_DB and the -60 dB seeds: still nothing said after 5 s */
    const float levels[] = { -55.0f, -48.0f, -40.0f, -30.0f };
    for (size_t i = 0; i < sizeof levels / sizeof levels[0]; i++) {
        voice_vad_t v;
        voice_vad_init(&v);
        assert(feed(&v, levels[i], VOICE_NOTHING_FRAMES - 1) == VOICE_VAD_GO);
        assert(voice_vad_step(&v, levels[i]) == VOICE_VAD_NOTHING);
    }
}

static void vad_speech_over_a_noisy_bed(void)
{
    voice_vad_t v;
    voice_vad_init(&v);
    assert(feed(&v, -45.0f, 25) == VOICE_VAD_GO);                      /* 0.5 s of the bed */
    for (int i = 0; i < 4; i++) {
        assert(feed(&v, -30.0f, 15) == VOICE_VAD_GO);                  /* 300 ms words */
        assert(feed(&v, -45.0f, 15) == VOICE_VAD_GO);                  /* 300 ms gaps */
    }
    assert(v.heard);
    /* 1.5 s after the last word (15 gap frames already passed) */
    assert(feed(&v, -45.0f, VOICE_SILENCE_FRAMES - 15) == VOICE_VAD_SILENCE);
}

static void vad_speech_at_the_tap_is_heard(void)
{
    voice_vad_t v;
    voice_vad_init(&v);
    /* Talking from the first frame: 200 ms words at -30 dB, 60 ms dips to -50 dB, 8 words */
    for (int w = 0; w < 8; w++) {
        if (w > 0) {
            assert(feed(&v, -50.0f, 3) == VOICE_VAD_GO);
        }
        assert(feed(&v, -30.0f, 10) == VOICE_VAD_GO);
    }
    assert(v.heard);
    assert(feed(&v, -60.0f, VOICE_SILENCE_FRAMES - 1) == VOICE_VAD_GO);   /* the room after the last word */
    assert(voice_vad_step(&v, -60.0f) == VOICE_VAD_SILENCE);
}

static void vad_held_vowel_is_not_cut(void)
{
    voice_vad_t v;
    voice_vad_init(&v);
    assert(feed(&v, -60.0f, 25) == VOICE_VAD_GO);                      /* 0.5 s room */
    assert(feed(&v, -30.0f, 200) == VOICE_VAD_GO);                     /* 4 s "aaa…" with no dip */
    assert(feed(&v, -60.0f, VOICE_SILENCE_FRAMES - 1) == VOICE_VAD_GO);
    assert(voice_vad_step(&v, -60.0f) == VOICE_VAD_SILENCE);
}

static voice_flow_t f;   /* about 0.8 KB: static, as on the board */

static claude_voice_t update(uint32_t id, char what, const char *text)
{
    claude_voice_t u;
    memset(&u, 0, sizeof u);
    u.id = id;
    u.what = what;
    snprintf(u.text, sizeof u.text, "%s", text);
    return u;
}

static void begin_encodes_the_start(void)
{
    uint8_t out[CLAUDE_INPUT_MAX];
    voice_reset(&f);
    assert(voice_begin(&f, 0x0A0B0C0D, CLAUDE_VOICE_FOR_OTHER, 2, 0x01020304, out) == 10);
    const uint8_t want[10] = { 0x0d, 0x0c, 0x0b, 0x0a, 0x30, 0x21, 0x04, 0x03, 0x02, 0x01 };
    assert(memcmp(out, want, 10) == 0);
    assert(f.state == VOICE_RECORDING && voice_active(&f));
    assert(f.id == 0x0A0B0C0D && f.purpose == CLAUDE_VOICE_FOR_OTHER && f.question == 2 && f.target == 0x01020304);
    assert(voice_begin(&f, 10, CLAUDE_VOICE_FOR_COMMAND, 0, 5, out) == 0);    /* one capture at a time */
    voice_reset(&f);
    assert(voice_begin(&f, 0, CLAUDE_VOICE_FOR_COMMAND, 0, 5, out) == 0);
    assert(voice_begin(&f, 9, CLAUDE_VOICE_FOR_COMMAND, 0, 0, out) == 0);
    assert(voice_begin(&f, 9, CLAUDE_VOICE_FOR_COMMAND, 1, 5, out) == 0);
    assert(f.state == VOICE_IDLE && !voice_active(&f));
}

static void command_round_trip(void)
{
    uint8_t out[CLAUDE_INPUT_MAX];
    voice_reset(&f);
    assert(voice_begin(&f, 9, CLAUDE_VOICE_FOR_COMMAND, 0, 5, out) == 10);
    claude_voice_t u = update(9, CLAUDE_VOICE_PARTIAL, "chạy các");
    assert(voice_on_update(&f, &u) && f.state == VOICE_RECORDING && strcmp(f.text, "chạy các") == 0);
    assert(voice_send(&f, out) == 0);                                  /* nothing to send while recording */
    assert(!voice_captured(&f, 10));
    assert(voice_captured(&f, 9) && f.state == VOICE_FINISHING);
    u = update(9, CLAUDE_VOICE_FINAL, "chạy các bài kiểm tra");
    assert(voice_on_update(&f, &u) && f.state == VOICE_CONFIRM && !f.empty);
    assert(strcmp(f.text, "chạy các bài kiểm tra") == 0);
    u = update(9, CLAUDE_VOICE_PARTIAL, "late");                     /* never changes what Send sends */
    assert(!voice_on_update(&f, &u) && strcmp(f.text, "chạy các bài kiểm tra") == 0);
    assert(voice_send(&f, out) == 5);
    const uint8_t want_send[5] = { 9, 0, 0, 0, 0x33 };
    assert(memcmp(out, want_send, 5) == 0 && f.state == VOICE_SENDING);
    assert(voice_send(&f, out) == 0);                                  /* one Send only */
    u = update(9, CLAUDE_VOICE_DONE, "Sent to esp32");
    assert(voice_on_update(&f, &u) && f.state == VOICE_RESULT && f.ok && strcmp(f.note, "Sent to esp32") == 0);
    assert(!voice_active(&f));
    assert(voice_cancel(&f, out) == 0 && f.state == VOICE_IDLE);       /* closing a result sends nothing */
}

static void final_may_arrive_before_the_capture_callback(void)
{
    uint8_t out[CLAUDE_INPUT_MAX];
    voice_reset(&f);
    voice_begin(&f, 9, CLAUDE_VOICE_FOR_COMMAND, 0, 5, out);
    claude_voice_t u = update(9, CLAUDE_VOICE_FINAL, "xin chào");
    assert(voice_on_update(&f, &u) && f.state == VOICE_CONFIRM);
    assert(!voice_captured(&f, 9) && f.state == VOICE_CONFIRM);
}

static void empty_final_cannot_be_sent(void)
{
    uint8_t out[CLAUDE_INPUT_MAX];
    const char *empties[] = { "", "   " };
    for (int i = 0; i < 2; i++) {
        voice_reset(&f);
        voice_begin(&f, 9, CLAUDE_VOICE_FOR_COMMAND, 0, 5, out);
        voice_captured(&f, 9);
        claude_voice_t u = update(9, CLAUDE_VOICE_FINAL, empties[i]);
        assert(voice_on_update(&f, &u) && f.state == VOICE_CONFIRM && f.empty);
        assert(voice_send(&f, out) == 0 && f.state == VOICE_CONFIRM);
    }
}

static void errors_end_the_capture(void)
{
    uint8_t out[CLAUDE_INPUT_MAX];
    voice_reset(&f);
    voice_begin(&f, 9, CLAUDE_VOICE_FOR_COMMAND, 0, 5, out);
    claude_voice_t u = update(9, CLAUDE_VOICE_ERROR, "Open with cb for voice");
    assert(voice_on_update(&f, &u) && f.state == VOICE_RESULT && !f.ok);
    assert(strcmp(f.note, "Open with cb for voice") == 0 && !voice_active(&f));
    u = update(9, CLAUDE_VOICE_DONE, "late");
    assert(!voice_on_update(&f, &u));
}

static void done_needs_a_send(void)
{
    uint8_t out[CLAUDE_INPUT_MAX];
    voice_reset(&f);
    voice_begin(&f, 9, CLAUDE_VOICE_FOR_COMMAND, 0, 5, out);
    claude_voice_t u = update(9, CLAUDE_VOICE_FINAL, "x");
    voice_on_update(&f, &u);
    u = update(9, CLAUDE_VOICE_DONE, "Sent");
    assert(!voice_on_update(&f, &u) && f.state == VOICE_CONFIRM);      /* done without our Send: ignored */
}

static void stale_updates_are_ignored(void)
{
    uint8_t out[CLAUDE_INPUT_MAX];
    voice_reset(&f);
    voice_begin(&f, 9, CLAUDE_VOICE_FOR_COMMAND, 0, 5, out);
    assert(voice_cancel(&f, out) == 5);
    const uint8_t want_cancel[5] = { 9, 0, 0, 0, 0x32 };
    assert(memcmp(out, want_cancel, 5) == 0 && f.state == VOICE_IDLE);
    claude_voice_t u = update(9, CLAUDE_VOICE_FINAL, "old");
    assert(!voice_on_update(&f, &u) && f.state == VOICE_IDLE);         /* the capture was cancelled */
    voice_begin(&f, 10, CLAUDE_VOICE_FOR_COMMAND, 0, 5, out);          /* Say again */
    assert(!voice_on_update(&f, &u) && f.state == VOICE_RECORDING && f.text[0] == '\0');
    assert(!voice_captured(&f, 9));
}

static void board_side_failure_shows_a_result(void)
{
    uint8_t out[CLAUDE_INPUT_MAX];
    voice_reset(&f);
    voice_begin(&f, 9, CLAUDE_VOICE_FOR_DENY, 0, 7, out);
    voice_captured(&f, 9);
    voice_fail(&f, "No answer from the Mac.");
    assert(f.state == VOICE_RESULT && !f.ok && strcmp(f.note, "No answer from the Mac.") == 0);
    assert(f.purpose == CLAUDE_VOICE_FOR_DENY && f.target == 7);       /* the caller still knows what it was for */
    voice_reset(&f);
    voice_fail(&f, "Mac not connected.");                              /* a start that never went out */
    assert(f.state == VOICE_RESULT && !f.ok);
    static char longer[2 * CLAUDE_TEXT_MAX];
    memset(longer, 'a', sizeof longer - 1);
    voice_fail(&f, longer);                                            /* bounded copy */
    assert(strlen(f.note) == CLAUDE_TEXT_MAX);
}

int main(void)
{
    vad_ends_after_silence_following_speech();
    vad_pause_inside_a_sentence_keeps_going();
    vad_ends_when_nothing_is_said();
    vad_click_is_not_speech();
    vad_caps_a_long_capture();
    vad_floor_is_clamped_after_a_near_silent_frame();
    vad_steady_noise_is_nothing();
    vad_speech_over_a_noisy_bed();
    vad_speech_at_the_tap_is_heard();
    vad_held_vowel_is_not_cut();
    begin_encodes_the_start();
    command_round_trip();
    final_may_arrive_before_the_capture_callback();
    empty_final_cannot_be_sent();
    errors_end_the_capture();
    done_needs_a_send();
    stale_updates_are_ignored();
    board_side_failure_shows_a_result();
    puts("voice: all tests passed");
    return 0;
}
