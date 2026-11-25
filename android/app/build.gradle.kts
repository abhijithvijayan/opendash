import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// android/key.properties (gitignored) names the release keystore. Without
// it a release build is signed
// with the debug key, so a clean checkout still builds.
val keyProperties = Properties().apply {
    val file = rootProject.file("key.properties")
    if (file.exists()) file.inputStream().use { load(it) }
}
val releaseKeyFields = listOf("storeFile", "storePassword", "keyAlias", "keyPassword")
val hasReleaseKey = releaseKeyFields.all { !keyProperties.getProperty(it).isNullOrBlank() }
if (!keyProperties.isEmpty && !hasReleaseKey) {
    throw GradleException("android/key.properties must set ${releaseKeyFields.joinToString()}")
}

android {
    namespace = "in.abhijithvijayan.opendash"
    // Pinned so a Flutter upgrade can't move them. The
    // head unit is API 29; target 36 is what every build so far has run as,
    // and raising or lowering it changes background-start and overlay rules.
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "in.abhijithvijayan.opendash"
        minSdk = 24
        targetSdk = 36
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // For trying the "build that does not start" fallback
        // only (`OPENDASH_CRASH=kotlin scripts/deploy.sh`): the activity
        // throws before the Flutter engine exists. scripts/release.sh
        // refuses to build with it.
        buildConfigField("boolean", "CRASH_AT_START", (project.findProperty("opendash.crash") == "kotlin").toString())
    }

    buildFeatures {
        buildConfig = true
    }

    signingConfigs {
        if (hasReleaseKey) {
            create("release") {
                // Absolute, or relative to android/.
                storeFile = rootProject.file(keyProperties.getProperty("storeFile"))
                storePassword = keyProperties.getProperty("storePassword")
                keyAlias = keyProperties.getProperty("keyAlias")
                keyPassword = keyProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName(if (hasReleaseKey) "release" else "debug")
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
    // GitHub is asked through OkHttp for its DNS hook: names the network
    // cannot resolve are asked of 1.1.1.1 over HTTPS (Net.kt).
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("com.squareup.okhttp3:okhttp-dnsoverhttps:4.12.0")
    // The update-callback layouts are checked on the JVM (OtaDecoderTest).
    testImplementation("junit:junit:4.13.2")
}
