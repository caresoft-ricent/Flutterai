plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystorePath = System.getenv("RICENT_KEYSTORE")
val keyAliasEnv = System.getenv("RICENT_KEYSTORE_ALIAS")
val keyPassEnv = System.getenv("RICENT_KEYSTORE_PASS")
val hasReleaseSigning = keystorePath != null && keyAliasEnv != null && keyPassEnv != null

android {
    namespace = "com.ricent.beaverai"
    compileSdk = 36
    ndkVersion = "27.0.12077973"

    compileOptions {
        // Flutter + Android Gradle Plugin (8.x) recommend Java 17.
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.ricent.beaverai"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 23
        targetSdk = 36
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            if (hasReleaseSigning) {
                storeFile = file(keystorePath!!)
                storePassword = keyPassEnv
                keyAlias = keyAliasEnv
                keyPassword = keyPassEnv
            }
        }
    }

    buildTypes {
        getByName("release") {
            // If release keystore env vars are set, sign with it; otherwise fall back to debug
            // so local builds still produce an installable APK.
            signingConfig = if (hasReleaseSigning) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

flutter {
    source = "../.."
}
