import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// The release signing key, read from `android/key.properties`, which is
// git-ignored and must stay that way.
//
// Android refuses to install an update signed with a different key than the
// installed copy, so this file is not a build detail: it is the only thing that
// lets a reader who downloaded 200 MB ever receive a second version. Losing the
// keystore means every existing install is stranded permanently — no
// re-signing, no recovery, only uninstall and reinstall by hand.
//
// See `key.properties.example` for the four values, and back the keystore up
// somewhere that is not this machine.
val keystoreProperties = Properties().apply {
    val file = rootProject.file("key.properties")
    if (file.exists()) file.inputStream().use { load(it) }
}

android {
    namespace = "site.spencersmith.council"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "site.spencersmith.council"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // The Hexagon DSP skeletons are not shipped.
    //
    // `flutter_gemma_litertlm` bundles four of them, one per Snapdragon
    // generation (V73/V75/V79/V81), and they are 42.4 MB of a 125 MB arm64
    // payload — a third of the native code in the app, carried by every Pixel
    // and Exynos device on earth to be used by none of them. They exist to run
    // the downloadable model on a Qualcomm NPU; without them LiteRT falls back
    // to GPU and CPU, which is what every non-Snapdragon device does anyway.
    //
    // They are also four of the five libraries in the app that are not 16 KB
    // aligned, and being prebuilt they cannot be fixed here — only dropped.
    //
    // The rest of the QNN set stays. The stubs and `libQnnSystem` are aligned,
    // they are 8 MB rather than 42, and on devices whose vendor ships its own
    // skeletons under /vendor they are the half that still works.
    packaging {
        jniLibs {
            excludes += setOf("**/libQnnHtpV*Skel.so")
        }
    }

    signingConfigs {
        if (!keystoreProperties.isEmpty) {
            create("release") {
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            // Null when there is no key, rather than a failure here. Gradle
            // configures every build type on every build, so throwing at this
            // point failed `flutter run` and every debug build on any machine
            // without the keystore — a fresh clone, or CI. The build is still
            // not allowed to *finish* unsigned; that is enforced below, where
            // it is known whether a release is actually being built.
            signingConfig = signingConfigs.findByName("release")
        }
    }
}

// No release without the real key — and no falling back to the debug one.
//
// The fallback is what shipped the published pre-release, and a debug-signed
// APK cannot be updated over: Android refuses an update signed with a different
// key, so the mistake is invisible at build time and permanent by the time
// anyone notices. Checked against the task graph rather than at configuration,
// so it speaks up when a release is genuinely being built and stays silent for
// everything else.
gradle.taskGraph.whenReady {
    val releasing = allTasks.any { it.name.contains("Release", ignoreCase = true) }
    if (releasing && keystoreProperties.isEmpty) {
        throw GradleException(
            "No release signing key. Copy android/key.properties.example to " +
                "android/key.properties and fill in the keystore this app is " +
                "published with — see the file for how to create one. Never " +
                "sign a published build with the debug key."
        )
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
