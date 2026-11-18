package com.weeyuga.watchrelay

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class BluetoothProbeServerTest {
    @Test
    fun readsAssignedChannelFromAndroidSocketDescription() {
        assertEquals(9, BluetoothProbeServer.rfcommChannelFromDescription(
            "ServerSocket: Type: TYPE_RFCOMM Channel: 9",
        ))
    }

    @Test
    fun leavesChannelUnavailableWhenFirmwareOmitsItOrReportsAnInvalidValue() {
        for (description in listOf("BluetoothServerSocket", "Channel: -1", "Channel: 0", "Channel: 31")) {
            assertNull(BluetoothProbeServer.rfcommChannelFromDescription(description))
        }
    }
}
