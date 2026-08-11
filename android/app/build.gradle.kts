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
            // Fails the build rather than falling back to the debug key. The
            // fallback is what shipped the published pre-release, and a
            // debug-signed APK cannot be updated over: the mistake is invisible
            // at build time and permanent by the time anyone notices.
            signingConfig = signingConfigs.findByName("release")
                ?: throw GradleException(
                    "No release signing key. Copy android/key.properties.example " +
                        "to android/key.properties and fill in the keystore this " +
                        "app is published with — see the file for how to create " +
                        "one. Never sign a published build with the debug key."
                )
        }
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
