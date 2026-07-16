import CryptoKit
import Foundation
import Network
import Security

final class Gateway: @unchecked Sendable {
    struct PairingTicket {
        let id: String
        let secret: Data
        let expiresAt: Date
    }

    private let queue = DispatchQueue(label: "dev.openlens.remote.gateway", qos: .userInitiated)
    private let identity: AgentIdentity
    private let deviceRegistry: DeviceRegistry
    private let forwarder: OpenCodeForwarder
    private let accessValidator: any CloudflareAccessValidating
    private var listener: NWListener?
    private var listenerGeneration: UUID?
    private var shouldRun = false
    private var isReady = false
    private var restartAttempt = 0
    private var restartWorkItem: DispatchWorkItem?
    private var connections: [ObjectIdentifier: GatewayConnection] = [:]
    private var pairingTicket: PairingTicket?
    private var failedAttempts: [String: [Date]] = [:]
    private var peerContexts: [String: (peer: String, expiresAt: Date)] = [:]
    var onRunningChange: (@Sendable (Bool) -> Void)?
    var onError: (@Sendable (Error) -> Void)?

    init(
        identity: AgentIdentity,
        deviceRegistry: DeviceRegistry,
        forwarder: OpenCodeForwarder,
        accessValidator: any CloudflareAccessValidating
    ) {
        self.identity = identity
        self.deviceRegistry = deviceRegistry
        self.forwarder = forwarder
        self.accessValidator = accessValidator
    }

    func start() throws {
        try queue.sync {
            shouldRun = true
            try startOnQueue()
        }
    }

    private func startOnQueue() throws {
        guard listener == nil else { return }
        restartWorkItem?.cancel()
        restartWorkItem = nil
        let webSocket = NWProtocolWebSocket.Options()
        webSocket.autoReplyPing = true
        webSocket.maximumMessageSize = RemoteProtocolVersion.maximumWireMessageBytes
        webSocket.setClientRequestHandler(queue) { [weak self] subprotocols, headers in
            guard subprotocols.contains(RemoteProtocolVersion.webSocketSubprotocol),
                  self?.isAccessAuthorized(headers: headers) == true
            else {
                return NWProtocolWebSocket.Response(status: .reject, subprotocol: nil)
            }
            return NWProtocolWebSocket.Response(
                status: .accept,
                subprotocol: RemoteProtocolVersion.webSocketSubprotocol
            )
        }

        let parameters = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
        parameters.requiredLocalEndpoint = .hostPort(
            host: "127.0.0.1",
            port: NWEndpoint.Port(rawValue: RemoteProtocolVersion.gatewayPort)!
        )
        let listener = try NWListener(using: parameters)
        let generation = UUID()
        listener.newConnectionLimit = 64
        listener.stateUpdateHandler = { [weak self] state in
            self?.handleListenerState(state, generation: generation)
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        self.listener = listener
        listenerGeneration = generation
        isReady = false
        listener.start(queue: queue)
    }

    func stop() {
        queue.async { [self] in
            shouldRun = false
            restartWorkItem?.cancel()
            restartWorkItem = nil
            pairingTicket = nil
            listener?.cancel()
            listener = nil
            listenerGeneration = nil
            isReady = false
            restartAttempt = 0
            let active = connections.values
            connections.removeAll()
            active.forEach { $0.cancel() }
            notifyRunning(false)
        }
    }

    func disconnectDevice(id: String) {
        queue.async { [self] in
            connections.values
                .filter { $0.connectedDeviceID == id }
                .forEach { $0.cancel() }
        }
    }

    func disconnectAllDevices() {
        queue.async { [self] in
            let active = Array(connections.values)
            active.forEach { $0.cancel() }
        }
    }

    func makePairingOffer(
        endpoint: URL,
        accessCredential: CloudflareAccessCredential
    ) throws -> RemotePairingOffer {
        try queue.sync {
            guard listener != nil, isReady else { throw RemoteAgentError.gatewayUnavailable }
            var secret = Data(count: 32)
            let status = secret.withUnsafeMutableBytes { buffer in
                SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
            }
            guard status == errSecSuccess else { throw RemoteAgentError.keychainFailure }
            let ticket = PairingTicket(
                id: UUID().uuidString,
                secret: secret,
                expiresAt: Date().addingTimeInterval(5 * 60)
            )
            pairingTicket = ticket
            return RemotePairingOffer(
                endpoint: endpoint,
                gatewayID: identity.gatewayID,
                gatewayPublicKey: identity.publicKeyData,
                pairingID: ticket.id,
                pairingSecret: ticket.secret,
                accessCredential: accessCredential,
                expiresAt: ticket.expiresAt
            )
        }
    }

    fileprivate func consumePairingTicket(id: String, secret: Data, peer: String) -> Bool {
        guard !isRateLimited(peer: peer),
              let ticket = pairingTicket,
              ticket.id == id,
              ticket.expiresAt > Date(),
              ticket.secret.constantTimeEquals(secret)
        else {
            recordFailedAttempt(peer: peer)
            return false
        }
        pairingTicket = nil
        return true
    }

    fileprivate func shouldRejectAuthentication(peer: String) -> Bool {
        isRateLimited(peer: peer)
    }

    fileprivate func lookupDevice(id: String, peer: String) -> TrustedDevice? {
        guard !isRateLimited(peer: peer), let device = deviceRegistry.device(id: id) else {
            recordFailedAttempt(peer: peer)
            return nil
        }
        return device
    }

    fileprivate func consumePeerIdentifier(handshakeID: String, fallback: String) -> String {
        let context = peerContexts.removeValue(forKey: handshakeID)
        guard let context, context.expiresAt > Date() else { return fallback }
        return context.peer
    }

    fileprivate func addDevice(name: String, publicKey: Data) throws -> TrustedDevice {
        try deviceRegistry.add(name: name, publicKey: publicKey)
    }

    fileprivate func activateDeviceSession(id: String, connection: GatewayConnection) {
        let previous = connections.values.first {
            $0 !== connection && $0.connectedDeviceID == id
        }
        previous?.cancel()
        deviceRegistry.markConnected(id: id)
    }

    fileprivate func removeConnection(_ connection: GatewayConnection) {
        connections.removeValue(forKey: ObjectIdentifier(connection))
    }

    private func accept(_ networkConnection: NWConnection) {
        let pendingAuthenticationCount = connections.values.filter { !$0.isAuthenticated }.count
        guard pendingAuthenticationCount < 8 else {
            networkConnection.cancel()
            return
        }
        let connection = GatewayConnection(
            networkConnection: networkConnection,
            queue: queue,
            gateway: self,
            identity: identity,
            forwarder: forwarder
        )
        connections[ObjectIdentifier(connection)] = connection
        connection.start()
    }

    private func isAccessAuthorized(
        headers: [(name: String, value: String)]
    ) -> Bool {
        let assertions = headers.filter {
            $0.name.caseInsensitiveCompare("Cf-Access-Jwt-Assertion") == .orderedSame
        }
        let handshakeIDs = headers.filter {
            $0.name.caseInsensitiveCompare("X-OpenLens-Handshake-ID") == .orderedSame
        }
        let connectingIPs = headers.filter {
            $0.name.caseInsensitiveCompare("CF-Connecting-IP") == .orderedSame
        }
        guard assertions.count == 1,
              handshakeIDs.count == 1,
              connectingIPs.count == 1,
              Self.isValidHandshakeID(handshakeIDs[0].value),
              Self.isValidIPAddress(connectingIPs[0].value),
              accessValidator.validate(assertion: assertions[0].value, now: Date())
        else { return false }

        let now = Date()
        peerContexts = peerContexts.filter { $0.value.expiresAt > now }
        guard peerContexts.count < 128 else { return false }
        peerContexts[handshakeIDs[0].value] = (
            peer: connectingIPs[0].value,
            expiresAt: now.addingTimeInterval(15)
        )
        return true
    }

    private static func isValidHandshakeID(_ value: String) -> Bool {
        (1...128).contains(value.utf8.count) && value.unicodeScalars.allSatisfy {
            $0.value < 128 && (CharacterSet.alphanumerics.contains($0) || $0 == "-")
        }
    }

    private static func isValidIPAddress(_ value: String) -> Bool {
        IPv4Address(value) != nil || IPv6Address(value) != nil
    }

    private func handleListenerState(_ state: NWListener.State, generation: UUID) {
        guard listenerGeneration == generation else { return }
        switch state {
        case .ready:
            isReady = true
            restartAttempt = 0
            notifyRunning(true)
        case .failed:
            isReady = false
            listener?.cancel()
            listener = nil
            listenerGeneration = nil
            notifyRunning(false)
            notifyError(RemoteAgentError.gatewayUnavailable)
            scheduleRestart()
        case .cancelled:
            isReady = false
            listener = nil
            listenerGeneration = nil
            notifyRunning(false)
            scheduleRestart()
        case .setup, .waiting:
            break
        @unknown default:
            break
        }
    }

    private func scheduleRestart() {
        guard shouldRun, restartWorkItem == nil else { return }
        restartAttempt += 1
        let delay = min(pow(2, Double(restartAttempt - 1)), 30)
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            restartWorkItem = nil
            guard shouldRun else { return }
            do {
                try startOnQueue()
            } catch {
                notifyError(error)
                scheduleRestart()
            }
        }
        restartWorkItem = workItem
        queue.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func isRateLimited(peer: String) -> Bool {
        let threshold = Date().addingTimeInterval(-60)
        failedAttempts[peer] = failedAttempts[peer, default: []].filter { $0 > threshold }
        return failedAttempts[peer, default: []].count >= 5
    }

    private func recordFailedAttempt(peer: String) {
        let threshold = Date().addingTimeInterval(-60)
        var attempts = failedAttempts[peer, default: []].filter { $0 > threshold }
        attempts.append(Date())
        failedAttempts[peer] = Array(attempts.suffix(8))
    }

    private func notifyRunning(_ running: Bool) {
        let callback = onRunningChange
        DispatchQueue.main.async { callback?(running) }
    }

    private func notifyError(_ error: Error) {
        let callback = onError
        DispatchQueue.main.async { callback?(error) }
    }
}

fileprivate final class GatewayConnection: @unchecked Sendable {
    private let networkConnection: NWConnection
    private let queue: DispatchQueue
    private unowned let gateway: Gateway
    private let identity: AgentIdentity
    private let forwarder: OpenCodeForwarder
    private var deviceID: String?
    private var sessionID: String?
    private var encryptor: RemoteEncryptor?
    private var decryptor: RemoteDecryptor?
    private var eventStreams: [String: GatewayEventStream] = [:]
    private var requestTasks: [String: Task<Void, Never>] = [:]
    private var authenticationTimeout: DispatchWorkItem?
    private var isClosed = false

    init(
        networkConnection: NWConnection,
        queue: DispatchQueue,
        gateway: Gateway,
        identity: AgentIdentity,
        forwarder: OpenCodeForwarder
    ) {
        self.networkConnection = networkConnection
        self.queue = queue
        self.gateway = gateway
        self.identity = identity
        self.forwarder = forwarder
    }

    func start() {
        let authenticationTimeout = DispatchWorkItem { [weak self] in
            guard let self, !isAuthenticated else { return }
            close()
        }
        self.authenticationTimeout = authenticationTimeout
        queue.asyncAfter(deadline: .now() + 10, execute: authenticationTimeout)
        networkConnection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                receiveNext()
            case .failed, .cancelled:
                close()
            case .setup, .preparing, .waiting:
                break
            @unknown default:
                break
            }
        }
        networkConnection.start(queue: queue)
    }

    func cancel() {
        close()
    }

    var connectedDeviceID: String? { deviceID }
    var isAuthenticated: Bool { deviceID != nil }

    private func receiveNext() {
        guard !isClosed else { return }
        networkConnection.receiveMessage { [weak self] content, _, _, error in
            guard let self else { return }
            if let error {
                _ = error
                close()
                return
            }
            guard let content,
                  !content.isEmpty,
                  content.count <= (isAuthenticated
                    ? RemoteProtocolVersion.maximumWireMessageBytes
                    : 64 * 1_024)
            else {
                close()
                return
            }
            do {
                try handle(RemoteWireEnvelope.decode(content))
                receiveNext()
            } catch {
                rejectAndClose()
            }
        }
    }

    private func handle(_ envelope: RemoteWireEnvelope) throws {
        if deviceID == nil {
            switch envelope.kind {
            case .pairingRequest:
                try handlePairing(envelope)
            case .sessionHello:
                try handleSessionHello(envelope)
            default:
                throw RemoteProtocolError.authenticationFailed
            }
            return
        }

        guard envelope.kind == .encrypted,
              envelope.deviceID == deviceID,
              envelope.sessionID == sessionID,
              let sequence = envelope.sequence,
              let ciphertext = envelope.ciphertext,
              var decryptor
        else {
            throw RemoteProtocolError.authenticationFailed
        }
        let message = try RemoteMessage.decode(
            try decryptor.open(sequence: sequence, ciphertext: ciphertext)
        )
        self.decryptor = decryptor
        handle(message)
    }

    private func handlePairing(_ envelope: RemoteWireEnvelope) throws {
        guard let pairingID = envelope.pairingID,
              let encapsulatedKey = envelope.encapsulatedKey,
              let sequence = envelope.sequence,
              let ciphertext = envelope.ciphertext
        else { throw RemoteProtocolError.malformedMessage }
        let peer = gateway.consumePeerIdentifier(
            handshakeID: pairingID,
            fallback: peerIdentifier
        )
        guard !gateway.shouldRejectAuthentication(peer: peer) else {
            throw RemoteProtocolError.authenticationFailed
        }

        var decryptor = try RemoteCrypto.pairingRecipient(
            gatewayPrivateKey: identity.privateKey,
            pairingID: pairingID,
            encapsulatedKey: encapsulatedKey
        )
        let request = try JSONDecoder().decode(
            RemotePairingRequest.self,
            from: decryptor.open(sequence: sequence, ciphertext: ciphertext)
        )
        guard gateway.consumePairingTicket(
            id: pairingID,
            secret: request.pairingSecret,
            peer: peer
        ) else {
            rejectAndClose()
            return
        }
        authenticationTimeout?.cancel()
        authenticationTimeout = nil
        let publicKey = try RemoteCrypto.publicKey(rawRepresentation: request.devicePublicKey)
        let device = try gateway.addDevice(
            name: request.deviceName,
            publicKey: publicKey.rawRepresentation
        )
        var encryptor = try RemoteCrypto.pairingResponseSender(
            devicePublicKey: publicKey,
            gatewayPrivateKey: identity.privateKey,
            pairingID: pairingID
        )
        let response = RemotePairingResponse(
            gatewayID: identity.gatewayID,
            deviceID: device.id,
            deviceName: device.name
        )
        let sealed = try encryptor.seal(try JSONEncoder().encode(response))
        send(
            RemoteWireEnvelope(
                kind: .pairingResponse,
                pairingID: pairingID,
                encapsulatedKey: encryptor.encapsulatedKey,
                sequence: sealed.sequence,
                ciphertext: sealed.ciphertext
            ),
            closeAfterSending: true
        )
    }

    private func handleSessionHello(_ envelope: RemoteWireEnvelope) throws {
        guard let deviceID = envelope.deviceID,
              let sessionID = envelope.sessionID,
              let encapsulatedKey = envelope.encapsulatedKey,
              let sequence = envelope.sequence,
              let ciphertext = envelope.ciphertext
        else { throw RemoteProtocolError.authenticationFailed }
        let peer = gateway.consumePeerIdentifier(
            handshakeID: sessionID,
            fallback: peerIdentifier
        )
        guard !gateway.shouldRejectAuthentication(peer: peer),
              let device = gateway.lookupDevice(id: deviceID, peer: peer)
        else { throw RemoteProtocolError.authenticationFailed }

        let devicePublicKey = try RemoteCrypto.publicKey(rawRepresentation: device.publicKey)
        var decryptor = try RemoteCrypto.gatewaySessionRecipient(
            gatewayPrivateKey: identity.privateKey,
            devicePublicKey: devicePublicKey,
            sessionID: sessionID,
            encapsulatedKey: encapsulatedKey
        )
        let hello = try JSONDecoder().decode(
            RemoteSessionHello.self,
            from: decryptor.open(sequence: sequence, ciphertext: ciphertext)
        )
        guard hello.protocolVersion == RemoteProtocolVersion.current else {
            throw RemoteProtocolError.unsupportedVersion
        }

        var encryptor = try RemoteCrypto.gatewaySessionSender(
            gatewayPrivateKey: identity.privateKey,
            devicePublicKey: devicePublicKey,
            sessionID: sessionID
        )
        let welcome = RemoteSessionWelcome(
            gatewayID: identity.gatewayID,
            protocolVersion: RemoteProtocolVersion.current
        )
        let sealed = try encryptor.seal(try JSONEncoder().encode(welcome))
        self.deviceID = deviceID
        self.sessionID = sessionID
        self.decryptor = decryptor
        self.encryptor = encryptor
        authenticationTimeout?.cancel()
        authenticationTimeout = nil
        gateway.activateDeviceSession(id: deviceID, connection: self)
        send(RemoteWireEnvelope(
            kind: .sessionWelcome,
            deviceID: deviceID,
            sessionID: sessionID,
            encapsulatedKey: encryptor.encapsulatedKey,
            sequence: sealed.sequence,
            ciphertext: sealed.ciphertext
        ))
    }

    private func handle(_ message: RemoteMessage) {
        switch message.kind {
        case .request:
            guard let request = message.request else {
                sendError(id: message.id, code: "invalid_request")
                return
            }
            guard requestTasks.count < 16 else {
                sendError(id: message.id, code: "too_many_requests")
                return
            }
            let task = Task { [weak self] in
                guard let self else { return }
                do {
                    let response = try await forwarder.perform(request)
                    queue.async { [weak self] in
                        self?.requestTasks.removeValue(forKey: message.id)
                        self?.sendEncrypted(RemoteMessage(kind: .response, id: message.id, response: response))
                    }
                } catch {
                    queue.async { [weak self] in
                        self?.requestTasks.removeValue(forKey: message.id)
                        self?.sendError(id: message.id, code: "request_failed")
                    }
                }
            }
            requestTasks[message.id] = task

        case .subscribeEvents:
            guard let request = message.request else {
                sendError(id: message.id, code: "invalid_stream")
                return
            }
            guard eventStreams.count < 2 || eventStreams[message.id] != nil else {
                sendError(id: message.id, code: "too_many_streams")
                return
            }
            do {
                let stream = try forwarder.makeEventStream(
                    request: request,
                    deliveryQueue: queue,
                    onOpened: { [weak self] statusCode, headers in
                        self?.sendEncrypted(RemoteMessage(
                            kind: .eventOpened,
                            id: message.id,
                            response: RemoteHTTPResponse(statusCode: statusCode, headers: headers, body: Data()),
                            statusCode: statusCode
                        ))
                    },
                    onData: { [weak self] data in
                        self?.sendEncrypted(RemoteMessage(kind: .eventData, id: message.id, payload: data))
                    },
                    onComplete: { [weak self] error in
                        self?.eventStreams.removeValue(forKey: message.id)
                        self?.sendEncrypted(RemoteMessage(
                            kind: .eventCompleted,
                            id: message.id,
                            errorCode: error == nil ? nil : "stream_closed"
                        ))
                    }
                )
                eventStreams[message.id]?.cancel()
                eventStreams[message.id] = stream
                stream.start()
            } catch {
                sendError(id: message.id, code: "stream_failed")
            }

        case .unsubscribeEvents:
            eventStreams.removeValue(forKey: message.id)?.cancel()

        case .ping:
            sendEncrypted(RemoteMessage(kind: .pong, id: message.id))

        case .sessionHello, .sessionWelcome, .response, .eventOpened, .eventData,
             .eventCompleted, .pong, .error:
            break
        }
    }

    private func sendError(id: String, code: String) {
        sendEncrypted(RemoteMessage(kind: .error, id: id, errorCode: code))
    }

    private func sendEncrypted(_ message: RemoteMessage) {
        guard let deviceID, let sessionID, var encryptor else {
            close()
            return
        }
        do {
            let sealed = try encryptor.seal(try message.encoded())
            self.encryptor = encryptor
            send(RemoteWireEnvelope(
                kind: .encrypted,
                deviceID: deviceID,
                sessionID: sessionID,
                sequence: sealed.sequence,
                ciphertext: sealed.ciphertext
            ))
        } catch {
            close()
        }
    }

    private func rejectAndClose() {
        send(RemoteWireEnvelope(kind: .rejected, errorCode: "rejected"), closeAfterSending: true)
    }

    private func send(_ envelope: RemoteWireEnvelope, closeAfterSending: Bool = false) {
        do {
            let data = try envelope.encoded()
            let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
            let context = NWConnection.ContentContext(
                identifier: "openlens-remote-frame",
                metadata: [metadata]
            )
            networkConnection.send(
                content: data,
                contentContext: context,
                isComplete: true,
                completion: .contentProcessed { [weak self] error in
                    guard let self else { return }
                    if error != nil || closeAfterSending { close() }
                }
            )
        } catch {
            close()
        }
    }

    private func close() {
        guard !isClosed else { return }
        isClosed = true
        authenticationTimeout?.cancel()
        authenticationTimeout = nil
        requestTasks.values.forEach { $0.cancel() }
        requestTasks.removeAll()
        eventStreams.values.forEach { $0.cancel() }
        eventStreams.removeAll()
        networkConnection.cancel()
        gateway.removeConnection(self)
    }

    private var peerIdentifier: String {
        switch networkConnection.endpoint {
        case .hostPort(let host, _): String(describing: host)
        default: String(describing: networkConnection.endpoint)
        }
    }
}

private extension Data {
    func constantTimeEquals(_ other: Data) -> Bool {
        guard count == other.count else { return false }
        return zip(self, other).reduce(UInt8(0)) { partial, pair in
            partial | (pair.0 ^ pair.1)
        } == 0
    }
}
