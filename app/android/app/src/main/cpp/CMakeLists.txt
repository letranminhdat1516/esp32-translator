cmake_minimum_required(VERSION 3.22.1)
project(whisper_jni LANGUAGES C CXX)

# whisper.cpp (git submodule, pinned to a release tag) built for the phone's CPU, arm64-v8a only.
# Always optimized: a -O0 debug build of ggml is ~10x slower and would distort the real-time factor.
set(CMAKE_BUILD_TYPE Release)
set(CMAKE_CXX_STANDARD 17)

set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_SERVER OFF CACHE BOOL "" FORCE)
set(WHISPER_SDL2 OFF CACHE BOOL "" FORCE)
set(WHISPER_CURL OFF CACHE BOOL "" FORCE)
# No -march=native when cross-compiling; plain ARMv8.0 NEON: the Note 9's Exynos M3 big cores have no
# FP16 arithmetic or dot product, so armv8.2 code would crash there
set(GGML_NATIVE OFF CACHE BOOL "" FORCE)
set(GGML_CPU_ARM_ARCH "armv8-a" CACHE STRING "" FORCE)
set(GGML_OPENMP OFF CACHE BOOL "" FORCE)
set(GGML_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(GGML_BUILD_TESTS OFF CACHE BOOL "" FORCE)

add_subdirectory(whisper.cpp)

add_library(whisper_jni SHARED whisper_jni.cpp)
target_link_libraries(whisper_jni PRIVATE whisper log)
target_compile_options(whisper_jni PRIVATE -O3 -Wall)
# Drop unused code and keep the exported JNI symbols only
target_link_options(whisper_jni PRIVATE -Wl,--gc-sections -Wl,--exclude-libs,ALL)
