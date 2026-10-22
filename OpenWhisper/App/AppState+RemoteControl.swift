import Foundation

extension AppState {
    func setupRemoteControl() {
        remoteControl.onChange = { [weak self] in self?.updateWakeWordListener() }
        updateRemoteControl()
    }

    /// The Mac is held awake only while "Jarvis" listens: without the listener nothing would use it.
    func updateRemoteControl() {
        remoteControl.setEnabled(remoteControlEnabled && wakeWordEnabled)
    }
}
