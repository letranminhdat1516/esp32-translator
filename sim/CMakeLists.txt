# Desktop simulator of the board UI: the real firmware/main/ui.c and lock_ui.c on LVGL + SDL2.
#   cmake -S sim -B sim/build && cmake --build sim/build -j && sim/build/board-sim
cmake_minimum_required(VERSION 3.16)
project(board_sim C)

set(CMAKE_C_STANDARD 11)
set(FW ${CMAKE_CURRENT_SOURCE_DIR}/../firmware/main)

# The firmware's own LVGL (idf.py build downloads it); else fetch the same version
set(LVGL_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../firmware/managed_components/lvgl__lvgl CACHE PATH "LVGL source")
if(NOT EXISTS ${LVGL_DIR}/lvgl.h)
    include(FetchContent)
    FetchContent_Declare(lvgl GIT_REPOSITORY https://github.com/lvgl/lvgl.git GIT_TAG v9.6.0 GIT_SHALLOW TRUE)
    FetchContent_Populate(lvgl)
    set(LVGL_DIR ${lvgl_SOURCE_DIR})
endif()

find_package(SDL2 REQUIRED CONFIG)   # brew install sdl2

file(GLOB_RECURSE LVGL_SRC ${LVGL_DIR}/src/*.c)
add_library(lvgl STATIC ${LVGL_SRC})
target_include_directories(lvgl PUBLIC ${LVGL_DIR} ${CMAKE_CURRENT_SOURCE_DIR})
target_link_libraries(lvgl PUBLIC SDL2::SDL2)
target_compile_definitions(lvgl PUBLIC LV_CONF_INCLUDE_SIMPLE LV_LVGL_H_INCLUDE_SIMPLE)
target_compile_options(lvgl PRIVATE -w)

add_executable(board-sim
    sim.c
    ${FW}/ui.c
    ${FW}/lock_ui.c
    ${FW}/modes.c
    ${FW}/logo_img.c
    ${FW}/font_vi_22.c
    ${FW}/font_vi_36.c)
target_include_directories(board-sim PRIVATE stubs ${FW})
target_link_libraries(board-sim PRIVATE lvgl m)
