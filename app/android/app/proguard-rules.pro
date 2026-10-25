# R8 rules for the release app.

# ML Kit finds its components by reflection on the registrars' no-argument constructors; R8 full mode
# strips them, RemoteModelManager.getInstance() then returns null and the engine cannot even be built
# (seen on the Note 9 with a release build: NoSuchMethodException ...Registrar.<init>, NPE in MlKitTranslator)
-keep class * implements com.google.firebase.components.ComponentRegistrar { public <init>(); }

# whisper_jni.cpp binds to these by name: the native methods, and the WhisperSegment class and its
# (String, float, float) constructor, which only native code calls (R8 removed it: NoSuchMethodError, abort)
-keep class vn.cicca.livetranslator.engine.WhisperNative { native <methods>; }
-keep class vn.cicca.livetranslator.engine.WhisperSegment { <init>(java.lang.String, float, float); }
