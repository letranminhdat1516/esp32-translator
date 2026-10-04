idf_component_register(SRCS "main.c" "ble_link.c" "claude_proto.c" "audio_in.c" "adpcm.c" "ui.c" "claude_ui.c" "chime.c" "pmu.c" "font_vi_22.c" "font_vi_36.c"
                       INCLUDE_DIRS "."
                       PRIV_REQUIRES bt nvs_flash)
