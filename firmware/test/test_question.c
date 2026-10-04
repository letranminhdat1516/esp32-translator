// firmware/test/test_question.c — build: cc -Wall -Werror -I../main -o /tmp/test_question test_question.c ../main/question.c ../main/claude_proto.c && /tmp/test_question
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "question.h"

static claude_question_t page(unsigned index, unsigned count, bool multi, unsigned nopt)
{
    claude_msg_t m;
    memset(&m, 0, sizeof m);
    m.kind = CLAUDE_QUESTION;
    m.id = 1;
    int n = snprintf(m.text, sizeof m.text, "%u %u %u %u\nproj\nHeader\nQuestion %u?", index, count, multi ? 1u : 0u,
                     nopt, index + 1);
    for (unsigned i = 0; i < nopt; i++) {
        n += snprintf(m.text + n, sizeof m.text - (size_t)n, "\nOption %u\nAbout %u", i + 1, i + 1);
    }
    claude_question_t q;
    assert(claude_parse_question(&m, &q));
    return q;
}

static question_set_t s;   /* about 1.8 KB: static, as on the board */

static void completes_when_every_page_arrived(void)
{
    question_reset(&s);
    claude_question_t p1 = page(1, 2, true, 3), p0 = page(0, 2, false, 2);
    assert(!question_add(&s, 7, &p1));   /* pages may come in any order */
    assert(!question_complete(&s));
    assert(question_add(&s, 7, &p0));
    assert(question_complete(&s) && s.page == 0);
    assert(!question_add(&s, 7, &p0));   /* a repeat does not complete it again */
}

static void new_id_starts_a_new_set(void)
{
    question_reset(&s);
    claude_question_t a = page(0, 2, false, 2), b = page(0, 1, false, 2);
    question_add(&s, 7, &a);             /* half of request 7 */
    assert(question_add(&s, 8, &b));     /* request 8 (one page) replaces it */
    assert(s.id == 8 && s.count == 1 && question_complete(&s));
}

static void ids_of_zero_are_refused(void)
{
    question_reset(&s);
    claude_question_t p = page(0, 1, false, 2);
    assert(!question_add(&s, 0, &p) && s.id == 0);
}

static void taps_wait_for_the_whole_set(void)
{
    question_reset(&s);
    claude_question_t p = page(0, 2, false, 2);
    question_add(&s, 3, &p);
    question_tap(&s, 0);
    assert(s.mask[0] == 0);
}

static void single_select_replaces_and_retap_keeps(void)
{
    question_reset(&s);
    claude_question_t p = page(0, 1, false, 3);
    question_add(&s, 1, &p);
    question_tap(&s, 2);
    assert(s.mask[0] == 0x04);
    question_tap(&s, 0);
    assert(s.mask[0] == 0x01);
    question_tap(&s, 0);                 /* tapping the chosen option keeps it */
    assert(s.mask[0] == 0x01);
    question_tap(&s, 3);                 /* no such option */
    assert(s.mask[0] == 0x01);
}

static void multi_select_needs_one(void)
{
    question_reset(&s);
    claude_question_t p = page(0, 1, true, 3);
    question_add(&s, 1, &p);
    uint8_t out[CLAUDE_INPUT_MAX];
    assert(!question_page_answered(&s, 0) && question_encode(&s, out) == 0);
    question_tap(&s, 0);
    question_tap(&s, 2);
    assert(s.mask[0] == 0x05 && question_page_answered(&s, 0));
    question_tap(&s, 0);
    question_tap(&s, 2);
    assert(s.mask[0] == 0 && !question_all_answered(&s) && question_encode(&s, out) == 0);
}

static void send_needs_every_page(void)
{
    question_reset(&s);
    claude_question_t p0 = page(0, 2, false, 2), p1 = page(1, 2, true, 3);
    question_add(&s, 0x01020304, &p0);
    question_add(&s, 0x01020304, &p1);
    assert(!question_last_page(&s));
    question_next(&s);
    assert(s.page == 0);                 /* page 1 unanswered: Next does nothing */
    question_tap(&s, 1);
    question_next(&s);
    assert(s.page == 1 && question_last_page(&s));
    uint8_t out[CLAUDE_INPUT_MAX];
    assert(question_encode(&s, out) == 0);
    question_tap(&s, 0);
    question_tap(&s, 2);
    assert(question_all_answered(&s));
    question_back(&s);
    assert(s.page == 0);
    question_back(&s);
    assert(s.page == 0);
    assert(question_encode(&s, out) == 8);
    const uint8_t want[8] = { 0x04, 0x03, 0x02, 0x01, 0x10, 0x02, 0x02, 0x05 };   /* same bytes as the Mac test */
    assert(memcmp(out, want, 8) == 0);
}

static void an_overwritten_page_loses_its_selection(void)
{
    question_reset(&s);
    claude_question_t p0 = page(0, 2, false, 3), p1 = page(1, 2, true, 3);
    question_add(&s, 7, &p0);
    question_add(&s, 7, &p1);
    question_tap(&s, 2);
    assert(question_page_answered(&s, 0));
    claude_question_t again = page(0, 2, false, 2);   /* the Mac resends page 0 with other options */
    assert(!question_add(&s, 7, &again));
    assert(!question_page_answered(&s, 0) && s.q[0].nopt == 2);
}

static void other_needs_a_spoken_text(void)
{
    question_reset(&s);
    claude_question_t p0 = page(0, 2, false, 2), p1 = page(1, 2, true, 3);
    question_add(&s, 7, &p0);
    question_add(&s, 7, &p1);
    question_tap(&s, QUESTION_OTHER);                  /* nothing spoken yet: no selection */
    assert(!question_page_answered(&s, 0));
    question_set_other(&s, 0, "Tím than");             /* Use on the confirm screen: stored and selected */
    assert(s.mask[0] == QUESTION_OTHER_BIT && strcmp(s.other[0], "Tím than") == 0);
    question_tap(&s, 1);                               /* single-select: an option replaces Other */
    assert(s.mask[0] == 0x02);
    question_tap(&s, QUESTION_OTHER);                  /* and Other replaces the option; the text stays */
    assert(s.mask[0] == QUESTION_OTHER_BIT);
    question_set_other(&s, 0, "");                     /* removed */
    assert(s.mask[0] == 0 && s.other[0][0] == '\0');
}

static void other_adds_on_multi_select_and_is_encoded(void)
{
    question_reset(&s);
    claude_question_t p0 = page(0, 2, false, 2), p1 = page(1, 2, true, 3);
    question_add(&s, 7, &p0);
    question_add(&s, 7, &p1);
    question_tap(&s, 1);
    question_next(&s);
    question_tap(&s, 0);
    question_set_other(&s, 1, "Sầu riêng");
    assert(s.mask[1] == (QUESTION_OTHER_BIT | 0x01));
    question_tap(&s, QUESTION_OTHER);                  /* multi-select: untick Other, keep the option */
    assert(s.mask[1] == 0x01);
    question_tap(&s, QUESTION_OTHER);
    uint8_t out[CLAUDE_INPUT_MAX];
    assert(question_encode(&s, out) == 8 && out[6] == 0x02 && out[7] == (QUESTION_OTHER_BIT | 0x01));
}

static void a_resent_page_loses_its_other(void)
{
    question_reset(&s);
    claude_question_t p0 = page(0, 1, false, 2);
    question_add(&s, 7, &p0);
    question_set_other(&s, 0, "Tím");
    question_add(&s, 7, &p0);                          /* the Mac resent the page */
    assert(s.mask[0] == 0 && s.other[0][0] == '\0');
}

static void long_other_is_cut_utf8_safe(void)
{
    question_reset(&s);
    claude_question_t p0 = page(0, 1, false, 2);
    question_add(&s, 7, &p0);
    char t[CLAUDE_TEXT_MAX + 1] = "";
    for (int i = 0; i < 120; i++) {
        strcat(t, "ữ");                                /* 3 bytes each: 360 bytes */
    }
    question_set_other(&s, 0, t);
    assert(strlen(s.other[0]) == CLAUDE_VOICE_TEXT_MAX);   /* 100 whole characters */
    question_set_other(&s, 3, "x");                    /* no such page: ignored */
}

int main(void)
{
    completes_when_every_page_arrived();
    new_id_starts_a_new_set();
    ids_of_zero_are_refused();
    taps_wait_for_the_whole_set();
    single_select_replaces_and_retap_keeps();
    multi_select_needs_one();
    send_needs_every_page();
    an_overwritten_page_loses_its_selection();
    other_needs_a_spoken_text();
    other_adds_on_multi_select_and_is_encoded();
    a_resent_page_loses_its_other();
    long_other_is_cut_utf8_safe();
    puts("question: all tests passed");
    return 0;
}
