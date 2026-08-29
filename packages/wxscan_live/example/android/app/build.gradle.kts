plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.wilinz.wxscan"
    // permission_handler_android 14 has to be compiled against SDK 37; a
    // higher one stays backwards compatible.
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "com.wilinz.wxscan"
        // CameraX needs 21+; the plugin requires 24
        minSdk = maxOf(24, flutter.minSdkVersion)
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // arm64 alone. Every Android device sold for years is arm64, and
        // the other two ABIs are a full Rust build each - three of
        // everything, for a demo.
        //
        // This only holds because gradle.properties turns off the Flutter
        // Gradle plugin's own ABI filtering, which otherwise clears this
        // block and puts its three back; see the note there. An application
        // that wants armeabi-v7a or the x86_64 emulator adds it here, and
        // both libraries are built for them.
        ndk {
            abiFilters += listOf("arm64-v8a")
        }
    }

    packaging {
        jniLibs {
            // The libraries are compressed in the APK and unpacked at install
            // time, which is what `android:extractNativeLibs="true"` means.
            // It is not the modern default: leaving them uncompressed and
            // page-aligned lets the loader map them straight out of the APK,
            // and costs no disk beyond the APK itself.
            //
            // The trade is download against installed size, and here the
            // download is the larger number: libtensorflowlite_c and
            // libwxscan_core deflate to about 40% of themselves.
            useLegacyPackaging = true
        }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")

            // R8 runs on a release build, and it stops on classes okhttp names
            // and no application has. proguard-rules.pro says why.
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
}

flutter {
    source = "../.."
}
