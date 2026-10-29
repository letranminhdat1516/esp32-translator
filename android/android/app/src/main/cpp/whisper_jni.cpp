// JNI bridge to whisper.cpp for vn.cicca.livetranslator.engine.WhisperNative.
// One whisper_context per loaded model; transcribe() runs whisper_full on one utterance and returns its
// segments (text + no_speech_prob). Calls on one context must not overlap (the Kotlin side serializes them).

#include <jni.h>
#include <android/log.h>

#include <string>
#include <vector>

#include "whisper.h"

#define TAG "whisper_jni"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN, TAG, __VA_ARGS__)

namespace {

std::string to_string(JNIEnv *env, jstring s) {
    if (s == nullptr) return {};
    const char *chars = env->GetStringUTFChars(s, nullptr);
    std::string out(chars);
    env->ReleaseStringUTFChars(s, chars);
    return out;
}

// Whisper emits UTF-8, but a segment may end inside a multi-byte character; NewStringUTF needs valid
// (modified) UTF-8, so build the Java string from bytes through String(byte[], "UTF-8").
jstring utf8_string(JNIEnv *env, const char *text) {
    const jsize n = static_cast<jsize>(strlen(text));
    jbyteArray bytes = env->NewByteArray(n);
    env->SetByteArrayRegion(bytes, 0, n, reinterpret_cast<const jbyte *>(text));
    jclass string_class = env->FindClass("java/lang/String");
    jmethodID ctor = env->GetMethodID(string_class, "<init>", "([BLjava/lang/String;)V");
    jstring charset = env->NewStringUTF("UTF-8");
    auto out = static_cast<jstring>(env->NewObject(string_class, ctor, bytes, charset));
    env->DeleteLocalRef(bytes);
    env->DeleteLocalRef(charset);
    env->DeleteLocalRef(string_class);
    return out;
}

}  // namespace

extern "C" {

JNIEXPORT jlong JNICALL
Java_vn_cicca_livetranslator_engine_WhisperNative_init(JNIEnv *env, jobject, jstring model_path) {
    const std::string path = to_string(env, model_path);
    whisper_context_params params = whisper_context_default_params();
    params.use_gpu = false;
    whisper_context *ctx = whisper_init_from_file_with_params(path.c_str(), params);
    if (ctx == nullptr) LOGW("could not load %s", path.c_str());
    return reinterpret_cast<jlong>(ctx);
}

JNIEXPORT void JNICALL
Java_vn_cicca_livetranslator_engine_WhisperNative_free(JNIEnv *, jobject, jlong handle) {
    auto *ctx = reinterpret_cast<whisper_context *>(handle);
    if (ctx != nullptr) whisper_free(ctx);
}

// True when the Java side this file builds is present (R8 may strip what only native code uses).
// A lookup failure leaves a pending exception that would abort the next JNI call: clear it.
JNIEXPORT jboolean JNICALL
Java_vn_cicca_livetranslator_engine_WhisperNative_bindingsOk(JNIEnv *env, jobject) {
    jclass segment_class = env->FindClass("vn/cicca/livetranslator/engine/WhisperSegment");
    if (segment_class == nullptr) {
        env->ExceptionClear();
        LOGW("WhisperSegment class missing");
        return JNI_FALSE;
    }
    jmethodID ctor = env->GetMethodID(segment_class, "<init>", "(Ljava/lang/String;FF)V");
    env->DeleteLocalRef(segment_class);
    if (ctor == nullptr) {
        env->ExceptionClear();
        LOGW("WhisperSegment(String, float, float) constructor missing");
        return JNI_FALSE;
    }
    return JNI_TRUE;
}

JNIEXPORT jstring JNICALL
Java_vn_cicca_livetranslator_engine_WhisperNative_systemInfo(JNIEnv *env, jobject) {
    return env->NewStringUTF(whisper_print_system_info());
}

// Returns WhisperSegment[] or null when whisper_full fails.
JNIEXPORT jobjectArray JNICALL
Java_vn_cicca_livetranslator_engine_WhisperNative_transcribe(
        JNIEnv *env, jobject, jlong handle, jfloatArray samples, jstring language, jstring prompt,
        jint threads) {
    auto *ctx = reinterpret_cast<whisper_context *>(handle);
    if (ctx == nullptr) return nullptr;

    const jsize n = env->GetArrayLength(samples);
    std::vector<float> pcm(static_cast<size_t>(n));
    env->GetFloatArrayRegion(samples, 0, n, pcm.data());
    const std::string lang = to_string(env, language);
    const std::string initial_prompt = to_string(env, prompt);

    whisper_full_params params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
    params.n_threads = threads;
    params.language = lang.c_str();
    params.translate = false;
    params.no_context = true;        // each utterance stands alone
    params.no_timestamps = true;     // utterances are short; timestamps cost decoding time
    params.single_segment = false;
    params.print_progress = false;
    params.print_realtime = false;
    params.print_special = false;
    params.print_timestamps = false;
    params.suppress_nst = true;      // no "[Music]"-style non-speech tokens
    params.initial_prompt = initial_prompt.empty() ? nullptr : initial_prompt.c_str();

    if (whisper_full(ctx, params, pcm.data(), n) != 0) {
        LOGW("whisper_full failed");
        return nullptr;
    }

    jclass segment_class = env->FindClass("vn/cicca/livetranslator/engine/WhisperSegment");
    jmethodID ctor = segment_class != nullptr
        ? env->GetMethodID(segment_class, "<init>", "(Ljava/lang/String;FF)V") : nullptr;
    if (ctor == nullptr) {
        // Not an abort: clear the lookup's exception and throw one the Kotlin side handles
        env->ExceptionClear();
        if (segment_class != nullptr) env->DeleteLocalRef(segment_class);
        jclass ise = env->FindClass("java/lang/IllegalStateException");
        if (ise == nullptr) {
            // FindClass left its own exception pending (NoClassDefFoundError): let that one reach Kotlin
            LOGW("WhisperSegment binding missing and IllegalStateException not found");
            return nullptr;
        }
        env->ThrowNew(ise, "WhisperSegment(String, float, float) not found (R8 keep rule missing?)");
        env->DeleteLocalRef(ise);
        return nullptr;
    }
    const int count = whisper_full_n_segments(ctx);
    const whisper_token eot = whisper_token_eot(ctx);
    jobjectArray out = env->NewObjectArray(count, segment_class, nullptr);
    for (int i = 0; i < count; ++i) {
        jstring text = utf8_string(env, whisper_full_get_segment_text(ctx, i));
        const float no_speech = whisper_full_get_segment_no_speech_prob(ctx, i);
        // Mean probability of the segment's text tokens (special tokens are >= eot)
        float sum = 0.0f;
        int tokens = 0;
        for (int t = 0; t < whisper_full_n_tokens(ctx, i); ++t) {
            if (whisper_full_get_token_id(ctx, i, t) >= eot) continue;
            sum += whisper_full_get_token_p(ctx, i, t);
            ++tokens;
        }
        const float token_p = tokens > 0 ? sum / tokens : 0.0f;
        jobject segment = env->NewObject(segment_class, ctor, text, no_speech, token_p);
        env->SetObjectArrayElement(out, i, segment);
        env->DeleteLocalRef(segment);
        env->DeleteLocalRef(text);
    }
    env->DeleteLocalRef(segment_class);
    return out;
}

}  // extern "C"
