package com.mac2droid.ui

import android.os.Bundle
import android.view.Surface
import android.view.View
import android.view.WindowManager
import android.widget.ProgressBar
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.lifecycle.lifecycleScope
import com.mac2droid.R
import com.mac2droid.decoder.VideoDecoder
import com.mac2droid.network.StreamClient
import com.mac2droid.protocol.M2DProtocol
import com.mac2droid.protocol.StreamConfig
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Full-screen activity for displaying video stream
 */
class StreamActivity : ComponentActivity() {

    // UI components
    private lateinit var surfaceView: StreamSurfaceView
    private lateinit var statusText: TextView
    private lateinit var progressBar: ProgressBar

    // Stream components
    private var streamClient: StreamClient? = null
    private var decoder: VideoDecoder? = null
    private var streamConfig: StreamConfig? = null
    private var pendingSurface: Surface? = null

    // Connection parameters
    private val host: String by lazy {
        intent.getStringExtra(EXTRA_HOST) ?: "127.0.0.1"
    }
    private val port: Int by lazy {
        intent.getIntExtra(EXTRA_PORT, M2DProtocol.DEFAULT_PORT)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_stream)

        setupFullscreen()
        initViews()
        startStreaming()
    }

    override fun onDestroy() {
        super.onDestroy()
        stopStreaming()
    }

    private fun setupFullscreen() {
        // Keep screen on
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

        // Hide system bars
        WindowCompat.setDecorFitsSystemWindows(window, false)
        WindowInsetsControllerCompat(window, window.decorView).let { controller ->
            controller.hide(WindowInsetsCompat.Type.systemBars())
            controller.systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        }
    }

    private fun initViews() {
        surfaceView = findViewById(R.id.surface_view)
        statusText = findViewById(R.id.status_text)
        progressBar = findViewById(R.id.progress_bar)

        surfaceView.onSurfaceReady = { surface ->
            onSurfaceReady(surface)
        }

        surfaceView.onSurfaceDestroyed = {
            stopStreaming()
        }
    }

    private fun startStreaming() {
        showStatus("Connecting to $host:$port...")

        lifecycleScope.launch {
            connectAndStream()
        }
    }

    private suspend fun connectAndStream() {
        val client = StreamClient(host, port)
        streamClient = client

        // Set up callbacks
        client.onError = { error ->
            runOnUiThread {
                showStatus("Error: ${error.message}")
            }
        }

        client.onDisconnected = {
            runOnUiThread {
                showStatus("Disconnected")
                finish()
            }
        }

        // Connect
        val result = client.connect()
        val config = result.getOrNull()
        if (config != null) {
            onConnected(config)
        } else {
            withContext(Dispatchers.Main) {
                showStatus("Connection failed: ${result.exceptionOrNull()?.message}")
            }
        }
    }

    private suspend fun onConnected(config: StreamConfig) {
        streamConfig = config
        withContext(Dispatchers.Main) {
            showStatus("Connected: ${config.width}x${config.height} @ ${config.frameRate}fps")
            surfaceView.setVideoSize(config.width, config.height)

            // If surface is already ready, start streaming
            pendingSurface?.let { surface ->
                startDecoding(surface)
            }
        }
    }

    private fun onSurfaceReady(surface: Surface) {
        pendingSurface = surface

        // If config is already available, start decoding
        if (streamConfig != null) {
            lifecycleScope.launch {
                startDecoding(surface)
            }
        }
    }

    private suspend fun startDecoding(surface: Surface) {
        val client = streamClient ?: return
        val config = streamConfig ?: return

        // Prevent double initialization
        if (decoder != null) return

        android.util.Log.d("StreamActivity", "Starting decoder: ${config.width}x${config.height}")

        // Create and configure decoder
        val videoDecoder = VideoDecoder()
        decoder = videoDecoder

        // Configure decoder with stored config
        videoDecoder.configure(config, surface)

        // Set frame handler
        client.onFrameReceived = { header, payload ->
            videoDecoder.decode(header, payload)
        }

        withContext(Dispatchers.Main) {
            hideStatus()
        }

        // Start receiving frames
        client.startReceiving()
    }

    private fun stopStreaming() {
        streamClient?.disconnect()
        streamClient = null

        decoder?.release()
        decoder = null
    }

    private fun showStatus(message: String) {
        statusText.text = message
        statusText.visibility = View.VISIBLE
        progressBar.visibility = View.VISIBLE
    }

    private fun hideStatus() {
        statusText.visibility = View.GONE
        progressBar.visibility = View.GONE
    }

    companion object {
        const val EXTRA_HOST = "host"
        const val EXTRA_PORT = "port"
    }
}
