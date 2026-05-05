import Foundation

struct OpenLensQRPayloadModel: Codable, Equatable {
    let deepLink: String
    let serverURL: String
    let username: String
    let generatedAt: Date
}
