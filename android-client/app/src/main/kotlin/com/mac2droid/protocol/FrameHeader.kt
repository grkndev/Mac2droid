package com.mac2droid.protocol

import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Stream configuration from handshake
 */
data class StreamConfig(
    val version: Int,
    val codec: M2DCodec,
    val width: Int,
    val height: Int,
    val frameRate: Int
) {
    companion object {
        /**
         * Parse handshake packet (24 bytes)
         */
        fun parse(data: ByteArray): StreamConfig? {
            if (data.size < M2DProtocol.HANDSHAKE_SIZE) return null

            val buffer = ByteBuffer.wrap(data).order(ByteOrder.BIG_ENDIAN)

            // Verify magic
            val magic = ByteArray(4)
            buffer.get(magic)
            if (!magic.contentEquals(M2DProtocol.MAGIC)) return null

            val version = buffer.int
            val codecValue = buffer.int
            val width = buffer.int
            val height = buffer.int
            val frameRate = buffer.int

            val codec = M2DCodec.fromValue(codecValue) ?: return null

            return StreamConfig(
                version = version,
                codec = codec,
                width = width,
                height = height,
                frameRate = frameRate
            )
        }
    }
}

/**
 * Frame header for each video packet
 */
data class FrameHeader(
    val isConfig: Boolean,
    val isKeyframe: Boolean,
    val isEndOfStream: Boolean,
    val pts: Long,          // Presentation timestamp in microseconds
    val payloadSize: Int
) {
    companion object {
        /**
         * Parse frame header (12 bytes)
         */
        fun parse(data: ByteArray): FrameHeader? {
            if (data.size < M2DProtocol.FRAME_HEADER_SIZE) return null

            val buffer = ByteBuffer.wrap(data).order(ByteOrder.BIG_ENDIAN)

            // Flags (1 byte)
            val flags = buffer.get().toInt() and 0xFF
            val isConfig = (flags and M2DFrameFlags.CONFIG) != 0
            val isKeyframe = (flags and M2DFrameFlags.KEYFRAME) != 0
            val isEndOfStream = (flags and M2DFrameFlags.END_OF_STREAM) != 0

            // Reserved (1 byte)
            buffer.get()

            // PTS (6 bytes) - read as part of 8-byte long
            val ptsBytes = ByteArray(8)
            buffer.get(ptsBytes, 2, 6)
            val pts = ByteBuffer.wrap(ptsBytes).order(ByteOrder.BIG_ENDIAN).long

            // Payload size (4 bytes)
            val payloadSize = buffer.int

            return FrameHeader(
                isConfig = isConfig,
                isKeyframe = isKeyframe,
                isEndOfStream = isEndOfStream,
                pts = pts,
                payloadSize = payloadSize
            )
        }
    }
}

/**
 * NAL unit parser for Annex B format
 */
object NalParser {
    /**
     * Extract SPS and PPS from config data
     * Config data format: [start_code][SPS][start_code][PPS]
     */
    fun extractParameterSets(configData: ByteArray): Pair<ByteArray, ByteArray>? {
        val nalUnits = extractNalUnits(configData)
        if (nalUnits.size < 2) return null

        // First NAL should be SPS (type 7), second should be PPS (type 8)
        val sps = nalUnits.find { getNalType(it) == 7 } ?: return null
        val pps = nalUnits.find { getNalType(it) == 8 } ?: return null

        return Pair(sps, pps)
    }

    /**
     * Extract NAL units from Annex B format data
     */
    fun extractNalUnits(data: ByteArray): List<ByteArray> {
        val units = mutableListOf<ByteArray>()
        var start = 0

        while (start < data.size) {
            // Find start code
            val startCodePos = findStartCode(data, start)
            if (startCodePos < 0) break

            // Find next start code or end of data
            val nalStart = startCodePos + 4
            var nalEnd = data.size

            val nextStartCode = findStartCode(data, nalStart)
            if (nextStartCode >= 0) {
                nalEnd = nextStartCode
            }

            // Extract NAL unit
            if (nalEnd > nalStart) {
                units.add(data.copyOfRange(nalStart, nalEnd))
            }

            start = nalEnd
        }

        return units
    }

    /**
     * Find 4-byte start code position starting from offset
     */
    private fun findStartCode(data: ByteArray, offset: Int): Int {
        for (i in offset until data.size - 3) {
            if (data[i] == 0x00.toByte() &&
                data[i + 1] == 0x00.toByte() &&
                data[i + 2] == 0x00.toByte() &&
                data[i + 3] == 0x01.toByte()) {
                return i
            }
        }
        return -1
    }

    /**
     * Get NAL unit type from first byte
     */
    fun getNalType(nalUnit: ByteArray): Int {
        return if (nalUnit.isNotEmpty()) nalUnit[0].toInt() and 0x1F else -1
    }
}
