import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

// Bản release phải ký bằng keystore thật (android/key.properties). Chỉ cho phép
// ký bằng debug key khi đặt rõ VNVAR_ALLOW_DEBUG_SIGNING=true (ví dụ CI tạo bản
// thử nghiệm); trước đây việc này diễn ra âm thầm.
val allowDebugReleaseSigning = System.getenv("VNVAR_ALLOW_DEBUG_SIGNING") == "true"

android {
    namespace = "vn.vnvar.cameraStation"
    // flutter_webrtc 1.6.0 is compiled against Android SDK 36.
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "vn.vnvar.sportocam"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            val keyAliasVal = keystoreProperties["keyAlias"] as String?
            val keyPasswordVal = keystoreProperties["keyPassword"] as String?
            val storePasswordVal = keystoreProperties["storePassword"] as String?
            val storeFileVal = keystoreProperties["storeFile"] as String?
            if (keyAliasVal != null && keyPasswordVal != null && storePasswordVal != null && storeFileVal != null) {
                keyAlias = keyAliasVal
                keyPassword = keyPasswordVal
                storePassword = storePasswordVal
                storeFile = file(storeFileVal)
            }
        }
    }

    buildTypes {
        release {
            val releaseSigningConfig = signingConfigs.findByName("release")
            if (releaseSigningConfig?.storeFile?.exists() == true) {
                signingConfig = releaseSigningConfig
            } else {
                // Chỉ dùng khi VNVAR_ALLOW_DEBUG_SIGNING=true; nếu không, kiểm tra
                // bên dưới chặn bản release trước khi build.
                signingConfig = signingConfigs.getByName("debug")
            }
        }
    }
}

// Kiểm tra lúc đã biết task sẽ chạy, để build debug/profile không bị ảnh hưởng.
gradle.taskGraph.whenReady {
    val releaseSigningReady =
        android.signingConfigs.findByName("release")?.storeFile?.exists() == true
    val buildsRelease = allTasks.any { task ->
        task.project == project &&
            task.name.endsWith("Release") &&
            (task.name.startsWith("assemble") ||
                task.name.startsWith("bundle") ||
                task.name.startsWith("package"))
    }
    if (buildsRelease && !releaseSigningReady) {
        if (!allowDebugReleaseSigning) {
            throw GradleException(
                "Missing release keystore (android/key.properties). Refusing to sign " +
                    "the release build with the debug key. Set " +
                    "VNVAR_ALLOW_DEBUG_SIGNING=true only for test builds.",
            )
        }
        logger.warn("WARNING: release build is signed with the DEBUG key (test build only).")
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
    // Keep this version exactly aligned with flutter_webrtc 1.6.0. The app
    // module needs it directly because the VNVAR RTSP sink uses VideoTrack.
    implementation("io.github.webrtc-sdk:android:144.7559.09")
}
