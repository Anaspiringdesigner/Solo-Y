plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace  = "com.example.biofeedback_app"
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    defaultConfig {
        applicationId = "com.example.biofeedback_app"
        minSdk = 24
        targetSdk     = 36
        versionCode   = flutter.versionCode
        versionName   = flutter.versionName
    }

    packaging {
        jniLibs {
            pickFirsts += setOf("lib/**/libc++_shared.so")
        }
    }

    buildTypes {
        release {
            signingConfig =
                signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}
