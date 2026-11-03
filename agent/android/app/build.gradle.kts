// Kotlin is built in since the Android Gradle plugin 9 (the root build file names its version):
// Kotlin compiles for the same JVM as Java, compileOptions' 17.
plugins {
    id("com.android.application")
}

android {
    namespace = "com.speedrun.agent"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.speedrun.agent"
        minSdk = 26
        targetSdk = 35
        versionCode = 1
        versionName = "0.1"
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}
