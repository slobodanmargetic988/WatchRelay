package com.weeyuga.watchrelay

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.EOFException
import java.nio.ByteBuffer

class ProbeProtocolTest {
    @Test
    fun readsFragmentedAndCoalescedFrames() {
        val message = ByteArray(256) { it.toByte() }
        val frames = header(ProbeProtocol.HELLO, 0) +
            header(ProbeProtocol.PING, message.size) + message +
            header(ProbeProtocol.CELL_PROBE, 0)
        val fragmented = object : ByteArrayInputStream(frames) {
            override fun read(bytes: ByteArray, offset: Int, length: Int): Int =
                super.read(bytes, offset, minOf(length, 1))
        }

        val input = DataInputStream(fragmented)
        assertEquals(ProbeProtocol.HELLO, ProbeProtocol.read(input).type)
        val ping = ProbeProtocol.read(input)
        assertEquals(ProbeProtocol.PING, ping.type)
        assertArrayEquals(message, ping.payload)
        assertEquals(ProbeProtocol.CELL_PROBE, ProbeProtocol.read(input).type)
        assertEquals(-1, input.read())
    }

    @Test
    fun rejectsInvalidHeadersBeforeReadingPayload() {
        val invalid = listOf(
            header(ProbeProtocol.PING, -1),
            header(ProbeProtocol.PING, 0),
            header(ProbeProtocol.PING, 257),
            header(ProbeProtocol.PING, Int.MAX_VALUE),
            header(ProbeProtocol.HELLO, 1),
            header(ProbeProtocol.PONG, 1),
            header(ProbeProtocol.HELLO, 0, version = 2),
            header(ProbeProtocol.HELLO, 0, flags = 1),
            header(ProbeProtocol.HELLO, 0, streamId = 1),
        )
        for (bytes in invalid) {
            assertThrows(ProbeProtocol.ProtocolError::class.java) {
                ProbeProtocol.read(DataInputStream(ByteArrayInputStream(bytes)))
            }
        }
    }

    @Test
    fun rejectsTruncatedPayload() {
        val truncated = header(ProbeProtocol.PING, 4) + byteArrayOf(1, 2, 3)
        assertThrows(EOFException::class.java) {
            ProbeProtocol.read(DataInputStream(ByteArrayInputStream(truncated)))
        }
    }

    @Test
    fun writesNetworkByteOrderWithBinaryPayloadIntact() {
        val payload = byteArrayOf(0, 1, -1)
        val output = ByteArrayOutputStream()
        ProbeProtocol.write(DataOutputStream(output), ProbeProtocol.PONG, payload)
        assertArrayEquals(header(ProbeProtocol.PONG, payload.size) + payload, output.toByteArray())
    }

    @Test
    fun preservesUnsignedStreamIdsAndDomainDestination() {
        val host = "example.com".toByteArray()
        val payload = byteArrayOf(3, host.size.toByte()) + host + byteArrayOf(1, -69)
        val bytes = header(ProbeProtocol.OPEN, payload.size, streamId = -1) + payload
        val frame = ProbeProtocol.read(DataInputStream(ByteArrayInputStream(bytes)))
        assertEquals(0xffff_ffffL, frame.streamId)
        val destination = ProbeProtocol.readDestination(frame.payload)
        assertEquals("example.com", destination.hostname)
        assertEquals(443, destination.port)
    }

    @Test
    fun rejectsInvalidRelayFrames() {
        val invalid = listOf(
            header(ProbeProtocol.OPEN, 7),
            header(ProbeProtocol.PING, 1, streamId = 1),
            header(ProbeProtocol.DATA, ProbeProtocol.DATA_MAX + 1, streamId = 1),
            header(ProbeProtocol.HALF_CLOSE, 1, streamId = 1),
            header(ProbeProtocol.CLOSE, 1, streamId = 1) + byteArrayOf(5),
            header(ProbeProtocol.WINDOW_UPDATE, 4, streamId = 1) + ByteArray(4),
            header(ProbeProtocol.WINDOW_UPDATE, 4, streamId = 1) + byteArrayOf(0, 1, 0, 1),
        )
        for (bytes in invalid) {
            assertThrows(ProbeProtocol.ProtocolError::class.java) {
                ProbeProtocol.read(DataInputStream(ByteArrayInputStream(bytes)))
            }
        }
    }

    @Test
    fun validatesNumericAndInvalidDestinationsWithoutDns() {
        val ipv4 = byteArrayOf(1, 10, 0, 0, 1, 0, 80)
        assertEquals("10.0.0.1", ProbeProtocol.readDestination(ipv4).address?.hostAddress)
        val ipv6 = byteArrayOf(4) + ByteArray(15) + byteArrayOf(1, 0, 80)
        assertEquals(16, ProbeProtocol.readDestination(ipv6).address?.address?.size)
        val badHost = byteArrayOf(3, 4) + "-bad".toByteArray() + byteArrayOf(0, 80)
        assertEquals(8, assertThrows(RelayOpenFailure::class.java) {
            ProbeProtocol.readDestination(badHost)
        }.socksCode)
        assertEquals(1, assertThrows(RelayOpenFailure::class.java) {
            ProbeProtocol.readDestination(ipv4.copyOf().apply { this[6] = 0 })
        }.socksCode)
    }

    private fun header(
        type: Int,
        length: Int,
        version: Int = 1,
        flags: Int = 0,
        streamId: Int = 0,
    ): ByteArray = ByteBuffer.allocate(12)
        .put(version.toByte())
        .put(type.toByte())
        .putShort(flags.toShort())
        .putInt(streamId)
        .putInt(length)
        .array()
}
