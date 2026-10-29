# The app's native build: React Native's libappmodules (autolinked libraries and the VoiceEngine codegen
# JNI glue, the same as RN's default-app-setup) plus whisper.cpp's JNI library from ../cpp (arm64 only).
cmake_minimum_required(VERSION 3.22.1)

project(appmodules)

include(${REACT_ANDROID_DIR}/cmake-utils/ReactNative-application.cmake)

# whisper.cpp for arm64 phones only; other ABIs run without Whisper (WhisperNative.loaded is false there)
if(ANDROID_ABI STREQUAL "arm64-v8a")
    add_subdirectory(${CMAKE_CURRENT_SOURCE_DIR}/../cpp whisper_jni)
endif()
