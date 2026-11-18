package com.weeyuga.watchrelay

import com.weeyuga.watchrelay.ProbeProtocol.CLOSE
import com.weeyuga.watchrelay.ProbeProtocol.DATA
import com.weeyuga.watchrelay.ProbeProtocol.DATA_MAX
import com.weeyuga.watchrelay.ProbeProtocol.Frame
import com.weeyuga.watchrelay.ProbeProtocol.HALF_CLOSE
import com.weeyuga.watchrelay.ProbeProtocol.INITIAL_CREDIT
import com.weeyuga.watchrelay.ProbeProtocol.OPEN_OK
import com.weeyuga.watchrelay.ProbeProtocol.PONG
import com.weeyuga.watchrelay.ProbeProtocol.WINDOW_UPDATE
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.ByteBuffer
import java.util.concurrent.FutureTask
import java.util.concurrent.TimeUnit

class RelayOutboxTest {
    @Test(timeout = 3000)
    fun rotatesAcrossStreamsAndPreservesEachStreamsDataAndEofOrder() {
        val queue = RelayOutbox()
        val first = byteArrayOf(1, 2, 3)
        val second = byteArrayOf(4, 5)
        val third = byteArrayOf(6, 7, 8)
        listOf(
            openOk(1),
            Frame(DATA, first, 1),
            Frame(DATA, second, 1),
            Frame(HALF_CLOSE, ByteArray(0), 1),
            Frame(CLOSE, byteArrayOf(0), 1),
            openOk(2),
            Frame(DATA, third, 2),
            Frame(HALF_CLOSE, ByteArray(0), 2),
            pong(),
        ).forEach { assertTrue(queue.offer(it)) }

        val result = List(8) { takeFrame(queue) }
        assertEquals(setOf(0L, 1L, 2L), result.take(3).map { it.streamId }.toSet())
        assertEquals(setOf(1L, 2L), result.drop(3).take(2).map { it.streamId }.toSet())
        val one = result.filter { it.streamId == 1L }
        val two = result.filter { it.streamId == 2L }
        assertEquals(listOf(OPEN_OK, DATA, HALF_CLOSE, CLOSE), one.map { it.type })
        assertArrayEquals(first + second, one[1].payload)
        assertEquals(listOf(OPEN_OK, DATA, HALF_CLOSE), two.map { it.type })
        assertArrayEquals(third, two[1].payload)
        assertEquals(PONG, result.single { it.streamId == 0L }.type)
    }

    @Test(timeout = 3000)
    fun aggregatesCreditBehindOpenOkAndAheadOfData() {
        val queue = RelayOutbox()
        listOf(
            openOk(1),
            Frame(DATA, byteArrayOf(9), 1),
            credit(1, 12_000),
            credit(1, 1_234),
            Frame(HALF_CLOSE, ByteArray(0), 1),
            credit(1, INITIAL_CREDIT - 13_234),
        ).forEach { assertTrue(queue.offer(it)) }

        assertEquals(OPEN_OK, takeFrame(queue).type)
        val aggregated = takeFrame(queue)
        assertEquals(WINDOW_UPDATE, aggregated.type)
        assertEquals(1L, aggregated.streamId)
        assertEquals(INITIAL_CREDIT, ByteBuffer.wrap(aggregated.payload).int)
        assertEquals(DATA, takeFrame(queue).type)
        assertEquals(HALF_CLOSE, takeFrame(queue).type)
    }

    @Test(timeout = 3000)
    fun enforcesPerStreamAndGlobalByteCapsAndReusesFreedSpace() {
        val queue = RelayOutbox()
        val fullFrame = ByteArray(DATA_MAX)
        val globalCap = 2 * 1024 * 1024
        val fullStreams = globalCap / INITIAL_CREDIT
        for (id in 1L..fullStreams.toLong()) {
            repeat(INITIAL_CREDIT / DATA_MAX) {
                assertTrue(queue.offer(Frame(DATA, fullFrame, id)))
            }
            assertFalse(queue.offer(Frame(DATA, byteArrayOf(1), id)))
        }
        val newStream = fullStreams.toLong() + 1
        assertEquals(globalCap, queue.highWaterBytes)
        assertFalse(queue.offer(Frame(DATA, byteArrayOf(1), newStream)))
        assertTrue(queue.offer(pong()))

        val first = takeFrame(queue)
        assertEquals(DATA, first.type)
        assertEquals(DATA_MAX, first.payload.size)
        assertTrue(queue.offer(Frame(DATA, fullFrame, newStream)))
        assertFalse(queue.offer(Frame(DATA, byteArrayOf(1), newStream)))
        assertEquals(globalCap, queue.highWaterBytes)
    }

    @Test(timeout = 3000)
    fun controlFrameCapDoesNotCountDataOrWindowUpdates() {
        val queue = RelayOutbox()
        repeat(128) { assertTrue(queue.offer(pong())) }
        assertFalse(queue.offer(pong()))
        assertTrue(queue.offer(Frame(DATA, byteArrayOf(1), 1)))
        assertTrue(queue.offer(credit(2, 1)))
        assertEquals(PONG, takeFrame(queue).type)
        assertTrue(queue.offer(pong()))
        assertFalse(queue.offer(pong()))
    }

    @Test(timeout = 5000)
    fun offerAndCloseWakeWaitersAndCloseDiscardsPendingFrames() {
        val queue = RelayOutbox()
        try {
            val available = beginWaiting(queue)
            assertTrue(queue.offer(pong()))
            assertEquals(PONG, available.get(1, TimeUnit.SECONDS)?.type)

            val closing = beginWaiting(queue)
            queue.close()
            assertNull(closing.get(1, TimeUnit.SECONDS))
            assertFalse(queue.offer(pong()))
            assertNull(queue.take())
        } finally {
            queue.close()
        }

        val pending = RelayOutbox()
        assertTrue(pending.offer(pong()))
        pending.close()
        assertNull(pending.take())
    }

    private fun openOk(id: Long) = Frame(OPEN_OK, byteArrayOf(1, 0, 0, 0, 0, 0, 80), id)
    private fun pong() = Frame(PONG, byteArrayOf(1))
    private fun credit(id: Long, bytes: Int) = Frame(
        WINDOW_UPDATE, ByteBuffer.allocate(4).putInt(bytes).array(), id,
    )

    private fun takeFrame(queue: RelayOutbox): Frame {
        val frame = queue.take()
        assertNotNull(frame)
        return checkNotNull(frame)
    }

    private fun beginWaiting(queue: RelayOutbox): FutureTask<Frame?> {
        val pending = FutureTask(queue::take)
        val worker = Thread(pending, "test RelayOutbox.take").apply {
            isDaemon = true
            start()
        }
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(1)
        val waitingStates = setOf(Thread.State.WAITING, Thread.State.TIMED_WAITING)
        while (worker.isAlive && worker.state !in waitingStates && System.nanoTime() < deadline) {
            Thread.sleep(1)
        }
        assertTrue("consumer reached its empty-queue wait", worker.state in waitingStates)
        return pending
    }
}
