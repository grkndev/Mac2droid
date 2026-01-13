import Foundation
import Network

// MARK: - Stream Server
final class StreamServer: ObservableObject {
    // MARK: - Types
    enum ServerState {
        case idle
        case starting
        case listening(port: UInt16)
        case connected(client: String)
        case error(Error)
    }

    // MARK: - Published Properties
    @Published private(set) var state: ServerState = .idle
    @Published private(set) var bytesSent: UInt64 = 0

    // MARK: - Properties
    private var listener: NWListener?
    private var activeConnection: NWConnection?
    private let queue = DispatchQueue(label: "com.mac2droid.server", qos: .userInteractive)

    private var port: UInt16 = M2DProtocol.defaultPort

    // MARK: - Callbacks
    var onClientConnected: (() -> Void)?
    var onClientDisconnected: (() -> Void)?

    // MARK: - Public Methods

    /// Start listening for connections
    func start(port: UInt16 = M2DProtocol.defaultPort) throws {
        guard case .idle = state else {
            throw ServerError.alreadyRunning
        }

        self.port = port
        state = .starting

        // Configure TCP parameters
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        // Optimize for low latency
        if let tcpOptions = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcpOptions.noDelay = true  // Disable Nagle's algorithm
            tcpOptions.connectionTimeout = 30
            tcpOptions.enableKeepalive = true
            tcpOptions.keepaliveIdle = 10
        }

        // Create listener
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw ServerError.invalidPort
        }

        do {
            listener = try NWListener(using: params, on: nwPort)
        } catch {
            state = .error(error)
            throw error
        }

        // Handle state changes
        listener?.stateUpdateHandler = { [weak self] newState in
            self?.handleListenerStateChange(newState)
        }

        // Handle new connections
        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleNewConnection(connection)
        }

        // Start listening
        listener?.start(queue: queue)
        print("[StreamServer] Starting on port \(port)")
    }

    /// Stop server and disconnect client
    func stop() {
        activeConnection?.cancel()
        activeConnection = nil

        listener?.cancel()
        listener = nil

        bytesSent = 0
        state = .idle

        print("[StreamServer] Stopped")
    }

    /// Send handshake to connected client
    func sendHandshake(config: StreamConfig) throws {
        guard let connection = activeConnection else {
            throw ServerError.notConnected
        }

        let handshake = config.createHandshake()
        let data = handshake.serialize()

        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error = error {
                print("[StreamServer] Handshake send error: \(error)")
                self?.handleConnectionError(error)
            } else {
                print("[StreamServer] Handshake sent (\(data.count) bytes)")
            }
        })
    }

    /// Send frame data to connected client
    func sendFrame(header: M2DFrameHeader, payload: Data) {
        guard let connection = activeConnection else { return }

        // Combine header and payload
        var packet = header.serialize()
        packet.append(payload)

        connection.send(content: packet, completion: .contentProcessed { [weak self] error in
            if let error = error {
                print("[StreamServer] Frame send error: \(error)")
                self?.handleConnectionError(error)
            } else {
                DispatchQueue.main.async {
                    self?.bytesSent += UInt64(packet.count)
                }
            }
        })
    }

    /// Send end-of-stream marker
    func sendEndOfStream() {
        let header = M2DFrameHeader.endOfStream()
        sendFrame(header: header, payload: Data())
    }

    /// Check if client is connected
    var isConnected: Bool {
        if case .connected = state {
            return true
        }
        return false
    }

    // MARK: - Private Methods

    private func handleListenerStateChange(_ newState: NWListener.State) {
        switch newState {
        case .setup:
            break
        case .waiting(let error):
            print("[StreamServer] Waiting with error: \(error)")
        case .ready:
            DispatchQueue.main.async {
                self.state = .listening(port: self.port)
            }
            print("[StreamServer] Listening on port \(port)")
        case .failed(let error):
            print("[StreamServer] Failed: \(error)")
            DispatchQueue.main.async {
                self.state = .error(error)
            }
        case .cancelled:
            DispatchQueue.main.async {
                self.state = .idle
            }
        @unknown default:
            break
        }
    }

    private func handleNewConnection(_ connection: NWConnection) {
        // Only allow one client at a time
        if activeConnection != nil {
            print("[StreamServer] Rejecting connection - client already connected")
            connection.cancel()
            return
        }

        activeConnection = connection
        let clientInfo = connection.endpoint.debugDescription

        // Handle connection state
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                print("[StreamServer] Client connected: \(clientInfo)")
                DispatchQueue.main.async {
                    self?.state = .connected(client: clientInfo)
                    self?.onClientConnected?()
                }
            case .failed(let error):
                print("[StreamServer] Connection failed: \(error)")
                self?.handleConnectionError(error)
            case .cancelled:
                print("[StreamServer] Client disconnected")
                self?.handleDisconnection()
            default:
                break
            }
        }

        // Start connection
        connection.start(queue: queue)
    }

    private func handleConnectionError(_ error: Error) {
        activeConnection?.cancel()
        activeConnection = nil

        DispatchQueue.main.async {
            self.state = .listening(port: self.port)
            self.onClientDisconnected?()
        }
    }

    private func handleDisconnection() {
        activeConnection = nil

        DispatchQueue.main.async {
            self.state = .listening(port: self.port)
            self.onClientDisconnected?()
        }
    }
}

// MARK: - Server Errors
enum ServerError: LocalizedError {
    case alreadyRunning
    case invalidPort
    case notConnected
    case sendFailed(Error)

    var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            return "Server is already running"
        case .invalidPort:
            return "Invalid port number"
        case .notConnected:
            return "No client connected"
        case .sendFailed(let error):
            return "Send failed: \(error.localizedDescription)"
        }
    }
}
