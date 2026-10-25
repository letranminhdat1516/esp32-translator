#include "font_store.h"

#include <string.h>

#include "board_info.h"

#ifndef FONT_STORE_SIM
#include "esp_heap_caps.h"
#include "esp_system.h"
#include "esp_log.h"
#include "esp_partition.h"
#include "esp_timer.h"
#endif

#if !LV_USE_FS_MEMFS
#error "font_store.c needs LV_USE_FS_MEMFS (sdkconfig.defaults sets it): delete firmware/sdkconfig and rebuild"
#endif

LV_FONT_DECLARE(font_vi_22);
LV_FONT_DECLARE(font_vi_36);

#define N_SCRIPTS 3
#define N_SIZES   2

/* Fallback order: a code point is looked up in the Latin font, then these */
static const uint32_t k_script_set[N_SCRIPTS] = { FONTSET_CJK, FONTSET_HANGUL, FONTSET_THAI };

static lv_font_t *s_script_font[N_SCRIPTS][N_SIZES];
static lv_font_t s_ui_font[N_SIZES];   /* RAM copies of font_vi_22 / 36 with .fallback set */
static bool s_ui_ready;

static int script_index(uint32_t set)
{
    for (int i = 0; i < N_SCRIPTS; i++) {
        if (k_script_set[i] == set) {
            return i;
        }
    }
    return -1;
}

static int size_index(int px)
{
    return px == 22 ? 0 : (px == 36 ? 1 : -1);
}

/* Chains the loaded script fonts of one size behind a copy of the Latin font */
static void relink(int si)
{
    const lv_font_t *latin = si == 0 ? &font_vi_22 : &font_vi_36;
    s_ui_font[si] = *latin;
    const lv_font_t **link = &s_ui_font[si].fallback;
    *link = NULL;
    for (int k = 0; k < N_SCRIPTS; k++) {
        lv_font_t *f = s_script_font[k][si];
        if (f) {
            *link = f;
            link = &f->fallback;
            *link = NULL;
        }
    }
    s_ui_ready = true;
}

bool font_store_add_buffer(uint32_t set, int px, const void *buf, uint32_t size)
{
    int k = script_index(set), si = size_index(px);
    if (k < 0 || si < 0 || buf == NULL || s_script_font[k][si] != NULL) {
        return false;
    }
    lv_binfont_dsc_t dsc = {
        .buffer = buf,
        .buffer_size = size,
        .dynamic_glyph_load = true,
    };
    lv_font_t *f = lv_binfont_create_ex(&dsc);
    if (f == NULL) {
        return false;
    }
    s_script_font[k][si] = f;
    relink(si);
    return true;
}

uint32_t font_store_sets(void)
{
    uint32_t sets = 0;
    for (int k = 0; k < N_SCRIPTS; k++) {
        if (s_script_font[k][0] && s_script_font[k][1]) {
            sets |= k_script_set[k];
        }
    }
    return sets;
}

const lv_font_t *font_store_font(int px)
{
    int si = size_index(px);
    if (si < 0) {
        return &font_vi_22;
    }
    if (!s_ui_ready) {
        return si == 0 ? &font_vi_22 : &font_vi_36;
    }
    return &s_ui_font[si];
}

#ifndef FONT_STORE_SIM

static const char TAG[] = "font_store";

typedef struct {
    uint32_t set, px, offset, size;
} entry_t;

void font_store_init(void)
{
    const esp_partition_t *part =
        esp_partition_find_first(ESP_PARTITION_TYPE_DATA, ESP_PARTITION_SUBTYPE_ANY, "fonts");
    if (part == NULL) {
        ESP_LOGW(TAG, "no fonts partition: Latin only");
        return;
    }
    const void *map = NULL;
    esp_partition_mmap_handle_t handle;
    if (esp_partition_mmap(part, 0, part->size, ESP_PARTITION_MMAP_DATA, &map, &handle) != ESP_OK) {
        ESP_LOGW(TAG, "cannot map the fonts partition: Latin only");
        return;
    }
    const uint8_t *base = map;
    uint32_t count;
    if (memcmp(base, "FNT1", 4) != 0) {
        ESP_LOGW(TAG, "fonts partition is empty or not a font image: Latin only");
        return;
    }
    memcpy(&count, base + 4, 4);
    if (count == 0 || count > 16) {
        ESP_LOGW(TAG, "fonts partition: bad count %lu", (unsigned long)count);
        return;
    }
    int64_t t0 = esp_timer_get_time();
    for (uint32_t i = 0; i < count; i++) {
        entry_t e;
        memcpy(&e, base + 8 + 16 * i, sizeof(e));
        if ((uint64_t)e.offset + e.size > part->size) {
            ESP_LOGW(TAG, "font %lu: outside the partition", (unsigned long)i);
            continue;
        }
        if (!font_store_add_buffer(e.set, (int)e.px, base + e.offset, e.size)) {
            ESP_LOGW(TAG, "font set 0x%lx %lu px did not load", (unsigned long)e.set, (unsigned long)e.px);
        }
    }
    ESP_LOGI(TAG, "loaded font sets 0x%lx in %lld ms, free heap %u (PSRAM %u)", (unsigned long)font_store_sets(),
             (long long)((esp_timer_get_time() - t0) / 1000), (unsigned)esp_get_free_heap_size(),
             (unsigned)heap_caps_get_free_size(MALLOC_CAP_SPIRAM));
}

#endif /* !FONT_STORE_SIM */
