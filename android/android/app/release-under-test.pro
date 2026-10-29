# Added to the release app ONLY for an instrumented run against it (-PtestBuildType=release):
# libraries the test runner expects the app under test to provide. The engine's own classes get no extra
# rules here, so the run sees them exactly as R8 leaves them in a real release build.
-keep class androidx.tracing.** { *; }
-keep class androidx.test.** { *; }
-keep class kotlin.** { *; }
-keep class kotlinx.** { *; }
# The engine surface ReleaseWhisperTest drives (it implements EngineEventSink, so the interface must not be
# merged away). Nothing behind it is kept here: WhisperNative/WhisperSegment get only the app's own rules.
-keep interface vn.cicca.livetranslator.engine.EngineEventSink { *; }
-keep class vn.cicca.livetranslator.engine.NativeVoiceEngine { public *; }
-keep class vn.cicca.livetranslator.engine.PairMsg { *; }
-keep class vn.cicca.livetranslator.engine.TheirsMsg { *; }
-keep class vn.cicca.livetranslator.engine.EngineErrorsKt { *; }
