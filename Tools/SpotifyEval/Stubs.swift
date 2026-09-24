import Foundation

// Stand-ins for the app-target symbols the Spotify sources call (defined next to `@main`
// in OpenWhisper/App/OpenWhisperApp.swift, which a standalone tool can't link against).
func owLog(_ msg: String) {}

enum OpenWhisperNotification {
    static func post(title: String, body: String, isError: Bool = false, identifierPrefix: String = "openwhisper") {}
}
