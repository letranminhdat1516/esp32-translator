/*
 * Board simulator: the real translator and lock screens (firmware/main/ui.c, lock_ui.c, modes.c) in a round
 * 466x466 window on the Mac. Everything else on the board (BLE, audio, PMU, Claude screens) is faked here.
 *
 *   board-sim                         window; the mouse is the finger, keys below drive the fake iPhone
 *   board-sim --do "a;b;..."          runs the commands first, then stays interactive
 *   board-sim --headless --do "..."   no window: run the commands (use shot:<file.bmp>) and exit
 *
 * Commands (also what the keys do):
 *   connect / disconnect     iPhone app link up / down                     C
 *   mic:on / mic:off         board mic streaming                           M (toggle)
 *   text:<utf8>              subtitle from the app ("\n" breaks a line)    T (next sample)
 *   status:<utf8>            status line
 *   toast:<utf8>             status line for 2 s
 *   level:<0..100>           level ring (0 hides it)                       V (fake voice on/off)
 *   lock / unlock / face     PWR x1 / PWR x2 / tap on the lock screen      K / U / F
 *   sleep                    the deep-sleep message
 *   wait:<ms>                keep rendering
 *   shot:<file.bmp>          save what the screen shows (round, outside the glass dark grey)   P
 *   tap:<x>,<y> / dtap:<x>,<y>                 a finger tap / double tap at that point
 *   drag:<x1>,<y1>,<x2>,<y2>                   press, move in steps, release (e.g. the swipe up)
 */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include <SDL2/SDL.h>

#include "app.h"
#include "bsp/esp-bsp.h"
#include "clock.h"
#include "esp_timer.h"
#include "lvgl.h"
#include "modes.h"

#define SIZE 466
#define BEZEL 0x202226

static modes_t s_modes;
static rec_lang_t s_rec = REC_NONE;
static bool s_connected;
static int s_brightness = 100;
static lv_obj_t *s_dark;
static bool s_voice;
static int s_sample;
static int s_shots;
/* Scripted finger (tap / dtap / drag), next to the SDL mouse */
static lv_point_t s_finger;
static bool s_finger_down;

static const char *SAMPLES[] = {
    "Hello! Where is the nearest train station?",
    "Could you say that again more slowly, please?",
    "Mr. Nguyễn Văn Đạt ordered phở bò and two bánh mì.",
    "We open at nine tomorrow morning. If you want a table by the window, please book before eight tonight, "
    "because it fills up fast on weekends.",
    "",
};

/* ---- time ---- */

static int64_t now_us(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000000 + ts.tv_nsec / 1000;
}

int64_t esp_timer_get_time(void)
{
    return now_us();
}

static uint32_t tick_ms(void)
{
    return (uint32_t)(now_us() / 1000);
}

static void pump(uint32_t ms)
{
    int64_t end = now_us() + (int64_t)ms * 1000;
    do {
        lv_timer_handler();
        usleep(5000);
    } while (now_us() < end);
}

void vTaskDelay(uint32_t ms)
{
    pump(ms);
}

/* ---- the rest of the board, faked ---- */

void bsp_display_brightness_set(int percent)
{
    s_brightness = percent;
    if (s_dark) {
        lv_obj_set_hidden(s_dark, percent > 0);
    }
}

bool clock_now_hhmm(char out[6])
{
    time_t t = time(NULL);
    struct tm tm;
    localtime_r(&t, &tm);
    snprintf(out, 6, "%02d:%02d", tm.tm_hour, tm.tm_min);
    return true;
}

bool pmu_battery(pmu_battery_t *out)
{
    *out = (pmu_battery_t){.present = true, .usb_power = false, .charging = false, .percent = 76};
    return true;
}

void claude_ui_set_touch_enabled(bool on) { (void)on; }
void phone_ui_set_touch_enabled(bool on) { (void)on; }
bool claude_ui_pending(void) { return false; }
bool voice_ui_active_locked(void) { return false; }

static void apply_screen(void)
{
    lv_obj_t *want = modes_screen(&s_modes) == SCREEN_LOCK ? lock_ui_screen() : ui_translator_screen();
    if (lv_screen_active() != want) {
        lv_screen_load(want);
    }
}

bool shell_post(modes_event_t ev)
{
    if (modes_handle(&s_modes, ev, now_us())) {
        ui_force_screen_on();
    }
    apply_screen();
    return true;
}

void shell_snapshot(modes_t *out)
{
    *out = s_modes;
}

rec_lang_t app_get_recording(void)
{
    return s_rec;
}

void app_request_recording(rec_lang_t lang)
{
    if (lang != REC_NONE && !s_connected) {
        ui_show_status("iPhone not connected");   /* main.c, when no iPhone link can be woken */
        return;
    }
    s_rec = lang;
    ui_set_recording(lang);
    printf("board mic %s\n", lang == REC_NONE ? "off" : "on");
}

/* ---- screenshots ---- */

static void put32(FILE *f, uint32_t v)
{
    fputc(v & 0xff, f), fputc((v >> 8) & 0xff, f), fputc((v >> 16) & 0xff, f), fputc(v >> 24, f);
}

static void shot(const char *path)
{
    lv_draw_buf_t *buf = lv_snapshot_take(lv_screen_active(), LV_COLOR_FORMAT_ARGB8888);
    FILE *f = buf ? fopen(path, "wb") : NULL;
    if (!f) {
        fprintf(stderr, "shot: cannot write %s\n", path);
        if (buf) {
            lv_draw_buf_destroy(buf);
        }
        return;
    }
    int w = buf->header.w, h = buf->header.h, row = (w * 3 + 3) & ~3;   /* BMP rows pad to 4 bytes */
    fputs("BM", f);
    put32(f, 54 + row * h), put32(f, 0), put32(f, 54);
    put32(f, 40), put32(f, w), put32(f, h);
    put32(f, 1 | (24 << 16)), put32(f, 0), put32(f, row * h), put32(f, 2835), put32(f, 2835), put32(f, 0), put32(f, 0);
    float c = (w - 1) / 2.0f, r = w / 2.0f;
    for (int y = h - 1; y >= 0; y--) {
        const uint8_t *src = buf->data + y * buf->header.stride;
        for (int x = 0; x < w; x++) {
            const uint8_t *p = src + x * 4;   /* B G R A */
            bool glass = hypotf(x - c, y - c) <= r;
            uint8_t b = p[0], g = p[1], rr = p[2];
            if (!glass) {
                b = BEZEL & 0xff, g = (BEZEL >> 8) & 0xff, rr = BEZEL >> 16;
            } else if (s_brightness == 0) {
                b = g = rr = 0;
            }
            fputc(b, f), fputc(g, f), fputc(rr, f);
        }
        for (int pad = w * 3; pad < row; pad++) {
            fputc(0, f);
        }
    }
    fclose(f);
    lv_draw_buf_destroy(buf);
    printf("shot %s\n", path);
}

/* ---- scripted finger ---- */

static void finger_read(lv_indev_t *indev, lv_indev_data_t *data)
{
    data->point = s_finger;
    data->state = s_finger_down ? LV_INDEV_STATE_PRESSED : LV_INDEV_STATE_RELEASED;
}

static void finger(int x, int y, bool down, uint32_t hold_ms)
{
    s_finger = (lv_point_t){x, y};
    s_finger_down = down;
    pump(hold_ms);
}

static void tap(int x, int y)
{
    finger(x, y, true, 60);
    finger(x, y, false, 60);
}

/* ---- commands ---- */

static void unescape(char *s)
{
    char *o = s;
    for (; *s; s++) {
        if (s[0] == '\\' && s[1] == 'n') {
            *o++ = '\n', s++;
        } else {
            *o++ = *s;
        }
    }
    *o = '\0';
}

static void run(char *cmd)
{
    char *arg = strchr(cmd, ':');
    if (arg) {
        *arg++ = '\0';
        unescape(arg);
    }
    if (!strcmp(cmd, "connect") || !strcmp(cmd, "disconnect")) {
        s_connected = !strcmp(cmd, "connect");
        ui_set_connected(s_connected);
        if (!s_connected && s_rec != REC_NONE) {
            app_request_recording(REC_NONE);
        }
        ui_mark_activity();
    } else if (!strcmp(cmd, "mic") && arg) {
        app_request_recording(!strcmp(arg, "on") ? REC_EN : REC_NONE);
        ui_mark_activity();
    } else if (!strcmp(cmd, "text") && arg) {
        ui_show_text(arg);
    } else if (!strcmp(cmd, "status") && arg) {
        ui_show_status(arg);
    } else if (!strcmp(cmd, "toast") && arg) {
        ui_toast(arg, 2000);
    } else if (!strcmp(cmd, "level") && arg) {
        ui_set_level(atoi(arg));
    } else if (!strcmp(cmd, "lock")) {
        shell_post(MODES_EV_PWR_1);
    } else if (!strcmp(cmd, "unlock")) {
        shell_post(MODES_EV_PWR_2);
    } else if (!strcmp(cmd, "face")) {
        shell_post(MODES_EV_TAP_1);
    } else if (!strcmp(cmd, "tap") && arg) {
        int x, y;
        if (sscanf(arg, "%d,%d", &x, &y) == 2) {
            tap(x, y);
        }
    } else if (!strcmp(cmd, "dtap") && arg) {
        int x, y;
        if (sscanf(arg, "%d,%d", &x, &y) == 2) {
            tap(x, y);
            tap(x, y);
        }
    } else if (!strcmp(cmd, "drag") && arg) {
        int x1, y1, x2, y2;
        if (sscanf(arg, "%d,%d,%d,%d", &x1, &y1, &x2, &y2) == 4) {
            for (int i = 0; i <= 10; i++) {
                finger(x1 + (x2 - x1) * i / 10, y1 + (y2 - y1) * i / 10, true, 30);
            }
            finger(x2, y2, false, 60);
        }
    } else if (!strcmp(cmd, "sleep")) {
        ui_prepare_sleep();
    } else if (!strcmp(cmd, "wait") && arg) {
        pump((uint32_t)atoi(arg));
        return;
    } else if (!strcmp(cmd, "shot") && arg) {
        pump(50);
        shot(arg);
        return;
    } else {
        fprintf(stderr, "unknown command: %s\n", cmd);
        return;
    }
    pump(300);   /* the 250 ms screen timer applies lock face / panel changes */
}

static void run_script(const char *script)
{
    char *copy = strdup(script);
    for (char *save = NULL, *c = strtok_r(copy, ";", &save); c; c = strtok_r(NULL, ";", &save)) {
        while (*c == ' ') {
            c++;
        }
        if (*c) {
            run(c);
        }
    }
    free(copy);
}

/* ---- keys and the fake voice ---- */

static void voice_cb(lv_timer_t *t)
{
    if (!s_voice) {
        return;
    }
    /* Syllables: a fast wobble inside a slow swell, with short pauses */
    double s = now_us() / 1e6;
    double swell = 0.5 + 0.5 * sin(s * 1.3);
    double syll = fabs(sin(s * 9.0));
    int level = (int)(8 + 92 * swell * syll);
    ui_set_level(fmod(s, 3.0) > 2.6 ? 0 : level);
}

static void keys_cb(lv_timer_t *t)
{
    static uint8_t was[SDL_NUM_SCANCODES];
    int n;
    const uint8_t *k = SDL_GetKeyboardState(&n);
    for (int i = 0; i < n && i < SDL_NUM_SCANCODES; i++) {
        bool down = k[i] && !was[i];
        was[i] = k[i];
        if (!down) {
            continue;
        }
        char cmd[320];
        switch (i) {
        case SDL_SCANCODE_C: run(s_connected ? "disconnect" : "connect"); break;
        case SDL_SCANCODE_M: run(s_rec == REC_NONE ? strcpy(cmd, "mic:on") : strcpy(cmd, "mic:off")); break;
        case SDL_SCANCODE_T:
            snprintf(cmd, sizeof(cmd), "text:%s", SAMPLES[s_sample++ % (sizeof(SAMPLES) / sizeof(*SAMPLES))]);
            run(cmd);
            break;
        case SDL_SCANCODE_V:
            s_voice = !s_voice;
            if (!s_voice) {
                ui_set_level(0);
            }
            printf("fake voice %s\n", s_voice ? "on" : "off");
            break;
        case SDL_SCANCODE_K: run(strcpy(cmd, "lock")); break;
        case SDL_SCANCODE_U: run(strcpy(cmd, "unlock")); break;
        case SDL_SCANCODE_F: run(strcpy(cmd, "face")); break;
        case SDL_SCANCODE_P:
            snprintf(cmd, sizeof(cmd), "shot:board-%d.bmp", ++s_shots);
            run(cmd);
            break;
        default: break;
        }
    }
}

/* ---- main ---- */

static void dummy_flush(lv_display_t *d, const lv_area_t *a, uint8_t *px)
{
    lv_display_flush_ready(d);
}

int main(int argc, char **argv)
{
    bool headless = false;
    const char *script = NULL;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--headless")) {
            headless = true;
        } else if (!strcmp(argv[i], "--do") && i + 1 < argc) {
            script = argv[++i];
        } else {
            fprintf(stderr, "usage: %s [--headless] [--do \"cmd;cmd;...\"]\n", argv[0]);
            return 2;
        }
    }

    lv_init();
    lv_tick_set_cb(tick_ms);
    if (headless) {
        static uint8_t buf[SIZE * 40 * 2];
        lv_display_t *d = lv_display_create(SIZE, SIZE);
        lv_display_set_buffers(d, buf, NULL, sizeof(buf), LV_DISPLAY_RENDER_MODE_PARTIAL);
        lv_display_set_flush_cb(d, dummy_flush);
    } else {
        lv_display_t *d = lv_sdl_window_create(SIZE, SIZE);
        lv_sdl_window_set_title(d, "Live Translator board");
        lv_sdl_mouse_create();

        /* The round glass: everything outside it is the bezel */
        lv_obj_t *bezel = lv_obj_create(lv_layer_sys());
        lv_obj_remove_style_all(bezel);
        lv_obj_set_size(bezel, SIZE + 300, SIZE + 300);
        lv_obj_center(bezel);
        lv_obj_set_style_radius(bezel, LV_RADIUS_CIRCLE, 0);
        lv_obj_set_style_border_width(bezel, 150, 0);
        lv_obj_set_style_border_color(bezel, lv_color_hex(BEZEL), 0);
        lv_obj_set_clickable(bezel, false);
    }
    lv_indev_t *f = lv_indev_create();
    lv_indev_set_type(f, LV_INDEV_TYPE_POINTER);
    lv_indev_set_read_cb(f, finger_read);

    /* The dark AMOLED (brightness 0): taps still reach the screen below */
    s_dark = lv_obj_create(lv_layer_top());
    lv_obj_remove_style_all(s_dark);
    lv_obj_set_size(s_dark, lv_pct(100), lv_pct(100));
    lv_obj_set_style_bg_color(s_dark, lv_color_black(), 0);
    lv_obj_set_style_bg_opa(s_dark, LV_OPA_COVER, 0);
    lv_obj_set_clickable(s_dark, false);
    lv_obj_set_hidden(s_dark, true);

    modes_init(&s_modes);
    ui_init();
    lock_ui_init();
    apply_screen();
    pump(100);

    if (script) {
        run_script(script);
    }
    if (headless) {
        return 0;
    }
    puts("Board simulator. Mouse = finger (double-click = double tap, drag up on the lock face = swipe).\n"
         "  C connect/disconnect iPhone   M board mic   T next subtitle   V fake voice (level ring)\n"
         "  K lock (PWR x1)   U unlock (PWR x2)   F tap on the lock screen   P screenshot (board-N.bmp)\n"
         "The panel goes dark after 30 s without activity, like the board: click to wake.");
    lv_timer_create(keys_cb, 30, NULL);
    lv_timer_create(voice_cb, 60, NULL);
    for (;;) {
        uint32_t idle = lv_timer_handler();
        usleep((idle > 10 ? 10 : idle) * 1000);
    }
}
