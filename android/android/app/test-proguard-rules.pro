# R8 rules for the instrumented test APK when the tests run against the release build
# (-PtestBuildType=release). They apply to the test APK only, never to the app.

# Compile-only annotations of androidx.test
-dontwarn com.google.errorprone.annotations.**
-dontwarn javax.lang.model.element.Modifier

# The test code itself stays whole (the runner finds tests by name; fakes are anonymous classes)
-dontobfuscate
-keep class vn.cicca.livetranslator.** { *; }
