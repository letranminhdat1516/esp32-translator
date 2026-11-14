idf_component_register(SRCS "main.c" "glyphs.c" "ble_link.c" "audio_in.c" "adpcm.c" "ui.c" "pmu.c" "modes.c" "clock.c" "clock_rtc.c" "logo_img.c" "shell.c" "lock_ui.c" "pair_ui.c" "font_vi_22.c" "font_vi_36.c" "font_store.c"
                       INCLUDE_DIRS "."
                       PRIV_REQUIRES bt nvs_flash esp_partition)
