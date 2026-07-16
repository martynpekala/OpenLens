import CryptoKit
import Foundation

nonisolated enum RemoteCrypto {
    static let ciphersuite = HPKE.Ciphersuite.Curve25519_SHA256_ChachaPoly

    static func makeIdentity() -> Curve25519.KeyAgreement.PrivateKey {
        Curve25519.KeyAgreement.PrivateKey()
    }

    static func privateKey(rawRepresentation: Data) throws -> Curve25519.KeyAgreement.PrivateKey {
        try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: rawRepresentation)
    }

    static func publicKey(rawRepresentation: Data) throws -> Curve25519.KeyAgreement.PublicKey {
        try Curve25519.KeyAgreement.PublicKey(rawRepresentation: rawRepresentation)
    }

    static func fingerprint(publicKey: Data) -> String {
        SHA256.hash(data: publicKey)
            .prefix(12)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func pairingSender(
        gatewayPublicKey: Curve25519.KeyAgreement.PublicKey,
        pairingID: String
    ) throws -> RemoteEncryptor {
        let info = contextInfo(scope: "pair", identifier: pairingID, direction: "device-to-gateway")
        let sender = try HPKE.Sender(
            recipientKey: gatewayPublicKey,
            ciphersuite: ciphersuite,
            info: info
        )
        return RemoteEncryptor(sender: sender, associatedDataPrefix: info)
    }

    static func pairingRecipient(
        gatewayPrivateKey: Curve25519.KeyAgreement.PrivateKey,
        pairingID: String,
        encapsulatedKey: Data
    ) throws -> RemoteDecryptor {
        let info = contextInfo(scope: "pair", identifier: pairingID, direction: "device-to-gateway")
        let recipient = try HPKE.Recipient(
            privateKey: gatewayPrivateKey,
            ciphersuite: ciphersuite,
            info: info,
            encapsulatedKey: encapsulatedKey
        )
        return RemoteDecryptor(recipient: recipient, associatedDataPrefix: info)
    }

    static func pairingResponseSender(
        devicePublicKey: Curve25519.KeyAgreement.PublicKey,
        gatewayPrivateKey: Curve25519.KeyAgreement.PrivateKey,
        pairingID: String
    ) throws -> RemoteEncryptor {
        let info = contextInfo(scope: "pair", identifier: pairingID, direction: "gateway-to-device")
        let sender = try HPKE.Sender(
            recipientKey: devicePublicKey,
            ciphersuite: ciphersuite,
            info: info,
            authenticatedBy: gatewayPrivateKey
        )
        return RemoteEncryptor(sender: sender, associatedDataPrefix: info)
    }

    static func pairingResponseRecipient(
        devicePrivateKey: Curve25519.KeyAgreement.PrivateKey,
        gatewayPublicKey: Curve25519.KeyAgreement.PublicKey,
        pairingID: String,
        encapsulatedKey: Data
    ) throws -> RemoteDecryptor {
        let info = contextInfo(scope: "pair", identifier: pairingID, direction: "gateway-to-device")
        let recipient = try HPKE.Recipient(
            privateKey: devicePrivateKey,
            ciphersuite: ciphersuite,
            info: info,
            encapsulatedKey: encapsulatedKey,
            authenticatedBy: gatewayPublicKey
        )
        return RemoteDecryptor(recipient: recipient, associatedDataPrefix: info)
    }

    static func deviceSessionSender(
        devicePrivateKey: Curve25519.KeyAgreement.PrivateKey,
        gatewayPublicKey: Curve25519.KeyAgreement.PublicKey,
        sessionID: String
    ) throws -> RemoteEncryptor {
        let info = contextInfo(scope: "session", identifier: sessionID, direction: "device-to-gateway")
        let sender = try HPKE.Sender(
            recipientKey: gatewayPublicKey,
            ciphersuite: ciphersuite,
            info: info,
            authenticatedBy: devicePrivateKey
        )
        return RemoteEncryptor(sender: sender, associatedDataPrefix: info)
    }

    static func gatewaySessionRecipient(
        gatewayPrivateKey: Curve25519.KeyAgreement.PrivateKey,
        devicePublicKey: Curve25519.KeyAgreement.PublicKey,
        sessionID: String,
        encapsulatedKey: Data
    ) throws -> RemoteDecryptor {
        let info = contextInfo(scope: "session", identifier: sessionID, direction: "device-to-gateway")
        let recipient = try HPKE.Recipient(
            privateKey: gatewayPrivateKey,
            ciphersuite: ciphersuite,
            info: info,
            encapsulatedKey: encapsulatedKey,
            authenticatedBy: devicePublicKey
        )
        return RemoteDecryptor(recipient: recipient, associatedDataPrefix: info)
    }

    static func gatewaySessionSender(
        gatewayPrivateKey: Curve25519.KeyAgreement.PrivateKey,
        devicePublicKey: Curve25519.KeyAgreement.PublicKey,
        sessionID: String
    ) throws -> RemoteEncryptor {
        let info = contextInfo(scope: "session", identifier: sessionID, direction: "gateway-to-device")
        let sender = try HPKE.Sender(
            recipientKey: devicePublicKey,
            ciphersuite: ciphersuite,
            info: info,
            authenticatedBy: gatewayPrivateKey
        )
        return RemoteEncryptor(sender: sender, associatedDataPrefix: info)
    }

    static func deviceSessionRecipient(
        devicePrivateKey: Curve25519.KeyAgreement.PrivateKey,
        gatewayPublicKey: Curve25519.KeyAgreement.PublicKey,
        sessionID: String,
        encapsulatedKey: Data
    ) throws -> RemoteDecryptor {
        let info = contextInfo(scope: "session", identifier: sessionID, direction: "gateway-to-device")
        let recipient = try HPKE.Recipient(
            privateKey: devicePrivateKey,
            ciphersuite: ciphersuite,
            info: info,
            encapsulatedKey: encapsulatedKey,
            authenticatedBy: gatewayPublicKey
        )
        return RemoteDecryptor(recipient: recipient, associatedDataPrefix: info)
    }

    private static func contextInfo(scope: String, identifier: String, direction: String) -> Data {
        Data("openlens-remote-v1|\(scope)|\(identifier)|\(direction)".utf8)
    }
}

nonisolated struct RemoteEncryptor: Sendable {
    private var sender: HPKE.Sender
    private let associatedDataPrefix: Data
    private(set) var nextSequence: UInt64 = 0

    var encapsulatedKey: Data {
        sender.encapsulatedKey
    }

    init(sender: HPKE.Sender, associatedDataPrefix: Data) {
        self.sender = sender
        self.associatedDataPrefix = associatedDataPrefix
    }

    mutating func seal(_ plaintext: Data) throws -> (sequence: UInt64, ciphertext: Data) {
        let sequence = nextSequence
        let ciphertext = try sender.seal(plaintext, authenticating: associatedData(for: sequence))
        nextSequence &+= 1
        return (sequence, ciphertext)
    }

    private func associatedData(for sequence: UInt64) -> Data {
        var data = associatedDataPrefix
        var bigEndianSequence = sequence.bigEndian
        withUnsafeBytes(of: &bigEndianSequence) { data.append(contentsOf: $0) }
        return data
    }
}

nonisolated struct RemoteDecryptor: Sendable {
    private var recipient: HPKE.Recipient
    private let associatedDataPrefix: Data
    private(set) var expectedSequence: UInt64 = 0

    init(recipient: HPKE.Recipient, associatedDataPrefix: Data) {
        self.recipient = recipient
        self.associatedDataPrefix = associatedDataPrefix
    }

    mutating func open(sequence: UInt64, ciphertext: Data) throws -> Data {
        guard sequence == expectedSequence else {
            throw RemoteProtocolError.replayDetected
        }
        do {
            let plaintext = try recipient.open(ciphertext, authenticating: associatedData(for: sequence))
            expectedSequence &+= 1
            return plaintext
        } catch let error as RemoteProtocolError {
            throw error
        } catch {
            throw RemoteProtocolError.authenticationFailed
        }
    }

    private func associatedData(for sequence: UInt64) -> Data {
        var data = associatedDataPrefix
        var bigEndianSequence = sequence.bigEndian
        withUnsafeBytes(of: &bigEndianSequence) { data.append(contentsOf: $0) }
        return data
    }
}
