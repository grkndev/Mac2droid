package com.mac2droid.network

import com.mac2droid.protocol.FrameHeader
import com.mac2droid.protocol.M2DProtocol
import com.mac2droid.protocol.StreamConfig
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.isActive
import kotlinx.coroutines.withContext
import java.io.DataInputStream
import java.io.IOException
import java.net.InetSocketAddress
import java.net.Socket
import java.net.SocketTimeoutException

/**
 * TCP client for receiving video stream from Mac server
 */
class StreamClient(
    private val host: String = "127.0.0.1",  // localhost via ADB forward
    private val port: Int = M2DProtocol.DEFAULT_PORT
) {
    // Socket connection
    private var socket: Socket? = null
    private var inputStream: DataInputStream? = null

    // Connection state
    @Volatile
    private var isRunning = false

    // Callbacks
    var onHandshakeReceived: ((StreamConfig) -> Unit)? = null
    var onFrameReceived: ((FrameHeader, ByteArray) -> Unit)? = null
    var onError: ((Exception) -> Unit)? = null
    var onDisconnected: (() -> Unit)? = null

    /**
     * Connect to server and receive handshake
     */
    suspend fun connect(): Result<StreamConfig> = withContext(Dispatchers.IO) {
        try {
            // Create socket with timeout
            val sock = Socket()
            sock.soTimeout = 5000  // 5 second read timeout initially
            sock.tcpNoDelay = true  // Disable Nagle's algorithm for low latency
            sock.receiveBufferSize = 1024 * 1024  // 1MB receive buffer

            // Connect
            sock.connect(InetSocketAddress(host, port), 10000)  // 10 second connect timeout

            socket = sock
            inputStream = DataInputStream(sock.getInputStream())

            // Read handshake
            val handshakeData = readExact(M2DProtocol.HANDSHAKE_SIZE)
            val config = StreamConfig.parse(handshakeData)
                ?: return@withContext Result.failure(IOException("Invalid handshake"))

            // Reduce timeout for streaming
            sock.soTimeout = 1000

            onHandshakeReceived?.invoke(config)
            Result.success(config)

        } catch (e: Exception) {
            disconnect()
            Result.failure(e)
        }
    }

    /**
     * Start receiving frames (blocking call, run in coroutine)
     */
    suspend fun startReceiving(): Unit = withContext(Dispatchers.IO) {
        isRunning = true

        try {
            while (isRunning && isActive) {
                // Read frame header (12 bytes)
                val headerData = readExact(M2DProtocol.FRAME_HEADER_SIZE)
                val header = FrameHeader.parse(headerData)
                    ?: throw IOException("Invalid frame header")

                // Check for end of stream
                if (header.isEndOfStream) {
                    break
                }

                // Read payload
                if (header.payloadSize > 0) {
                    val payload = readExact(header.payloadSize)
                    onFrameReceived?.invoke(header, payload)
                }
            }
        } catch (e: SocketTimeoutException) {
            // Timeout is expected during idle periods
            if (isRunning) {
                // Continue if still running
                startReceiving()
            }
        } catch (e: Exception) {
            if (isRunning) {
                onError?.invoke(e)
            }
        } finally {
            isRunning = false
            onDisconnected?.invoke()
        }
    }

    /**
     * Disconnect from server
     */
    fun disconnect() {
        isRunning = false

        try {
            inputStream?.close()
            socket?.close()
        } catch (e: Exception) {
            // Ignore close errors
        } finally {
            inputStream = null
            socket = null
        }
    }

    /**
     * Check if connected
     */
    val isConnected: Boolean
        get() = socket?.isConnected == true && !socket!!.isClosed

    /**
     * Read exactly n bytes from stream (blocking)
     */
    private fun readExact(size: Int): ByteArray {
        val buffer = ByteArray(size)
        var offset = 0

        while (offset < size) {
            val bytesRead = inputStream?.read(buffer, offset, size - offset)
                ?: throw IOException("Stream closed")

            if (bytesRead < 0) {
                throw IOException("End of stream")
            }

            offset += bytesRead
        }

        return buffer
    }
}

/**
 * Connection manager for handling reconnection and state
 */
class ConnectionManager(
    private val host: String = "127.0.0.1",
    private val port: Int = M2DProtocol.DEFAULT_PORT
) {
    sealed class State {
        data object Disconnected : State()
        data object Connecting : State()
        data class Connected(val config: StreamConfig) : State()
        data object Streaming : State()
        data class Error(val message: String) : State()
    }

    private var client: StreamClient? = null

    var state: State = State.Disconnected
        private set

    var onStateChanged: ((State) -> Unit)? = null
    var onFrameReceived: ((FrameHeader, ByteArray) -> Unit)? = null

    /**
     * Connect to server
     */
    suspend fun connect(): Boolean {
        if (state is State.Connected || state is State.Streaming) {
            return true
        }

        setState(State.Connecting)

        val newClient = StreamClient(host, port)

        newClient.onFrameReceived = { header, payload ->
            if (state !is State.Streaming) {
                setState(State.Streaming)
            }
            onFrameReceived?.invoke(header, payload)
        }

        newClient.onDisconnected = {
            setState(State.Disconnected)
        }

        newClient.onError = { e ->
            setState(State.Error(e.message ?: "Unknown error"))
        }

        val result = newClient.connect()
        return if (result.isSuccess) {
            client = newClient
            setState(State.Connected(result.getOrThrow()))
            true
        } else {
            setState(State.Error(result.exceptionOrNull()?.message ?: "Connection failed"))
            false
        }
    }

    /**
     * Start receiving stream
     */
    suspend fun startReceiving() {
        client?.startReceiving()
    }

    /**
     * Disconnect
     */
    fun disconnect() {
        client?.disconnect()
        client = null
        setState(State.Disconnected)
    }

    private fun setState(newState: State) {
        state = newState
        onStateChanged?.invoke(newState)
    }
}
