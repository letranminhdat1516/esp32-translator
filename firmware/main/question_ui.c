/*
 * AskUserQuestion pages on the Claude screen, one page per question:
 *   top    : "1/3 · project", the question's header, the question (up to 3 lines)
 *   middle : one full-width row per option, radio (single-select) or checkbox (multi-select);
 *            the list scrolls when it does not fit; long-press a row for its description
 *   bottom : Back (from page 2) and Next, or Send on the last page (disabled until answered)
 * No "Other" row in Phase 2 (voice answers come with Phase 3).
 * Selection and the answer bytes: question.c (host-tested). claude_ui.c owns the pending request, the
 * 700 ms arming and the dark-panel rule: every control asks claude_ui_tap_allowed() before acting, and
 * every page change re-arms (a double tap on Next never lands on Send).
 * Every function runs with the display lock held (LVGL callbacks, or claude_ui.c under the lock).
 * Rows are rebuilt only from the Back / Next buttons, never from a row's own event.
 */
#include <stdint.h>
#include <stdio.h>

#include "lvgl.h"

#include "app.h"
#include "question.h"

LV_FONT_DECLARE(font_vi_22);

#define COLOR_ACCENT 0x1e6fd9
#define COLOR_ROW    0x1a1a1a
#define COLOR_ROW_ON 0x16324f
#define COLOR_MUTED  0x9a9a9a
#define COLOR_OFF    0x333333
#define COLOR_BACK   0x3a3a3a

/* Layout on the 466 px circle (centre 233, r 233; chord = 2*sqrt(233^2 - (y-233)^2)):
 *   counter  y  30.. 63, 240 wide   (chord at y 34 = 242)
 *   header   y  63.. 96, 300 wide   (chord at y 63 = 318)
 *   question y  96..195, 360 wide, 3 lines, scrolls beyond (chord at y 96 = 376)
 *   options  y 202..364, 344 wide   (chord at y 202 = 462, at y 364 = 385)
 *   buttons  y 372..424 (Back -125..-15, Next/Send +10..+140 from the centre; their rounded corners stay
 *            within r 227 of the centre) */
#define LINE_H   33
#define TEXT_Y   96
#define TEXT_H   (3 * LINE_H)
#define LIST_Y   202
#define LIST_H   162

static question_set_t *s_set;   /* owned by claude_ui.c */
static lv_obj_t *s_box;
static lv_obj_t *s_counter;
static lv_obj_t *s_header;
static lv_obj_t *s_text_box;   /* scrolls the question when it needs more than 3 lines */
static lv_obj_t *s_text;
static lv_obj_t *s_list;
static lv_obj_t *s_back;
static lv_obj_t *s_next;
static lv_obj_t *s_next_label;
static lv_obj_t *s_desc;
static lv_obj_t *s_desc_label;
static lv_obj_t *s_rows[CLAUDE_OPT_MAX];
static lv_obj_t *s_marks[CLAUDE_OPT_MAX];

static void build_page(void);

static void on_pressed(lv_event_t *e)
{
    claude_ui_note_press();
}

static void refresh_marks(void)
{
    const claude_question_t *q = &s_set->q[s_set->page];
    uint8_t mask = s_set->mask[s_set->page];
    for (int i = 0; i < q->nopt && s_marks[i] != NULL; i++) {   /* rows as built (a resent page may differ) */
        bool on = (mask >> i) & 1u;
        lv_obj_set_style_bg_color(s_marks[i], lv_color_hex(on ? COLOR_ACCENT : 0x000000), 0);
        lv_obj_set_style_bg_color(s_rows[i], lv_color_hex(on ? COLOR_ROW_ON : COLOR_ROW), 0);
    }
    bool last = question_last_page(s_set);
    bool ready = last ? question_all_answered(s_set) : question_page_answered(s_set, s_set->page);
    lv_label_set_text(s_next_label, last ? "Send" : "Next");
    lv_obj_set_state(s_next, LV_STATE_DISABLED, !ready);
}

/* SHORT_CLICKED: a long press (description) never selects */
static void on_row_tap(lv_event_t *e)
{
    if (!claude_ui_tap_allowed()) {
        return;
    }
    question_tap(s_set, (uint8_t)(uintptr_t)lv_event_get_user_data(e));
    refresh_marks();
}

static void on_row_long(lv_event_t *e)
{
    if (!claude_ui_tap_allowed()) {
        return;
    }
    const claude_question_t *q = &s_set->q[s_set->page];
    int i = (int)(uintptr_t)lv_event_get_user_data(e);
    const char *d = CLAUDE_Q_STR(q, desc[i]);
    lv_label_set_text(s_desc_label, d[0] ? d : "No description.");
    lv_obj_scroll_to_y(s_desc, 0, LV_ANIM_OFF);
    lv_obj_set_hidden(s_desc, false);
    claude_ui_rearm();   /* the finger is still down: its release must not close the overlay */
}

/* Gated like the answers: a tap on the dark panel only wakes it */
static void on_desc_tap(lv_event_t *e)
{
    if (!claude_ui_tap_allowed()) {
        return;
    }
    lv_obj_set_hidden(s_desc, true);
    claude_ui_rearm();   /* a fast second tap must not land on the row the overlay covered */
}

/* The question box takes presses (to scroll): a tap on it on the dark panel still wakes it */
static void on_text_tap(lv_event_t *e)
{
    ui_wake_from_tap();
}

static void on_back(lv_event_t *e)
{
    if (!claude_ui_tap_allowed() || s_set->page == 0) {
        return;
    }
    question_back(s_set);
    build_page();
    claude_ui_rearm();
}

static void on_next(lv_event_t *e)
{
    if (!claude_ui_tap_allowed()) {
        return;
    }
    if (!question_last_page(s_set)) {
        if (question_page_answered(s_set, s_set->page)) {
            question_next(s_set);
            build_page();
            claude_ui_rearm();   /* Send may now sit under the finger */
        }
        return;
    }
    uint8_t answer[CLAUDE_INPUT_MAX];
    size_t n = question_encode(s_set, answer);
    if (n > 0) {
        claude_ui_question_send_locked(answer, n);   /* hides this box; do not touch s_set afterwards */
    }
}

/* One line (33 px for font_vi_22), "…" when longer */
static lv_obj_t *make_label(uint32_t color, int width, int y)
{
    lv_obj_t *l = lv_label_create(s_box);
    lv_obj_set_size(l, width, LINE_H);
    lv_obj_set_style_text_font(l, &font_vi_22, 0);
    lv_obj_set_style_text_color(l, lv_color_hex(color), 0);
    lv_obj_set_style_text_align(l, LV_TEXT_ALIGN_CENTER, 0);
    lv_label_set_long_mode(l, LV_LABEL_LONG_MODE_DOTS);
    lv_obj_align(l, LV_ALIGN_TOP_MID, 0, y);
    return l;
}

static lv_obj_t *make_button(const char *text, int width, lv_event_cb_t cb, lv_obj_t **label_out)
{
    lv_obj_t *b = lv_button_create(s_box);
    lv_obj_set_size(b, width, 52);
    lv_obj_set_style_radius(b, 26, 0);
    lv_obj_set_style_shadow_width(b, 0, 0);
    lv_obj_set_style_bg_color(b, lv_color_hex(COLOR_ACCENT), 0);
    lv_obj_set_style_bg_color(b, lv_color_hex(COLOR_OFF), LV_STATE_DISABLED);
    lv_obj_add_event_cb(b, on_pressed, LV_EVENT_PRESSED, NULL);
    lv_obj_add_event_cb(b, cb, LV_EVENT_CLICKED, NULL);
    lv_obj_t *l = lv_label_create(b);
    lv_obj_set_style_text_font(l, &font_vi_22, 0);
    lv_obj_set_style_text_color(l, lv_color_white(), 0);
    lv_label_set_text(l, text);
    lv_obj_center(l);
    if (label_out) {
        *label_out = l;
    }
    return b;
}

static lv_obj_t *make_row(int i, const claude_question_t *q)
{
    lv_obj_t *row = lv_obj_create(s_list);
    lv_obj_set_width(row, 330);
    lv_obj_set_height(row, LV_SIZE_CONTENT);
    lv_obj_set_style_min_height(row, 52, 0);
    lv_obj_set_style_radius(row, 16, 0);
    lv_obj_set_style_border_width(row, 0, 0);
    lv_obj_set_style_bg_opa(row, LV_OPA_COVER, 0);
    lv_obj_set_style_pad_hor(row, 14, 0);
    lv_obj_set_style_pad_ver(row, 10, 0);
    lv_obj_set_style_pad_column(row, 12, 0);
    lv_obj_set_flex_flow(row, LV_FLEX_FLOW_ROW);
    lv_obj_set_flex_align(row, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
    lv_obj_set_scrollable(row, false);   /* a drag scrolls the list */
    lv_obj_add_event_cb(row, on_pressed, LV_EVENT_PRESSED, NULL);
    lv_obj_add_event_cb(row, on_row_tap, LV_EVENT_SHORT_CLICKED, (void *)(uintptr_t)i);
    lv_obj_add_event_cb(row, on_row_long, LV_EVENT_LONG_PRESSED, (void *)(uintptr_t)i);

    lv_obj_t *mark = lv_obj_create(row);   /* radio (circle) or checkbox (rounded square) */
    lv_obj_set_size(mark, 22, 22);
    lv_obj_set_style_radius(mark, q->multi ? 4 : LV_RADIUS_CIRCLE, 0);
    lv_obj_set_style_border_width(mark, 2, 0);
    lv_obj_set_style_border_color(mark, lv_color_white(), 0);
    lv_obj_set_style_bg_opa(mark, LV_OPA_COVER, 0);
    lv_obj_set_style_pad_all(mark, 0, 0);
    lv_obj_set_clickable(mark, false);
    lv_obj_set_scrollable(mark, false);

    lv_obj_t *label = lv_label_create(row);
    lv_obj_set_width(label, 262);
    lv_obj_set_style_text_font(label, &font_vi_22, 0);
    lv_obj_set_style_text_color(label, lv_color_white(), 0);
    lv_label_set_long_mode(label, LV_LABEL_LONG_MODE_WRAP);
    lv_label_set_text(label, CLAUDE_Q_STR(q, label[i]));

    s_marks[i] = mark;
    return row;
}

static void build_page(void)
{
    const claude_question_t *q = &s_set->q[s_set->page];
    char counter[96];
    snprintf(counter, sizeof(counter), "%u/%u · %s", (unsigned)s_set->page + 1, (unsigned)s_set->count,
             CLAUDE_Q_STR(q, project));
    lv_label_set_text(s_counter, counter);
    lv_label_set_text(s_header, CLAUDE_Q_STR(q, header));
    lv_label_set_text(s_text, CLAUDE_Q_STR(q, question));
    lv_obj_scroll_to_y(s_text_box, 0, LV_ANIM_OFF);
    lv_obj_clean(s_list);
    for (int i = 0; i < CLAUDE_OPT_MAX; i++) {
        s_rows[i] = NULL;
        s_marks[i] = NULL;
    }
    for (int i = 0; i < q->nopt; i++) {
        s_rows[i] = make_row(i, q);
    }
    lv_obj_scroll_to_y(s_list, 0, LV_ANIM_OFF);
    bool first = s_set->page == 0;
    lv_obj_set_hidden(s_back, first);
    lv_obj_align(s_next, LV_ALIGN_BOTTOM_MID, first ? 0 : 75, -42);
    lv_obj_set_hidden(s_desc, true);
    refresh_marks();
}

void question_ui_init(lv_obj_t *scr, question_set_t *set)
{
    s_set = set;
    s_box = lv_obj_create(scr);   /* opaque, covers the Claude screen's own widgets while shown */
    lv_obj_set_size(s_box, 466, 466);
    lv_obj_center(s_box);
    lv_obj_set_style_bg_color(s_box, lv_color_black(), 0);
    lv_obj_set_style_bg_opa(s_box, LV_OPA_COVER, 0);
    lv_obj_set_style_border_width(s_box, 0, 0);
    lv_obj_set_style_radius(s_box, 0, 0);
    lv_obj_set_style_pad_all(s_box, 0, 0);
    lv_obj_set_scrollable(s_box, false);
    lv_obj_set_clickable(s_box, false);   /* a tap between controls reaches the screen (wakes a dark panel) */

    s_counter = make_label(COLOR_MUTED, 240, 30);
    s_header = make_label(COLOR_ACCENT, 300, 63);

    s_text_box = lv_obj_create(s_box);
    lv_obj_set_size(s_text_box, 360, TEXT_H);
    lv_obj_align(s_text_box, LV_ALIGN_TOP_MID, 0, TEXT_Y);
    lv_obj_set_style_bg_opa(s_text_box, LV_OPA_TRANSP, 0);
    lv_obj_set_style_border_width(s_text_box, 0, 0);
    lv_obj_set_style_pad_all(s_text_box, 0, 0);
    lv_obj_set_style_radius(s_text_box, 0, 0);
    lv_obj_set_scroll_dir(s_text_box, LV_DIR_VER);
    lv_obj_set_scrollbar_mode(s_text_box, LV_SCROLLBAR_MODE_AUTO);
    lv_obj_add_event_cb(s_text_box, on_text_tap, LV_EVENT_CLICKED, NULL);
    s_text = lv_label_create(s_text_box);
    lv_obj_set_width(s_text, 360);
    lv_obj_set_style_text_font(s_text, &font_vi_22, 0);
    lv_obj_set_style_text_color(s_text, lv_color_white(), 0);
    lv_obj_set_style_text_align(s_text, LV_TEXT_ALIGN_CENTER, 0);
    lv_label_set_long_mode(s_text, LV_LABEL_LONG_MODE_WRAP);
    lv_obj_align(s_text, LV_ALIGN_TOP_MID, 0, 0);

    s_list = lv_obj_create(s_box);
    lv_obj_set_size(s_list, 344, LIST_H);
    lv_obj_align(s_list, LV_ALIGN_TOP_MID, 0, LIST_Y);
    lv_obj_set_style_bg_opa(s_list, LV_OPA_TRANSP, 0);
    lv_obj_set_style_border_width(s_list, 0, 0);
    lv_obj_set_style_pad_all(s_list, 0, 0);
    lv_obj_set_style_pad_row(s_list, 6, 0);
    lv_obj_set_flex_flow(s_list, LV_FLEX_FLOW_COLUMN);
    lv_obj_set_flex_align(s_list, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
    lv_obj_set_scroll_dir(s_list, LV_DIR_VER);
    lv_obj_set_scrollbar_mode(s_list, LV_SCROLLBAR_MODE_AUTO);
    lv_obj_set_clickable(s_list, false);   /* rows take the presses; a drag on a row scrolls the list */

    s_back = make_button("Back", 110, on_back, NULL);
    lv_obj_set_style_bg_color(s_back, lv_color_hex(COLOR_BACK), 0);
    lv_obj_align(s_back, LV_ALIGN_BOTTOM_MID, -70, -42);
    s_next = make_button("Next", 130, on_next, &s_next_label);
    lv_obj_align(s_next, LV_ALIGN_BOTTOM_MID, 75, -42);

    /* Created last: on top of the list and the buttons. Sized to the text up to 380 x 260 (rounded corners
     * within r 223 of the centre), scrolls beyond: a drag scrolls it, a tap closes it. */
    s_desc = lv_obj_create(s_box);
    lv_obj_set_size(s_desc, 380, LV_SIZE_CONTENT);
    lv_obj_set_style_max_height(s_desc, 260, 0);
    lv_obj_center(s_desc);
    lv_obj_set_style_bg_color(s_desc, lv_color_hex(0x202020), 0);
    lv_obj_set_style_bg_opa(s_desc, LV_OPA_COVER, 0);
    lv_obj_set_style_radius(s_desc, 20, 0);
    lv_obj_set_style_border_width(s_desc, 0, 0);
    lv_obj_set_style_pad_all(s_desc, 20, 0);
    lv_obj_set_scroll_dir(s_desc, LV_DIR_VER);
    lv_obj_set_scrollbar_mode(s_desc, LV_SCROLLBAR_MODE_AUTO);
    lv_obj_add_event_cb(s_desc, on_pressed, LV_EVENT_PRESSED, NULL);
    lv_obj_add_event_cb(s_desc, on_desc_tap, LV_EVENT_CLICKED, NULL);
    s_desc_label = lv_label_create(s_desc);
    lv_obj_set_width(s_desc_label, 340);
    lv_obj_set_style_text_font(s_desc_label, &font_vi_22, 0);
    lv_obj_set_style_text_color(s_desc_label, lv_color_white(), 0);
    lv_obj_set_style_text_align(s_desc_label, LV_TEXT_ALIGN_CENTER, 0);
    lv_label_set_long_mode(s_desc_label, LV_LABEL_LONG_MODE_WRAP);
    lv_obj_align(s_desc_label, LV_ALIGN_TOP_MID, 0, 0);

    lv_obj_set_hidden(s_desc, true);
    lv_obj_set_hidden(s_box, true);
}

void question_ui_show(void)
{
    if (s_box == NULL || !question_complete(s_set)) {
        return;
    }
    s_set->page = 0;
    build_page();
    lv_obj_set_hidden(s_box, false);
}

void question_ui_refresh(void)
{
    if (s_box == NULL || lv_obj_is_hidden(s_box) || !question_complete(s_set)) {
        return;
    }
    if (s_set->page >= s_set->count) {
        s_set->page = 0;
    }
    build_page();
}

void question_ui_hide(void)
{
    if (s_box == NULL) {
        return;
    }
    lv_obj_set_hidden(s_desc, true);
    lv_obj_set_hidden(s_box, true);
}

void question_ui_set_other(uint8_t page, const char *text)
{
    question_set_other(s_set, page, text);
    if (s_box != NULL && !lv_obj_is_hidden(s_box) && page == s_set->page) {
        build_page();   /* from the voice result (NimBLE host task, lock held), never from a row's own event */
    }
}
