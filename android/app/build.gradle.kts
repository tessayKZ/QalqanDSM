plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.mycompany.qalqan_dsm"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "27.0.12077973"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.mycompany.qalqan_dsm"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        manifestPlaceholders += mapOf("applicationName" to "io.flutter.app.FlutterApplication")
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
    packagingOptions {
        jniLibs {
            pickFirsts += "**/libolm.so"
        }
    }
}

dependencies {
    // Стандартные зависимости Flutter/Kotlin
    implementation("androidx.core:core-ktx:1.6.0")
    implementation("org.jetbrains.kotlin:kotlin-stdlib-jdk7:1.8.20")
    implementation("org.matrix.android:olm-sdk:3.2.12")

}

flutter {
    source = "../.."
}
