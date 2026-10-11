package android.util

/** Yalnız JVM öz-denetimi için: RtpDepacketizer'ın `android.util.Log` çağrılarını karşılar (APK'ya girmez). */
object Log {
    fun i(tag: String, msg: String): Int = 0
    fun w(tag: String, msg: String): Int = 0
}
