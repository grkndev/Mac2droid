package com.mac2droid

import android.content.Intent
import android.os.Bundle
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.mac2droid.protocol.M2DProtocol
import com.mac2droid.ui.StreamActivity
import com.mac2droid.ui.theme.Mac2DroidTheme

/**
 * Main activity for connection setup
 */
class MainActivity : ComponentActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // Check for auto-connect intent from Mac app
        if (handleAutoConnect()) {
            return // Skip UI, already starting StreamActivity
        }

        setContent {
            Mac2DroidTheme {
                Surface(
                    modifier = Modifier.fillMaxSize(),
                    color = MaterialTheme.colorScheme.background
                ) {
                    ConnectionScreen(
                        onConnect = { host, port ->
                            startStreaming(host, port)
                        }
                    )
                }
            }
        }
    }

    /**
     * Handle auto-connect intent from Mac app
     * @return true if auto-connect was triggered
     */
    private fun handleAutoConnect(): Boolean {
        val autoConnect = intent.getStringExtra("auto_connect") == "true"
        if (autoConnect) {
            val port = intent.getStringExtra("port")?.toIntOrNull() ?: M2DProtocol.DEFAULT_PORT
            Toast.makeText(this, "Connecting to Mac...", Toast.LENGTH_SHORT).show()
            startStreaming("127.0.0.1", port)
            finish() // Close MainActivity, only StreamActivity will be shown
            return true
        }
        return false
    }

    private fun startStreaming(host: String, port: Int) {
        val intent = Intent(this, StreamActivity::class.java).apply {
            putExtra(StreamActivity.EXTRA_HOST, host)
            putExtra(StreamActivity.EXTRA_PORT, port)
        }
        startActivity(intent)
    }
}

@Composable
fun ConnectionScreen(
    onConnect: (host: String, port: Int) -> Unit
) {
    var host by remember { mutableStateOf("127.0.0.1") }
    var port by remember { mutableStateOf(M2DProtocol.DEFAULT_PORT.toString()) }
    var isConnecting by remember { mutableStateOf(false) }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center
    ) {
        // Title
        Text(
            text = "Mac2Droid",
            style = MaterialTheme.typography.headlineLarge,
            color = MaterialTheme.colorScheme.primary
        )

        Spacer(modifier = Modifier.height(8.dp))

        Text(
            text = "Stream your Mac display to Android",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )

        Spacer(modifier = Modifier.height(48.dp))

        // Connection card
        Card(
            modifier = Modifier.fillMaxWidth(),
            colors = CardDefaults.cardColors(
                containerColor = MaterialTheme.colorScheme.surfaceVariant
            )
        ) {
            Column(
                modifier = Modifier.padding(16.dp),
                horizontalAlignment = Alignment.CenterHorizontally
            ) {
                Text(
                    text = "USB Connection (ADB)",
                    style = MaterialTheme.typography.titleMedium
                )

                Spacer(modifier = Modifier.height(8.dp))

                Text(
                    text = "Make sure you run:\nadb forward tcp:5555 tcp:5555",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    textAlign = TextAlign.Center
                )

                Spacer(modifier = Modifier.height(16.dp))

                // Host input
                OutlinedTextField(
                    value = host,
                    onValueChange = { host = it },
                    label = { Text("Host") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth()
                )

                Spacer(modifier = Modifier.height(8.dp))

                // Port input
                OutlinedTextField(
                    value = port,
                    onValueChange = { port = it },
                    label = { Text("Port") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth()
                )

                Spacer(modifier = Modifier.height(24.dp))

                // Connect button
                Button(
                    onClick = {
                        val portNum = port.toIntOrNull() ?: M2DProtocol.DEFAULT_PORT
                        onConnect(host, portNum)
                    },
                    enabled = !isConnecting && host.isNotBlank(),
                    modifier = Modifier.fillMaxWidth()
                ) {
                    if (isConnecting) {
                        CircularProgressIndicator(
                            modifier = Modifier.size(24.dp),
                            color = MaterialTheme.colorScheme.onPrimary
                        )
                    } else {
                        Text("Connect")
                    }
                }
            }
        }

        Spacer(modifier = Modifier.height(32.dp))

        // Instructions
        Card(
            modifier = Modifier.fillMaxWidth(),
            colors = CardDefaults.cardColors(
                containerColor = MaterialTheme.colorScheme.secondaryContainer
            )
        ) {
            Column(
                modifier = Modifier.padding(16.dp)
            ) {
                Text(
                    text = "Quick Start",
                    style = MaterialTheme.typography.titleSmall,
                    color = MaterialTheme.colorScheme.onSecondaryContainer
                )

                Spacer(modifier = Modifier.height(8.dp))

                Text(
                    text = """
                        1. Connect your device via USB
                        2. Run: adb forward tcp:5555 tcp:5555
                        3. Start Mac2Droid on your Mac
                        4. Click 'Start Streaming' on Mac
                        5. Click 'Connect' here
                    """.trimIndent(),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSecondaryContainer
                )
            }
        }
    }
}
