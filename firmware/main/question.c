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
    s->have |= (uint8_t)(1u << page->index);
    return !was_complete && question_complete(s);
}

void question_tap(question_set_t *s, uint8_t option)
{
    if (!question_complete(s) || s->page >= s->count) {
        return;
    }
    const claude_question_t *q = &s->q[s->page];
    if (option >= q->nopt) {
        return;
    }
    uint8_t bit = (uint8_t)(1u << option);
    if (q->multi) {
        s->mask[s->page] ^= bit;
    } else {
        s->mask[s->page] = bit;
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
