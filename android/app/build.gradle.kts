plugins {
    id("com.android.application")
    id("kotlin-android")

    // Flutter plugin
    id("dev.flutter.flutter-gradle-plugin")

    // Firebase / Google services
    id("com.google.gms.google-services")
}

import java.util.Properties
import java.io.FileInputStream

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")

if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.garv.vaultx"

    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "com.garv.vaultx"

        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion

        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    lint {
        checkReleaseBuilds = false
        abortOnError = false
    }

    signingConfigs {
        create("releaseUpload") {
            if (keystorePropertiesFile.exists()) {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {

            // Enable shrinking
            isMinifyEnabled = true
            isShrinkResources = true

            // Proguard / R8
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )

            // Signing
            signingConfig =
                if (keystorePropertiesFile.exists())
                    signingConfigs.getByName("releaseUpload")
                else
                    signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}

dependencies {

    // AndroidX Security (EncryptedSharedPreferences)
    implementation("androidx.security:security-crypto:1.1.0-alpha06")

    // MegaSDK JAR
    implementation(files("libs/MegaSDK.jar"))

    // MEGA Android SDK — built from source and placed as a local AAR
    // Build instructions: https://github.com/meganz/sdk
    // 1. Clone https://github.com/meganz/sdk
    // 2. Follow Android build steps in bindings/java/
    // 3. Copy the resulting .aar to android/app/libs/
    implementation(fileTree(mapOf("dir" to "libs", "include" to listOf("*.aar"))))

    // ML Kit Base
    implementation("com.google.mlkit:text-recognition:16.0.1")

    // Extra language recognizers required by R8
    implementation("com.google.mlkit:text-recognition-chinese:16.0.1")
    implementation("com.google.mlkit:text-recognition-devanagari:16.0.1")
    implementation("com.google.mlkit:text-recognition-japanese:16.0.1")
    implementation("com.google.mlkit:text-recognition-korean:16.0.1")
}