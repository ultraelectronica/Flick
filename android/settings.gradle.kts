pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "8.11.1" apply false
    id("org.jetbrains.kotlin.android") version "2.2.20" apply false
}

include(":app")

// Fix for libraries that don't have namespace specified (like Isar)
gradle.projectsLoaded {
    rootProject.allprojects {
        if (this != rootProject && file("build.gradle").exists()) {
            val buildGradleFile = file("build.gradle")
            val content = buildGradleFile.readText()
            if (content.contains("com.android.library") && !content.contains("namespace")) {
                // Add namespace if missing
                val packageName = name.replace("-", "_").replace(".", "_")
                val namespace = "com.flutter.plugins.$packageName"
                val patched = content.replace(
                    "android {",
                    "android {\n    namespace '$namespace'"
                )
                buildGradleFile.writeText(patched)
            }
        }
    }
}
