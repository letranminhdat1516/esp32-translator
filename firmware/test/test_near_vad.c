// firmware/test/test_near_vad.c — build: cc -Wall -Wextra -Werror -I../main -o /tmp/test_near_vad test_near_vad.c && /tmp/test_near_vad
#include <assert.h>
#include <stdio.h>
#include "near_vad.h"

#define QUIET  -65.0f   /* room background at the board mic */
#define NEAR   -30.0f   /* the holder, 10-40 cm from the board */
#define FAR    -44.0f   /* the user, 0.5-1.5 m away */

static near_vad_t fresh(void)
{
    near_vad_t v;
    near_vad_init(&v, QUIET);
    for (int i = 0; i < 50; i++) {
        near_vad_step(&v, QUIET);
    }
    return v;
}

/* Feeds `n` frames at `db`; returns how many of them were streamed (START or SPEECH or END) */
static int feed(near_vad_t *v, float db, int n)
{
    int streamed = 0;
    for (int i = 0; i < n; i++) {
        if (near_vad_step(v, db) != NEAR_VAD_QUIET) {
            streamed++;
        }
    }
    return streamed;
}

static void near_speech_opens_after_the_start_frames(void)
{
    near_vad_t v = fresh();
    for (int i = 1; i < NEAR_VAD_START_FRAMES; i++) {
        assert(near_vad_step(&v, NEAR) == NEAR_VAD_QUIET);
    }
    assert(near_vad_step(&v, NEAR) == NEAR_VAD_START);
    assert(v.speaking);
    assert(near_vad_step(&v, NEAR) == NEAR_VAD_SPEECH);
}

static void far_speech_never_opens(void)
{
    near_vad_t v = fresh();
    /* well above the background (the old VAD opened on it), below the near level */
    assert(feed(&v, FAR, 500) == 0);
    assert(!v.speaking);
    assert(v.far_frames == 500);
}

static void quiet_room_hiss_is_not_counted_as_far_speech(void)
{
    near_vad_t v = fresh();
    feed(&v, QUIET + 3, 100);
    assert(v.far_frames == 0);
}

static void a_near_phrase_closes_after_the_hangover(void)
{
    near_vad_t v = fresh();
    feed(&v, NEAR, 20);
    for (int i = 1; i < NEAR_VAD_HANGOVER_FRAMES; i++) {
        assert(near_vad_step(&v, QUIET) == NEAR_VAD_SPEECH);
    }
    assert(near_vad_step(&v, QUIET) == NEAR_VAD_END);
    assert(!v.speaking);
    assert(near_vad_step(&v, QUIET) == NEAR_VAD_QUIET);
}

/* The softer end of the holder's sentence (below the open level, above the hold level) keeps the phrase open */
static void a_soft_tail_inside_a_near_sentence_holds(void)
{
    near_vad_t v = fresh();
    feed(&v, NEAR, 10);
    float soft = (NEAR_VAD_OPEN_DB + NEAR_VAD_HOLD_DB) / 2;
    for (int round = 0; round < 10; round++) {
        /* syllables at the near level every few hundred ms, softer ones between them */
        assert(feed(&v, soft, NEAR_VAD_SOFT_FRAMES - 1) == NEAR_VAD_SOFT_FRAMES - 1);
        assert(feed(&v, NEAR, 2) == 2);
    }
    assert(v.speaking);
}

/* The user answering right after the holder stops does not keep the phrase open: only the hangover and the soft
 * window after the last near frame are streamed */
static void far_speech_after_a_near_phrase_closes_it(void)
{
    near_vad_t v = fresh();
    feed(&v, NEAR, 20);
    int streamed = feed(&v, FAR, 500);
    assert(!v.speaking);
    assert(streamed <= NEAR_VAD_SOFT_FRAMES + NEAR_VAD_HANGOVER_FRAMES);
}

/* Far speech louder than the hold level but under the open level: held only inside the soft window */
static void far_speech_cannot_hold_after_the_soft_window(void)
{
    near_vad_t v = fresh();
    feed(&v, NEAR, 20);
    float loud_far = NEAR_VAD_OPEN_DB - 2;
    int streamed = feed(&v, loud_far, 500);
    assert(!v.speaking);
    assert(streamed <= NEAR_VAD_SOFT_FRAMES + NEAR_VAD_HANGOVER_FRAMES);
}

/* In loud surroundings the level must still stand out from the background */
static void loud_background_needs_the_margin(void)
{
    near_vad_t v;
    near_vad_init(&v, -34.0f);   /* a steady loud background, e.g. a café */
    assert(feed(&v, -30.0f, 50) == 0);
    assert(feed(&v, -22.0f, 3) > 0);
}

static void the_floor_drops_at_once_and_rises_slowly(void)
{
    near_vad_t v;
    near_vad_init(&v, -40.0f);
    near_vad_step(&v, -70.0f);
    assert(v.floor_db == -70.0f);
    feed(&v, -20.0f, 100);
    assert(v.floor_db < -70.0f + 100 * NEAR_VAD_FLOOR_RISE_DB + 0.01f);
}

static void reset_keeps_the_floor(void)
{
    near_vad_t v = fresh();
    feed(&v, NEAR, 10);
    float floor = v.floor_db;
    near_vad_reset(&v);
    assert(!v.speaking && v.above == 0 && v.hangover == 0);
    assert(v.floor_db == floor);
}

int main(void)
{
    near_speech_opens_after_the_start_frames();
    far_speech_never_opens();
    quiet_room_hiss_is_not_counted_as_far_speech();
    a_near_phrase_closes_after_the_hangover();
    a_soft_tail_inside_a_near_sentence_holds();
    far_speech_after_a_near_phrase_closes_it();
    far_speech_cannot_hold_after_the_soft_window();
    loud_background_needs_the_margin();
    the_floor_drops_at_once_and_rises_slowly();
    reset_keeps_the_floor();
    printf("near_vad: all tests passed\n");
    return 0;
}
