#include "claude_proto.h"

#include <stdlib.h>
#include <string.h>

#define FLAG_FIRST 0x01
#define FLAG_LAST  0x02

size_t claude_utf8_cut(const char *str, size_t n)
{
    const uint8_t *s = (const uint8_t *)str;
    size_t i = n;
    while (i > 0 && (s[i - 1] & 0xC0) == 0x80) {
        i--;
    }
    if (i > 0 && (s[i - 1] & 0x80)) {
        uint8_t lead = s[i - 1];
        size_t need = (lead & 0xE0) == 0xC0 ? 2 : (lead & 0xF0) == 0xE0 ? 3 : (lead & 0xF8) == 0xF0 ? 4 : 1;
        if (n - (i - 1) < need) {
            return i - 1;
        }
    }
    return n;
}

bool claude_rx_feed(claude_rx_t *rx, const uint8_t *chunk, size_t len, claude_msg_t *out)
{
    if (len < 1) {
        return false;
    }
    uint8_t flags = chunk[0];
    if (flags & FLAG_FIRST) {
        rx->len = 0;
    }
    size_t n = len - 1;
    if (rx->len + n > sizeof(rx->buf)) {
        n = sizeof(rx->buf) - rx->len;
    }
    memcpy(rx->buf + rx->len, chunk + 1, n);
    rx->len += n;

    if (!(flags & FLAG_LAST) || rx->len < 5) {
        return false;
    }
    out->kind = (claude_kind_t)rx->buf[0];
    out->id = (uint32_t)rx->buf[1] | (uint32_t)rx->buf[2] << 8 | (uint32_t)rx->buf[3] << 16 | (uint32_t)rx->buf[4] << 24;
    size_t text_len = claude_utf8_cut((const char *)rx->buf + 5, rx->len - 5);
    memcpy(out->text, rx->buf + 5, text_len);
    out->text[text_len] = '\0';
    rx->len = 0;
    return true;
}

static void put32(uint8_t *p, uint32_t v)
{
    p[0] = v & 0xff;
    p[1] = (v >> 8) & 0xff;
    p[2] = (v >> 16) & 0xff;
    p[3] = (v >> 24) & 0xff;
}

void claude_encode_answer(uint32_t id, uint8_t decision, uint8_t out[5])
{
    put32(out, id);
    out[4] = decision;
}

size_t claude_encode_answers(uint32_t id, const uint8_t *masks, size_t n, uint8_t out[CLAUDE_INPUT_MAX])
{
    if (id == 0 || masks == NULL || n < 1 || n > CLAUDE_Q_MAX) {
        return 0;
    }
    put32(out, id);
    out[4] = CLAUDE_INPUT_ANSWERS;
    out[5] = (uint8_t)n;
    memcpy(out + 6, masks, n);
    return 6 + n;
}

size_t claude_encode_mode(uint8_t mode, uint8_t out[CLAUDE_INPUT_MAX])
{
    put32(out, 0);
    out[4] = CLAUDE_INPUT_MODE;
    out[5] = mode;
    return 6;
}

size_t claude_encode_focus(uint32_t handle, uint8_t out[CLAUDE_INPUT_MAX])
{
    if (handle == 0) {
        return 0;
    }
    put32(out, 0);
    out[4] = CLAUDE_INPUT_FOCUS;
    put32(out + 5, handle);
    return 9;
}

size_t claude_split_lines(char *text, char **fields, size_t max)
{
    size_t n = 0;
    char *p = text;
    while (n < max) {
        fields[n++] = p;
        if (n == max) {
            break;
        }
        char *nl = strchr(p, '\n');
        if (nl == NULL) {
            break;
        }
        *nl = '\0';
        p = nl + 1;
    }
    return n;
}

/* One decimal integer (optional sign) followed by a single space or the end of the string */
static bool take_int(const char **p, long long *out)
{
    char *end;
    long long v = strtoll(*p, &end, 10);
    if (end == *p || **p == ' ') {
        return false;
    }
    if (*end == ' ') {
        end++;
    } else if (*end != '\0') {
        return false;
    }
    *out = v;
    *p = end;
    return true;
}

bool claude_parse_session(const claude_msg_t *m, claude_session_t *out)
{
    if (m->kind != CLAUDE_SESSION || m->id == 0) {
        return false;
    }
    const char *nl1 = strchr(m->text, '\n');
    const char *nl2 = nl1 ? strchr(nl1 + 1, '\n') : NULL;
    if (nl2 == NULL) {
        return false;
    }
    char meta[64];
    size_t ml = (size_t)(nl1 - m->text);
    if (ml < 3 || ml >= sizeof(meta)) {
        return false;
    }
    memcpy(meta, m->text, ml);
    meta[ml] = '\0';
    char state = meta[0];
    if (meta[1] != ' ' || (state != CLAUDE_STATE_NEEDS_YOU && state != CLAUDE_STATE_WORKING &&
                           state != CLAUDE_STATE_IDLE && state != CLAUDE_STATE_ENDED)) {
        return false;
    }
    const char *p = meta + 2;
    long long since, updated, flags;
    if (!take_int(&p, &since) || !take_int(&p, &updated) || !take_int(&p, &flags) || *p != '\0' ||
        flags < 0 || flags > (CLAUDE_SESSION_FOCUSED | CLAUDE_SESSION_UNSEEN)) {
        return false;
    }
    out->handle = m->id;
    out->state = state;
    out->flags = (uint8_t)flags;
    out->since = since;
    out->updated = updated;
    size_t pl = (size_t)(nl2 - nl1 - 1);
    pl = claude_utf8_cut(nl1 + 1, pl > CLAUDE_PROJECT_MAX ? CLAUDE_PROJECT_MAX : pl);
    memcpy(out->project, nl1 + 1, pl);
    out->project[pl] = '\0';
    size_t ll = strlen(nl2 + 1);   /* part of m->text: at most CLAUDE_TEXT_MAX */
    memcpy(out->line, nl2 + 1, ll + 1);
    return true;
}

bool claude_parse_question(const claude_msg_t *m, claude_question_t *q)
{
    if (m->kind != CLAUDE_QUESTION || m->id == 0) {
        return false;
    }
    memset(q, 0, sizeof(*q));
    size_t len = strlen(m->text);
    memcpy(q->buf, m->text, len + 1);
    size_t lines = 1;
    for (size_t i = 0; i < len; i++) {
        if (q->buf[i] == '\n') {
            lines++;
        }
    }
    if (lines < 6 || lines > 4 + 2 * CLAUDE_OPT_MAX) {
        return false;
    }
    char *f[4 + 2 * CLAUDE_OPT_MAX];
    claude_split_lines(q->buf, f, lines);
    const char *p = f[0];
    long long index, count, multi, nopt;
    if (!take_int(&p, &index) || !take_int(&p, &count) || !take_int(&p, &multi) || !take_int(&p, &nopt) ||
        *p != '\0') {
        return false;
    }
    if (count < 1 || count > CLAUDE_Q_MAX || index < 0 || index >= count || (multi != 0 && multi != 1) ||
        nopt < 1 || nopt > CLAUDE_OPT_MAX || lines != (size_t)(4 + 2 * nopt)) {
        return false;
    }
    q->index = (uint8_t)index;
    q->count = (uint8_t)count;
    q->multi = multi == 1;
    q->nopt = (uint8_t)nopt;
    q->project = (uint16_t)(f[1] - q->buf);
    q->header = (uint16_t)(f[2] - q->buf);
    q->question = (uint16_t)(f[3] - q->buf);
    for (int i = 0; i < q->nopt; i++) {
        if (f[4 + 2 * i][0] == '\0') {
            return false;   /* every option needs a label */
        }
        q->label[i] = (uint16_t)(f[4 + 2 * i] - q->buf);
        q->desc[i] = (uint16_t)(f[5 + 2 * i] - q->buf);
    }
    return true;
}
