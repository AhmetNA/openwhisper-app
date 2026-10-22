import Foundation

extension AppState {
    func setupRemoteControl() {
        remoteControl.onChange = { [weak self] in self?.updateWakeWordListener() }
        updateRemoteControl()
    }

    /// Display asleep with the Mac awake (remote control, or media playing): the work only the
    /// screen needs slows down or stops. Called with every listener update; acts on changes.
    func updateDisplayAsleepWork() {
        let asleep = screensAsleep && !systemAsleep
        guard asleep != displayAsleepWorkReduced else { return }
        displayAsleepWorkReduced = asleep
        wakeWordListener?.setLowPower(asleep)
        mediaActivityMonitor?.setDisplayAsleep(asleep)
        remoteControl.logPower(displayAsleep: asleep)
        owLog(asleep ? "[Power] Display asleep: speech detector only on sound, media checked every \(Int(SystemMediaActivityMonitor.displayAsleepPollInterval)) s"
                     : "[Power] Display awake: full listening")
    }

    /// The Mac is held awake only while "Jarvis" listens: without the listener nothing would use it.
    func updateRemoteControl() {
        remoteControl.setEnabled(remoteControlEnabled && wakeWordEnabled)
    }
}
