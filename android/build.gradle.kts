allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
// The onnxruntime plugin pins compileSdkVersion 33, but the AndroidX libraries
// the Flutter engine pulls in now require 34 or later, so the release build
// fails outright. The pin lives in the published package, not in this repo, so
// it cannot be edited — it has to be overridden here.
//
// Raising compileSdk only changes which APIs the plugin compiles against. It
// does not touch minSdk, so no device loses support, and it does not touch
// targetSdk, so no runtime behaviour changes. The alternative is pinning the
// AndroidX versions downward, which would hold back the whole app to
// accommodate one plugin.
//
// This must run before the evaluationDependsOn block below: that one forces
// projects to evaluate, and afterEvaluate cannot be registered on a project
// that has already been evaluated.
subprojects {
    afterEvaluate {
        val android = project.extensions.findByName("android")
            as? com.android.build.gradle.BaseExtension ?: return@afterEvaluate
        val current = android.compileSdkVersion?.removePrefix("android-")?.toIntOrNull()
        if (current != null && current < 34) {
            android.compileSdkVersion(34)
        }
    }
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
