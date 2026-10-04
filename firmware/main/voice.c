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
    v->floor_db = -60.0f;
}

voice_vad_result_t voice_vad_step(voice_vad_t *v, float db)
{
    v->frames++;
    /* Noise floor: drops at once to quieter frames, rises slowly so speech does not lift it */
    if (db < v->floor_db) {
        v->floor_db = db < VOICE_FLOOR_MIN_DB ? VOICE_FLOOR_MIN_DB : db;
    } else {
        v->floor_db += VOICE_FLOOR_RISE_DB;
    }
    bool voiced = db > v->floor_db + VOICE_MARGIN_DB && db > VOICE_MIN_DB;
    v->above = voiced ? v->above + 1 : 0;
    if (v->above >= VOICE_START_FRAMES) {
        v->heard = true;
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
