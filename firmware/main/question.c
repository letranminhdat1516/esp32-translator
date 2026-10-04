#include "question.h"

#include <string.h>

void question_reset(question_set_t *s)
{
    memset(s, 0, sizeof(*s));
}

bool question_complete(const question_set_t *s)
{
    return s->id != 0 && s->count > 0 && s->have == (uint8_t)((1u << s->count) - 1);
}

bool question_add(question_set_t *s, uint32_t id, const claude_question_t *page)
{
    if (id == 0 || page->count == 0 || page->count > CLAUDE_Q_MAX || page->index >= page->count) {
        return false;
    }
    if (s->id != id || s->count != page->count) {
        question_reset(s);
        s->id = id;
        s->count = page->count;
    }
    bool was_complete = question_complete(s);
    s->q[page->index] = *page;
    s->mask[page->index] = 0;   /* a resent page may carry other options: its old selection no longer applies */
    s->other[page->index][0] = '\0';
    s->have |= (uint8_t)(1u << page->index);
    return !was_complete && question_complete(s);
}

void question_tap(question_set_t *s, uint8_t option)
{
    if (!question_complete(s) || s->page >= s->count) {
        return;
    }
    const claude_question_t *q = &s->q[s->page];
    uint8_t bit;
    if (option == QUESTION_OTHER) {
        if (s->other[s->page][0] == '\0') {
            return;   /* nothing spoken yet: the row starts a voice capture instead (question_ui.c) */
        }
        bit = QUESTION_OTHER_BIT;
    } else if (option < q->nopt) {
        bit = (uint8_t)(1u << option);
    } else {
        return;
    }
    if (q->multi) {
        s->mask[s->page] ^= bit;
    } else {
        s->mask[s->page] = bit;
    }
}

void question_set_other(question_set_t *s, uint8_t page, const char *text)
{
    if (!question_complete(s) || page >= s->count) {
        return;
    }
    size_t n = claude_utf8_cut(text, strnlen(text, CLAUDE_VOICE_TEXT_MAX));
    memcpy(s->other[page], text, n);
    s->other[page][n] = '\0';
    if (n == 0) {
        s->mask[page] &= (uint8_t)~QUESTION_OTHER_BIT;
    } else if (s->q[page].multi) {
        s->mask[page] |= QUESTION_OTHER_BIT;
    } else {
        s->mask[page] = QUESTION_OTHER_BIT;
    }
}

bool question_page_answered(const question_set_t *s, uint8_t page)
{
    return page < s->count && s->mask[page] != 0;
}

bool question_all_answered(const question_set_t *s)
{
    if (!question_complete(s)) {
        return false;
    }
    for (uint8_t i = 0; i < s->count; i++) {
        if (s->mask[i] == 0) {
            return false;
        }
    }
    return true;
}

bool question_last_page(const question_set_t *s)
{
    return s->page + 1 >= s->count;
}

void question_next(question_set_t *s)
{
    if (!question_last_page(s) && question_page_answered(s, s->page)) {
        s->page++;
    }
}

void question_back(question_set_t *s)
{
    if (s->page > 0) {
        s->page--;
    }
}

size_t question_encode(const question_set_t *s, uint8_t out[CLAUDE_INPUT_MAX])
{
    if (!question_all_answered(s)) {
        return 0;
    }
    return claude_encode_answers(s->id, s->mask, s->count, out);
}
