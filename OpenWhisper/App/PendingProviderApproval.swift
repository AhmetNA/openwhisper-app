import Foundation

/// A user-installed STT provider (manifest found under
/// `~/Library/Application Support/OpenWhisper/STTProviders`) that has not yet been explicitly
/// approved to run. Carries the resolved paths so Settings can show the user exactly what they'd
/// be authorizing before they approve it. `manifestPath` is always present -- it's just the
/// location the manifest was found at. `pythonPath`/`bridgePath` are nil when the security checks
/// in `ExternalSTTProvider.resolveRuntime()` rejected the manifest (bridge escapes its directory,
/// no allowlisted interpreter matched, etc.); such a provider still shows up here as rejected
/// rather than silently disappearing from Settings.
struct PendingProviderApproval: Identifiable, Sendable {
    let id: String
    let displayName: String
    let manifestPath: String
    let pythonPath: String?
    let bridgePath: String?
}
