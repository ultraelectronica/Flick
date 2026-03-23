plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

import java.io.File
import java.util.Properties

android {
    namespace = "com.ultraelectronica.flick"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"  // fixed deprecation: plain string, not JavaVersion.toString()
    }

    defaultConfig {
        applicationId = "com.ultraelectronica.flick"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        ndk {
            abiFilters += listOf("arm64-v8a", "armeabi-v7a", "x86_64", "x86")
        }

        externalNativeBuild {
            cmake {
                arguments += "-DANDROID_STL=c++_shared"
            }
        }
    }

    packaging {  // fixed deprecation: renamed from packagingOptions
        jniLibs {
            useLegacyPackaging = true
            // Keep libc++_shared.so for Rust library
            pickFirsts += listOf("**/libc++_shared.so")
        }
    }

    sourceSets {
        getByName("main") {
            jniLibs.srcDirs("src/main/jniLibs")
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}

// Copy libc++_shared.so from NDK before building
tasks.register("copyNdkLibs") {
    description = "Copy libc++_shared.so from Android NDK to jniLibs"
    doLast {
        fun ndkHomeFromLocalProperties(): String? {
            val propsFile = rootProject.file("local.properties")
            if (!propsFile.exists()) return null

            val props = Properties()
            propsFile.inputStream().use { props.load(it) }

            val explicitNdk = props.getProperty("ndk.dir")
            if (!explicitNdk.isNullOrBlank()) {
                return explicitNdk
            }

            val sdkDir = props.getProperty("sdk.dir") ?: return null
            val ndkRoot = File(sdkDir, "ndk")
            if (!ndkRoot.exists()) return null

            return ndkRoot.listFiles()
                ?.filter { it.isDirectory }
                ?.maxByOrNull { it.name }
                ?.absolutePath
        }

        val ndkHome =
            System.getenv("ANDROID_NDK_HOME")
                ?: System.getenv("ANDROID_NDK_ROOT")
                ?: ndkHomeFromLocalProperties()
                ?: throw GradleException(
                    "ANDROID_NDK_HOME/ANDROID_NDK_ROOT is not set and no NDK could be resolved from local.properties",
                )

        val abiToArch = mapOf(
            "arm64-v8a" to "aarch64-linux-android",
            "armeabi-v7a" to "arm-linux-androideabi",
            "x86_64" to "x86_64-linux-android",
            "x86" to "i686-linux-android",
        )

        val jniLibsDir = project.file("src/main/jniLibs")
        val prebuiltRoots = listOf(
            "toolchains/llvm/prebuilt/windows-x86_64",
            "toolchains/llvm/prebuilt/linux-x86_64",
            "toolchains/llvm/prebuilt/darwin-x86_64",
            "toolchains/llvm/prebuilt/darwin-arm64",
        )

        abiToArch.forEach { (abi, arch) ->
            val abiOutDir = File(jniLibsDir, abi)
            abiOutDir.mkdirs()

            val candidates = mutableListOf<File>()

            prebuiltRoots.forEach { root ->
                candidates += File(ndkHome, "$root/sysroot/usr/lib/$arch/libc++_shared.so")
                candidates += File(ndkHome, "$root/sysroot/usr/lib/$abi/libc++_shared.so")
            }

            // Legacy location (older NDKs)
            candidates += File(ndkHome, "sources/cxx-stl/llvm-libc++/libs/$abi/libc++_shared.so")

            val sourceLib = candidates.firstOrNull { it.exists() }
            if (sourceLib != null) {
                sourceLib.copyTo(File(abiOutDir, "libc++_shared.so"), overwrite = true)
                logger.lifecycle("Copied libc++_shared.so for $abi from ${sourceLib.absolutePath}")
            } else {
                logger.warn("Warning: libc++_shared.so not found for $abi in NDK $ndkHome")
            }
        }
    }
}

// Make preBuild depend on copyNdkLibs
tasks.named("preBuild") {
    dependsOn("copyNdkLibs")
}

dependencies {
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.documentfile:documentfile:1.1.0")
    implementation("androidx.media:media:1.7.0")
    implementation("androidx.lifecycle:lifecycle-service:2.7.0")
}
