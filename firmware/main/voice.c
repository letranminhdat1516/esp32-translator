#include "voice.h"

#include <string.h>

/* Bounded copy into a CLAUDE_TEXT_MAX + 1 buffer (no snprintf: this runs on the NimBLE host task's stack) */
static void copy_text(char dst[CLAUDE_TEXT_MAX + 1], const char *src)
{
    size_t n = strnlen(src, CLAUDE_TEXT_MAX);
    memcpy(dst, src, n);
    dst[n] = '\0';
}

void voice_vad_init(voice_vad_t *v)
{
    memset(v, 0, sizeof(*v));
    for (int i = 0; i < VOICE_FLOOR_BLOCKS; i++) {
        v->block_min[i] = VOICE_FLOOR_SEED_DB;
    }
    v->floor_db = VOICE_FLOOR_SEED_DB;
    v->seed_peak = -200.0f;
    v->prev_db = -200.0f;
}

static float clamp_floor(float db)
{
    return db < VOICE_FLOOR_MIN_DB ? VOICE_FLOOR_MIN_DB : db;
}

/*
 * Noise floor: the quietest frame of the last 1.5 s (a sliding minimum over 5-frame blocks). Steady noise,
 * however loud, is its own floor; speech has gaps, so the floor stays at the room level under it.
 * Start: the window is seeded with VOICE_FLOOR_SEED_DB, so speech that begins at the tap is heard at once. Until
 * the seeds have rolled out (1.5 s) that is provisional: it is kept only if the first 1.5 s held a level
 * VOICE_MARGIN_DB above their own quietest frame (speech swings; a steady noise does not, and then ends as
 * nothing said).
 * After speech is heard the floor may not rise more than VOICE_ONSET_RISE_DB above its level at that moment, so
 * a held vowel or speech with shallow dips is not taken for noise; the capture ends once the level falls back.
 */
voice_vad_result_t voice_vad_step(voice_vad_t *v, float db)
{
    int in_block = v->frames % VOICE_FLOOR_BLOCK;
    if (in_block == 0 && v->frames > 0) {
        v->block = (v->block + 1) % VOICE_FLOOR_BLOCKS;
    }
    if (in_block == 0 || db < v->block_min[v->block]) {
        v->block_min[v->block] = db;
    }
    v->frames++;
    float window = v->block_min[0];
    for (int i = 1; i < VOICE_FLOOR_BLOCKS; i++) {
        if (v->block_min[i] < window) {
            window = v->block_min[i];
        }
    }
    window = clamp_floor(window);

    if (v->frames <= VOICE_FLOOR_WINDOW_FRAMES) {
        float held = db < v->prev_db ? db : v->prev_db;   /* level held for two frames */
        if (held > v->seed_peak) {
            v->seed_peak = held;
        }
    }
    v->prev_db = db;
    if (v->frames == VOICE_FLOOR_WINDOW_FRAMES && v->heard) {
        /* The seeds are gone: the window is the first 1.5 s itself. Keep the provisional speech only if it
         * stood out of them. */
        if (v->seed_peak > window + VOICE_MARGIN_DB && v->seed_peak > VOICE_MIN_DB) {
            v->onset_db = window;
        } else {
            v->heard = false;
            v->above = 0;
        }
    }

    v->floor_db = window;
    if (v->heard && v->frames >= VOICE_FLOOR_WINDOW_FRAMES && v->floor_db > v->onset_db + VOICE_ONSET_RISE_DB) {
        v->floor_db = v->onset_db + VOICE_ONSET_RISE_DB;
    }
    bool voiced = db > v->floor_db + VOICE_MARGIN_DB && db > VOICE_MIN_DB;
    v->above = voiced ? v->above + 1 : 0;
    if (v->above >= VOICE_START_FRAMES && !v->heard) {
        v->heard = true;
        v->onset_db = v->floor_db;   /* after the first 1.5 s; earlier it is set when the seeds are gone */
    }
    v->quiet = voiced ? 0 : v->quiet + 1;
    if (v->frames >= VOICE_MAX_FRAMES) {
        return VOICE_VAD_MAX;
    }
    if (v->heard && v->quiet >= VOICE_SILENCE_FRAMES) {
        return VOICE_VAD_SILENCE;
    }
    if (!v->heard && v->frames >= VOICE_NOTHING_FRAMES) {
        return VOICE_VAD_NOTHING;
    }
    return VOICE_VAD_GO;
}

void voice_reset(voice_flow_t *f)
{
    memset(f, 0, sizeof(*f));
}

bool voice_active(const voice_flow_t *f)
{
    return f->state >= VOICE_RECORDING && f->state <= VOICE_SENDING;
}

size_t voice_begin(voice_flow_t *f, uint32_t id, uint8_t purpose, uint8_t question, uint32_t target,
                   uint8_t out[CLAUDE_INPUT_MAX])
{
    if (voice_active(f)) {
        return 0;
    }
    size_t n = claude_encode_voice_start(id, purpose, question, target, out);
    if (n == 0) {
        return 0;
    }
    voice_reset(f);
    f->state = VOICE_RECORDING;
    f->id = id;
    f->purpose = purpose;
    f->question = question;
    f->target = target;
    return n;
}

bool voice_captured(voice_flow_t *f, uint32_t id)
{
    if (f->state != VOICE_RECORDING || id != f->id) {
        return false;
    }
    f->state = VOICE_FINISHING;
    return true;
}

size_t voice_cancel(voice_flow_t *f, uint8_t out[CLAUDE_INPUT_MAX])
{
    size_t n = voice_active(f) ? claude_encode_voice(f->id, CLAUDE_INPUT_VOICE_CANCEL, out) : 0;
    voice_reset(f);
    return n;
}

size_t voice_send(voice_flow_t *f, uint8_t out[CLAUDE_INPUT_MAX])
{
    if (f->state != VOICE_CONFIRM || f->empty) {
        return 0;
    }
    size_t n = claude_encode_voice(f->id, CLAUDE_INPUT_VOICE_SEND, out);
    if (n > 0) {
        f->state = VOICE_SENDING;
    }
    return n;
}

static bool blank(const char *s)
{
    for (; *s; s++) {
        if (*s != ' ') {
            return false;
        }
    }
    return true;
}

bool voice_on_update(voice_flow_t *f, const claude_voice_t *u)
{
    if (!voice_active(f) || u->id != f->id) {
        return false;
    }
    bool listening = f->state == VOICE_RECORDING || f->state == VOICE_FINISHING;
    switch (u->what) {
    case CLAUDE_VOICE_PARTIAL:
        if (!listening) {
            return false;
        }
        copy_text(f->text, u->text);
        return true;
    case CLAUDE_VOICE_FINAL:
        if (!listening) {
            return false;
        }
        copy_text(f->text, u->text);
        f->empty = blank(f->text);
        f->state = VOICE_CONFIRM;
        return true;
    case CLAUDE_VOICE_ERROR:
        voice_fail(f, u->text);
        return true;
    case CLAUDE_VOICE_DONE:
        if (f->state != VOICE_SENDING) {
            return false;
        }
        copy_text(f->note, u->text);
        f->ok = true;
        f->state = VOICE_RESULT;
        return true;
    default:
        return false;
    }
}

void voice_fail(voice_flow_t *f, const char *note)
{
    copy_text(f->note, note);
    f->ok = false;
    f->state = VOICE_RESULT;
}
