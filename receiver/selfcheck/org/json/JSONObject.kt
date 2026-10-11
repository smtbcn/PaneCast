package org.json

/** Yalnız JVM öz-denetimi için derleme taslağı: Protocol.kt'deki org.json kullanımını karşılar.
 *  Öz-denetim JSON ayrıştırmaz; bu sınıf çağrılırsa boş davranır (APK'ya girmez). */
class JSONObject(@Suppress("UNUSED_PARAMETER") source: String = "") {
    fun put(key: String, value: Any?): JSONObject = this
    fun optInt(key: String, fallback: Int = 0): Int = fallback
    fun optLong(key: String, fallback: Long = 0): Long = fallback
    fun has(key: String): Boolean = false
    override fun toString(): String = "{}"
}
