package com.weeyuga.watchrelay

import java.security.MessageDigest
import java.security.SecureRandom
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

internal object AutoAuthentication {
    const val SIZE = 32
    private val random = SecureRandom()
    private val watchTag = "WatchRelay auto watch v1".toByteArray(Charsets.US_ASCII)
    private val macTag = "WatchRelay auto mac v1".toByteArray(Charsets.US_ASCII)

    fun nonce(): ByteArray = ByteArray(SIZE).also(random::nextBytes)

    fun watchProof(key: ByteArray, macNonce: ByteArray, watchNonce: ByteArray): ByteArray =
        authenticate(key, watchTag, macNonce, watchNonce)

    fun acceptsMac(key: ByteArray, macNonce: ByteArray, watchNonce: ByteArray, proof: ByteArray): Boolean =
        MessageDigest.isEqual(authenticate(key, macTag, macNonce, watchNonce), proof)

    private fun authenticate(
        key: ByteArray,
        tag: ByteArray,
        macNonce: ByteArray,
        watchNonce: ByteArray,
    ): ByteArray = Mac.getInstance("HmacSHA256").run {
        init(SecretKeySpec(key, "HmacSHA256"))
        update(tag)
        update(macNonce)
        doFinal(watchNonce)
    }
}
