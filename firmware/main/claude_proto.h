#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define CLAUDE_TEXT_MAX 400

/* CLAUDE_TIME: id 0, text "<unix seconds> <UTC offset minutes>" (see clock.h), sent by the Mac on connect */
typedef enum { CLAUDE_PERMISSION = 0, CLAUDE_FINISHED = 1, CLAUDE_CANCEL = 2, CLAUDE_TIME = 3 } claude_kind_t;

typedef struct {
    claude_kind_t kind;
    uint32_t id;
    char text[CLAUDE_TEXT_MAX + 1];
} claude_msg_t;

typedef struct {
    uint8_t buf[CLAUDE_TEXT_MAX + 5];
    size_t len;
} claude_rx_t;

/* Feeds one BLE write ([flags][payload...]). Returns true and fills *out when the last chunk arrives. */
bool claude_rx_feed(claude_rx_t *rx, const uint8_t *chunk, size_t len, claude_msg_t *out);
void claude_encode_answer(uint32_t id, uint8_t decision, uint8_t out[5]);
