idf_component_register(SRCS "main.c" "ble_link.c" "audio_in.c" "adpcm.c" "ui.c" "font_vi_20.c" "font_vi_26.c"
                       INCLUDE_DIRS "."
                       PRIV_REQUIRES bt nvs_flash)
