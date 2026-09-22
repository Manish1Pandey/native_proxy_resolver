group = "dev.manishpanday.native_proxy_resolver"
version = "1.0-SNAPSHOT"

buildscript {
    val kotlinVersion = "2.2.20"
    repositories {
        google()
        mavenCentral()
    }

    dependencies {
        classpath("com.android.tools.build:gradle:8.11.1")
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:$kotlinVersion")
    }
}

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

plugins {
    id("com.android.library")
    // The Kotlin Gradle Plugin is still applied on purpose. AGP's built-in
    // Kotlin support, which is what would let this line go away, needs AGP 9
    // and Flutter 3.47, while this plugin supports Flutter 3.35+. Without KGP
    // there is no `kotlin` extension and the Kotlin sources are not compiled.
    // See https://docs.flutter.dev/release/breaking-changes/migrate-to-built-in-kotlin/for-plugin-authors
    id("kotlin-android")
}

android {
    namespace = "dev.manishpanday.native_proxy_resolver"

    compileSdk = 36

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    sourceSets {
        getByName("main") {
            java.srcDirs("src/main/kotlin")
        }
    }

    defaultConfig {
        minSdk = 24
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}
