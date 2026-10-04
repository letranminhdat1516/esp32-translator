/*
 * AskUserQuestion pages on the board (pure C, host-tested in firmware/test/test_question.c).
 * The Mac sends one kind-7 message per question, all with the request id; the set is shown once every
 * page is in. Single-select: a tap selects that option (tapping it again keeps it). Multi-select: a tap
 * toggles. Next needs the page answered; Send (last page) needs every page answered.
 */
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "claude_proto.h"

typedef struct {
    uint32_t id;                      /* request id; 0 = empty */
    uint8_t count;                    /* pages expected */
    uint8_t have;                     /* bit i = page i received */
    uint8_t page;                     /* page on screen */
    uint8_t mask[CLAUDE_Q_MAX];       /* bit i = option i chosen */
    claude_question_t q[CLAUDE_Q_MAX];
} question_set_t;

void question_reset(question_set_t *s);
/* Stores one page; a page with another id (or page count) starts a new set. True when the set has just
 * become complete. */
bool question_add(question_set_t *s, uint32_t id, const claude_question_t *page);
bool question_complete(const question_set_t *s);
void question_tap(question_set_t *s, uint8_t option);
bool question_page_answered(const question_set_t *s, uint8_t page);
bool question_all_answered(const question_set_t *s);
bool question_last_page(const question_set_t *s);
void question_next(question_set_t *s);   /* only from an answered page */
void question_back(question_set_t *s);
/* The answer bytes (claude_encode_answers), or 0 until every page is answered */
size_t question_encode(const question_set_t *s, uint8_t out[CLAUDE_INPUT_MAX]);
