plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// unifiedpush_android brings com.google.crypto.tink:tink and another
// dependency brings tink-android: one copy, the Android one (latest on Maven
// Central as of 2026-10-18), as the unifiedpush README suggests.
configurations.all {
    val tink = "com.google.crypto.tink:tink-android:1.24.0"
    resolutionStrategy {
        force(tink)
        dependencySubstitution {
            substitute(module("com.google.crypto.tink:tink")).using(module(tink))
        }
    }
}

android {
    namespace = "nl.sennadevos.roster"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        // flutter_local_notifications needs core library desugaring.
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "nl.sennadevos.roster"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // The release key comes from the environment (tool/release.sh decodes it
    // from the owner's secrets); without it a release build is signed with
    // the debug key, which a phone with the real app will refuse to update.
    val releaseStore = System.getenv("ROSTER_KEYSTORE")
    signingConfigs {
        if (releaseStore != null) {
            create("release") {
                storeFile = file(releaseStore)
                storeType = "PKCS12"
                storePassword = System.getenv("ROSTER_KEYSTORE_PASSWORD")
                keyAlias = "roster"
                keyPassword = System.getenv("ROSTER_KEYSTORE_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName(if (releaseStore != null) "release" else "debug")
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

dependencies {
    // Latest on Google's Maven as of 2026-10-18.
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
}
