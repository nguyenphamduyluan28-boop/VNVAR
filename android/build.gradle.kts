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
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}

// THÊM ĐOẠN NÀY VÀO CUỐI FILE ĐỂ ÉP CÁC MODULE (NHƯ BONSOIR) LÊN SDK 34
// Thay thế đoạn code cũ ở cuối file bằng đoạn này:
subprojects {
    plugins.withId("com.android.library") {
        the<com.android.build.gradle.BaseExtension>().apply {
            compileSdkVersion(34)
            defaultConfig {
                targetSdkVersion(34)
            }
        }
    }
}
