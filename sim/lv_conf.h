/* LVGL config for the desktop simulator: only what differs from LVGL's defaults (lv_conf_internal.h fills the rest).
 * Matches the board where it matters for the look: 16-bit colour, software rendering. */
#ifndef LV_CONF_H
#define LV_CONF_H

#define LV_COLOR_FORMAT_DEFAULT LV_COLOR_FORMAT_RGB565
#define LV_MEM_SIZE (1024 * 1024)
#define LV_USE_OS LV_OS_NONE
#define LV_USE_SNAPSHOT 1
#define LV_FONT_MONTSERRAT_14 1

#define LV_USE_SDL 1
#define LV_SDL_INCLUDE_PATH "SDL2/SDL.h"
#define LV_SDL_RENDER_MODE LV_DISPLAY_RENDER_MODE_DIRECT
#define LV_SDL_BUF_COUNT 1
#define LV_SDL_FULLSCREEN 0
#define LV_SDL_DIRECT_EXIT 1

#endif
