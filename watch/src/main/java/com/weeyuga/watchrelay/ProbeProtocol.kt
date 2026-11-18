package com.weeyuga.watchrelay

import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.IOException
import java.net.InetAddress
import java.net.Socket
import java.nio.ByteBuffer
import java.util.UUID

internal object ProbeProtocol {
    val UUID: UUID = java.util.UUID.fromString("0c5bc6fa-c662-4fc0-bc94-62a1ce97de9d")
    const val SERVICE_NAME = "WatchRelay"
    const val HELLO = 1
    const val HELLO_ACK = 2
    const val PING = 3
    const val PONG = 4
    const val CELL_PROBE = 5
    const val CELL_RESULT = 6
    const val OPEN = 7
    const val OPEN_OK = 8
    const val OPEN_ERR = 9
    const val DATA = 10
    const val HALF_CLOSE = 11
    const val CLOSE = 12
    const val WINDOW_UPDATE = 13
    const val AUTO_ENROLL = 14
    const val AUTO_ENROLLED = 15
    const val AUTO_CHALLENGE = 16
    const val AUTO_PROOF = 17
    const val AUTO_ACCEPT = 18
    const val HEADER_SIZE = 12
    const val DATA_MAX = 16_384
    const val INITIAL_CREDIT = 65_536

    data class Frame(val type: Int, val payload: ByteArray, val streamId: Long = 0)

    fun read(input: DataInputStream): Frame {
        val version = input.readUnsignedByte()
        val type = input.readUnsignedByte()
        val flags = input.readUnsignedShort()
        val streamId = input.readInt().toLong() and 0xffff_ffffL
        val length = input.readInt()
        val validLength = when (type) {
            HELLO, CELL_PROBE -> length == 0
            PING -> length in 1..256
            OPEN -> length in 5..259
            DATA -> length in 1..DATA_MAX
            HALF_CLOSE -> length == 0
            CLOSE -> length == 1
            WINDOW_UPDATE -> length == 4
            AUTO_ENROLL, AUTO_CHALLENGE, AUTO_ACCEPT -> length == AutoAuthentication.SIZE
            else -> false
        }
        val linkControl = type < OPEN || type >= AUTO_ENROLL
        if (version != 1 || flags != 0 || (streamId == 0L) != linkControl || !validLength) {
            throw ProtocolError()
        }
        val payload = ByteArray(length).also { input.readFully(it) }
        if (type == CLOSE && payload[0].toInt() !in 0..4) throw ProtocolError()
        if (type == WINDOW_UPDATE && ByteBuffer.wrap(payload).int !in 1..INITIAL_CREDIT) {
            throw ProtocolError()
        }
        return Frame(type, payload, streamId)
    }

    fun write(output: DataOutputStream, type: Int, payload: ByteArray, streamId: Long = 0) {
        output.writeByte(1)
        output.writeByte(type)
        output.writeShort(0)
        output.writeInt(streamId.toInt())
        output.writeInt(payload.size)
        output.write(payload)
        output.flush()
    }

    fun readDestination(payload: ByteArray): RelayDestination {
        val type = payload[0].toInt() and 0xff
        val port = ((payload[payload.size - 2].toInt() and 0xff) shl 8) or
            (payload.last().toInt() and 0xff)
        if (port == 0) throw RelayOpenFailure(1)
        return when (type) {
            1, 4 -> {
                val size = if (type == 1) 4 else 16
                if (payload.size != size + 3) throw RelayOpenFailure(8)
                RelayDestination(InetAddress.getByAddress(payload.copyOfRange(1, size + 1)), null, port)
            }
            3 -> {
                val size = payload[1].toInt() and 0xff
                if (payload.size != size + 4 || size !in 1..254) throw RelayOpenFailure(8)
                val host = payload.decodeToString(2, size + 2)
                if (!host.removeSuffix(".").split('.').all(DNS_LABEL::matches)) {
                    throw RelayOpenFailure(8)
                }
                RelayDestination(null, host, port)
            }
            else -> throw RelayOpenFailure(8)
        }
    }

    fun boundAddress(socket: Socket): ByteArray {
        val address = socket.localAddress.address
        return ByteBuffer.allocate(address.size + 3)
            .put(if (address.size == 4) 1.toByte() else 4.toByte())
            .put(address)
            .putShort(socket.localPort.toShort())
            .array()
    }

    private val DNS_LABEL = Regex("[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?")

    class ProtocolError : IOException()
}

internal data class RelayDestination(val address: InetAddress?, val hostname: String?, val port: Int)
