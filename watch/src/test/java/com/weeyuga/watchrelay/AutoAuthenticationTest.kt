package com.weeyuga.watchrelay

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream

class AutoAuthenticationTest {
    private val key = ByteArray(32) { it.toByte() }
    private val macNonce = ByteArray(32) { (it + 32).toByte() }
    private val watchNonce = ByteArray(32) { (it + 64).toByte() }
    private val watchProof = "402e5137dbb2612f5f38cea9f914fa95d9dda519aac19a7ac8229e70d395fb87".hexToByteArray()
    private val macProof = "d5ea85976ed0329f9d25ad11ff7c5499284d9e83b31e255e3fd5a44193125708".hexToByteArray()

    @Test
    fun matchesIndependentHmacVectorsInBothDirections() {
        assertArrayEquals(watchProof, AutoAuthentication.watchProof(key, macNonce, watchNonce))
        assertTrue(AutoAuthentication.acceptsMac(key, macNonce, watchNonce, macProof))
    }

    @Test
    fun rejectsWrongKeyNonceAndProofDirection() {
        val wrongKey = key.copyOf().also { it[0]++ }
        val newNonce = watchNonce.copyOf().also { it[0]++ }
        assertFalse(AutoAuthentication.acceptsMac(wrongKey, macNonce, watchNonce, macProof))
        assertFalse(AutoAuthentication.acceptsMac(key, macNonce, newNonce, macProof))
        assertFalse(AutoAuthentication.acceptsMac(key, macNonce, watchNonce, watchProof))
    }

    @Test
    fun requiresExactControlFrameLengthsAndDirection() {
        for (type in listOf(ProbeProtocol.AUTO_ENROLL, ProbeProtocol.AUTO_CHALLENGE, ProbeProtocol.AUTO_ACCEPT)) {
            assertArrayEquals(key, read(type, 0, key).payload)
            assertThrows(ProbeProtocol.ProtocolError::class.java) { read(type, 1, key) }
            assertThrows(ProbeProtocol.ProtocolError::class.java) { read(type, 0, ByteArray(31)) }
        }
        assertThrows(ProbeProtocol.ProtocolError::class.java) {
            read(ProbeProtocol.AUTO_ENROLLED, 0, ByteArray(0))
        }
        assertThrows(ProbeProtocol.ProtocolError::class.java) {
            read(ProbeProtocol.AUTO_PROOF, 0, ByteArray(64))
        }
    }

    private fun read(type: Int, id: Long, payload: ByteArray): ProbeProtocol.Frame {
        val output = ByteArrayOutputStream()
        ProbeProtocol.write(DataOutputStream(output), type, payload, id)
        return ProbeProtocol.read(DataInputStream(ByteArrayInputStream(output.toByteArray())))
    }
}
