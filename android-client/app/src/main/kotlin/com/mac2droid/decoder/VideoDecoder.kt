package com.mac2droid.decoder

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.view.Surface
import com.mac2droid.protocol.FrameHeader
import com.mac2droid.protocol.NalParser
import com.mac2droid.protocol.StreamConfig
import java.nio.ByteBuffer
import java.util.concurrent.ConcurrentLinkedQueue

/**
 * Hardware H.264 decoder using MediaCodec
 */
class VideoDecoder {
    // MediaCodec instance
    private var mediaCodec: MediaCodec? = null
    private var surface: Surface? = null

    // Decoder state
    @Volatile
    private var isConfigured = false

    @Volatile
    private var isRunning = false

    // Frame queue for async processing
    private val frameQueue = ConcurrentLinkedQueue<DecoderFrame>()

    // Available input buffer indices
    private val availableInputBuffers = ConcurrentLinkedQueue<Int>()

    // Callback handler
    private var handlerThread: HandlerThread? = null
    private var handler: Handler? = null

    // Statistics
    var decodedFrameCount = 0L
        private set

    /**
     * Frame data for decoding
     */
    data class DecoderFrame(
        val data: ByteArray,
        val pts: Long,
        val isConfig: Boolean
    )

    /**
     * Configure decoder with stream parameters
     */
    fun configure(config: StreamConfig, outputSurface: Surface) {
        release()

        surface = outputSurface

        // Create video format
        val format = MediaFormat.createVideoFormat(
            MediaFormat.MIMETYPE_VIDEO_AVC,  // H.264
            config.width,
            config.height
        )

        // Create decoder
        val codec = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)

        // Start handler thread for callbacks
        handlerThread = HandlerThread("VideoDecoder").apply { start() }
        handler = Handler(handlerThread!!.looper)

        // Set async callback
        codec.setCallback(DecoderCallback(), handler)

        // Configure and start
        codec.configure(format, outputSurface, null, 0)
        codec.start()

        mediaCodec = codec
        isRunning = true

        android.util.Log.d(TAG, "Decoder configured: ${config.width}x${config.height}")
    }

    /**
     * Process codec configuration data (SPS/PPS)
     */
    fun processConfigData(data: ByteArray) {
        if (!isRunning) return

        val params = NalParser.extractParameterSets(data)
        if (params != null) {
            // Queue SPS
            frameQueue.offer(DecoderFrame(
                data = addStartCode(params.first),
                pts = 0,
                isConfig = true
            ))

            // Queue PPS
            frameQueue.offer(DecoderFrame(
                data = addStartCode(params.second),
                pts = 0,
                isConfig = true
            ))

            isConfigured = true
            android.util.Log.d(TAG, "Config data processed: SPS=${params.first.size}, PPS=${params.second.size}")
        }
    }

    /**
     * Decode a video frame
     */
    fun decode(header: FrameHeader, payload: ByteArray) {
        if (!isRunning) return

        if (header.isConfig) {
            processConfigData(payload)
            return
        }

        if (!isConfigured) {
            android.util.Log.w(TAG, "Skipping frame - decoder not configured")
            return
        }

        // Queue frame for decoding
        frameQueue.offer(DecoderFrame(
            data = payload,
            pts = header.pts,
            isConfig = false
        ))

        // Try to process queued frames
        processQueuedFrames()
    }

    /**
     * Process frames from queue using available input buffers
     */
    private fun processQueuedFrames() {
        val codec = mediaCodec ?: return

        while (true) {
            val bufferIndex = availableInputBuffers.poll() ?: return
            val frame = frameQueue.poll()

            if (frame == null) {
                // No frame available, put buffer back
                availableInputBuffers.offer(bufferIndex)
                return
            }

            try {
                val buffer = codec.getInputBuffer(bufferIndex) ?: continue
                buffer.clear()
                buffer.put(frame.data)

                val flags = if (frame.isConfig) {
                    MediaCodec.BUFFER_FLAG_CODEC_CONFIG
                } else {
                    0
                }

                codec.queueInputBuffer(
                    bufferIndex,
                    0,
                    frame.data.size,
                    frame.pts,
                    flags
                )
            } catch (e: Exception) {
                android.util.Log.e(TAG, "Error queuing input buffer: ${e.message}")
            }
        }
    }

    /**
     * Release decoder resources
     */
    fun release() {
        isRunning = false
        isConfigured = false
        frameQueue.clear()
        availableInputBuffers.clear()

        try {
            mediaCodec?.stop()
            mediaCodec?.release()
        } catch (e: Exception) {
            android.util.Log.e(TAG, "Error releasing codec: ${e.message}")
        }

        mediaCodec = null

        handlerThread?.quitSafely()
        handlerThread = null
        handler = null

        android.util.Log.d(TAG, "Decoder released")
    }

    /**
     * Add NAL start code if not present
     */
    private fun addStartCode(nalUnit: ByteArray): ByteArray {
        // Check if start code already present
        if (nalUnit.size >= 4 &&
            nalUnit[0] == 0x00.toByte() &&
            nalUnit[1] == 0x00.toByte() &&
            nalUnit[2] == 0x00.toByte() &&
            nalUnit[3] == 0x01.toByte()) {
            return nalUnit
        }

        // Prepend start code
        return byteArrayOf(0x00, 0x00, 0x00, 0x01) + nalUnit
    }

    /**
     * Async callback for MediaCodec
     */
    private inner class DecoderCallback : MediaCodec.Callback() {

        override fun onInputBufferAvailable(codec: MediaCodec, index: Int) {
            // Store available buffer index
            availableInputBuffers.offer(index)
            // Try to process any queued frames
            processQueuedFrames()
        }

        override fun onOutputBufferAvailable(
            codec: MediaCodec,
            index: Int,
            info: MediaCodec.BufferInfo
        ) {
            try {
                // Release buffer to surface for display
                codec.releaseOutputBuffer(index, true)
                decodedFrameCount++
            } catch (e: Exception) {
                android.util.Log.e(TAG, "Error releasing output buffer: ${e.message}")
            }
        }

        override fun onError(codec: MediaCodec, e: MediaCodec.CodecException) {
            android.util.Log.e(TAG, "Codec error: ${e.diagnosticInfo}")
        }

        override fun onOutputFormatChanged(codec: MediaCodec, format: MediaFormat) {
            android.util.Log.d(TAG, "Output format changed: $format")
        }
    }

    companion object {
        private const val TAG = "VideoDecoder"
    }
}
