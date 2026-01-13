package com.mac2droid.protocol

/**
 * Mac2Droid streaming protocol constants
 */
object M2DProtocol {
    /** Magic bytes for handshake: "M2D\0" */
    val MAGIC = byteArrayOf(0x4D, 0x32, 0x44, 0x00)

    /** Protocol version: 1.0.0 = 0x00010000 */
    const val VERSION = 0x00010000

    /** Default server port */
    const val DEFAULT_PORT = 5555

    /** Handshake size in bytes */
    const val HANDSHAKE_SIZE = 24

    /** Frame header size in bytes */
    const val FRAME_HEADER_SIZE = 12

    /** NAL start code (4 bytes) */
    val NAL_START_CODE = byteArrayOf(0x00, 0x00, 0x00, 0x01)
}

/**
 * Video codec types
 */
enum class M2DCodec(val value: Int) {
    H264(1),
    HEVC(2);

    companion object {
        fun fromValue(value: Int): M2DCodec? = entries.find { it.value == value }
    }
}

/**
 * Frame flags (bit field)
 */
object M2DFrameFlags {
    /** Frame contains codec configuration (SPS/PPS) */
    const val CONFIG = 0x80

    /** Frame is a keyframe (IDR) */
    const val KEYFRAME = 0x40

    /** End of stream marker */
    const val END_OF_STREAM = 0x20
}

/**
 * Quality presets matching Mac server
 */
enum class M2DQuality(
    val width: Int,
    val height: Int,
    val frameRate: Int,
    val bitRate: Int
) {
    PERFORMANCE(1280, 720, 30, 4_000_000),
    BALANCED(1920, 1080, 30, 6_000_000),
    QUALITY(1920, 1080, 60, 10_000_000)
}
