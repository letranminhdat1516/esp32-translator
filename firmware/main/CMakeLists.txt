idf_component_register(SRCS "main.c" "ble_link.c" "claude_proto.c" "sessions.c" "question.c" "audio_in.c" "adpcm.c" "ui.c" "claude_ui.c" "question_ui.c" "chime.c" "pmu.c" "modes.c" "clock.c" "clock_rtc.c" "logo_img.c" "shell.c" "lock_ui.c" "picker_ui.c" "font_vi_22.c" "font_vi_36.c"
                       INCLUDE_DIRS "."
                       PRIV_REQUIRES bt nvs_flash)
