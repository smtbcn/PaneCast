import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

// Sürüm tek kaynaktan gelir: depo kökündeki VERSION (macOS betikleri de aynı dosyayı okur).
val appVersion: String = rootProject.file("../VERSION").readText().trim()
val versionParts = appVersion.split(".").map { it.toInt() }
require(versionParts.size == 3) { "VERSION biçimi MAJOR.MINOR.PATCH olmalı: $appVersion" }

// Yayın imzası: önce receiver/keystore.properties (gitignore), yoksa PANECAST_* ortam değişkenleri.
// İkisi de yoksa release imzasız üretilir; debug anahtarına ASLA düşülmez.
val keystoreProps = Properties().apply {
    val f = rootProject.file("keystore.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}
fun signingValue(prop: String, env: String): String? =
    (keystoreProps.getProperty(prop) ?: System.getenv(env))?.takeIf { it.isNotBlank() }
val releaseStoreFile = signingValue("storeFile", "PANECAST_KEYSTORE")
val releaseStorePassword = signingValue("storePassword", "PANECAST_KEYSTORE_PASSWORD")
val releaseKeyAlias = signingValue("keyAlias", "PANECAST_KEY_ALIAS")
val releaseKeyPassword = signingValue("keyPassword", "PANECAST_KEY_PASSWORD")
val releaseSigningReady = releaseStoreFile != null && releaseStorePassword != null &&
    releaseKeyAlias != null && releaseKeyPassword != null

android {
    namespace = "dev.atvm.receiver"
    compileSdk = 36
    // Hedef cihaz: Android TV, Android 11 / API 30, yalnızca armeabi-v7a, leanback_only.
    // Bu uygulama tamamen framework API kullanır (AndroidX bağımlılığı YOK) —
    // bkz. cihaz ölçümümüz, cihaz ölçümümüz (MemAvailable ~400 MB).

    defaultConfig {
        applicationId = "app.panecast.receiver"
        minSdk = 26
        // 34 = Google Play's minimum target for Android TV apps since 2026-08-31.
        // Staying below 35 avoids the edge-to-edge and large-screen orientation
        // behaviour changes, which cannot be tested on the API 30 reference TV.
        targetSdk = 34
        versionCode = versionParts[0] * 10000 + versionParts[1] * 100 + versionParts[2]
        versionName = appVersion
    }

    signingConfigs {
        if (releaseSigningReady) {
            create("release") {
                // Göreli yol receiver/ köküne göredir; mutlak yol olduğu gibi kullanılır.
                storeFile = rootProject.file(releaseStoreFile!!)
                storePassword = releaseStorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
            }
        }
    }

    // BuildConfig.DEBUG: eşleştirme kodu yalnız debug derlemesinde logcat'e yazılır (otomatik cihaz testi).
    buildFeatures {
        buildConfig = true
    }

    buildTypes {
        debug {
            isMinifyEnabled = false
        }
        release {
            isMinifyEnabled = false
            if (releaseSigningReady) {
                signingConfig = signingConfigs.getByName("release")
            } else {
                signingConfig = null
                logger.warn(
                    "UYARI: release imza bilgisi yok (receiver/keystore.properties veya PANECAST_KEYSTORE*). " +
                        "Release çıktısı İMZASIZ olacak; docs/RELEASING.md'ye bak."
                )
            }
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    lint {
        abortOnError = false
        warningsAsErrors = false
    }
}

dependencies {
    // Bilinçli olarak boş: AndroidX dahil HİÇBİR üçüncü taraf bağımlılık yok.
    // org.json platformda gelir; MediaCodec/SurfaceView/NsdManager framework API.
}
