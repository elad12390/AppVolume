import AppKit
import AudioToolbox
import CoreAudio
import Observation

/// Owns the per-app settings and the taps that apply them. Main actor only.
@MainActor @Observable final class VolumeController {
    struct OutputDevice: Equatable {
        var name: String
        var volume: Float?   // nil when the device has no settable volume (e.g. HDMI, some USB DACs)
        var muted: Bool?     // nil when the device has no settable mute
    }

    struct Setting: Codable, Equatable {
        var volume: Float = 1
        var muted = false
        var isDefault: Bool { abs(volume - 1) < 0.001 && !muted }
    }

    private(set) var apps: [AudioApp] = []
    private(set) var lastError: String?
    /// The default output device, shown as the mixer's "Device" channel. nil when it can't be read.
    private(set) var outputDevice: OutputDevice?
    /// Tracked on purpose: the view's slider and mute bindings read it.
    private var settings: [String: Setting] = [:]

    @ObservationIgnored private var taps: [String: AppTap] = [:]
    /// Builds that failed, so an unchanged app is not rebuilt on every slider tick or monitor refresh.
    @ObservationIgnored private var failedBuilds: [String: (processObjectIDs: [AudioObjectID], device: AudioObjectID)] = [:]
    @ObservationIgnored private let monitor = AudioAppMonitor()
    @ObservationIgnored private var defaultDeviceListener: PropertyListener?
    @ObservationIgnored private var terminateObserver: NSObjectProtocol?
    @ObservationIgnored private var deviceChangePending = false
    @ObservationIgnored private var outputDeviceID = AudioObjectID.unknown
    @ObservationIgnored private var outputDeviceListeners: [PropertyListener] = []

    private static let defaultsKey = "AppVolume.settings"

    init() {
        // Order matters: the first reconcile (inside monitor.start) can build taps,
        // so the device listener and terminate observer must already be in place.
        settings = Self.loadSettings()
        bindOutputDevice()
        do {
            defaultDeviceListener = try PropertyListener(object: .system, selector: kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in
                MainActor.assumeIsolated { self?.scheduleDeviceRebuild() }
            }
        } catch {
            lastError = "Couldn't watch the default output device: \(describe(error))"
        }
        terminateObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.invalidateAllTaps() }
        }
        monitor.onChange = { [weak self] apps in self?.reconcile(apps) }
        // A group that is not a regular app and not playing stays listed while it has a setting, so its tap survives pauses.
        monitor.shouldRetain = { [weak self] id in self?.settings[id] != nil }
        monitor.start()
    }

    func volume(for app: AudioApp) -> Float { settings[app.id]?.volume ?? 1 }

    func isMuted(_ app: AudioApp) -> Bool { settings[app.id]?.muted ?? false }

    func isAdjusted(_ app: AudioApp) -> Bool { settings[app.id] != nil }

    var hasAdjustments: Bool { !settings.isEmpty }

    /// True while any listed app is boosted above 100%, which can distort.
    var isBoosting: Bool { apps.contains { app in settings[app.id].map { $0.volume > 1.001 && !$0.muted } ?? false } }

    /// Back to 100% and unmuted, which removes the app's tap.
    func reset(_ app: AudioApp) {
        update(app) { $0 = Setting() }
    }

    func setVolume(_ volume: Float, for app: AudioApp) {
        guard volume.isFinite else { return }
        update(app) { $0.volume = min(max(volume, 0), AppTap.maxGain) }
    }

    func toggleMute(_ app: AudioApp) {
        update(app) { $0.muted.toggle() }
    }

    func setDeviceVolume(_ volume: Float) {
        guard volume.isFinite, outputDevice?.volume != nil else { return }
        let v = min(max(volume, 0), 1)
        outputDevice?.volume = v   // immediate UI; the listener confirms
        try? outputDeviceID.write(Self.mainVolume, scope: Self.output, Float32(v))
    }

    func toggleDeviceMute() {
        guard let muted = outputDevice?.muted else { return }
        outputDevice?.muted = !muted
        try? outputDeviceID.write(kAudioDevicePropertyMute, scope: Self.output, UInt32(muted ? 0 : 1))
    }

    func resetAll() {
        settings = [:]
        save()
        invalidateAllTaps()
        failedBuilds = [:]
        lastError = nil
        monitor.refresh()   // drops groups that were listed only because they had a setting
    }

    func dismissError() {
        lastError = nil
        failedBuilds = [:]  // dismissing is the cue to retry: the next change to an app builds again
    }

    // MARK: - Settings

    private func update(_ app: AudioApp, _ change: (inout Setting) -> Void) {
        let wasStored = settings[app.id] != nil
        var setting = settings[app.id] ?? Setting()
        change(&setting)
        settings[app.id] = setting.isDefault ? nil : setting
        save()
        if wasStored != (settings[app.id] != nil) { monitor.refresh() }
        // The Binding may hold a stale AudioApp snapshot, so apply the fresh entry.
        if let current = apps.first(where: { $0.id == app.id }) { apply(current) }
    }

    // MARK: - Taps

    private func apply(_ app: AudioApp) {
        let setting = settings[app.id] ?? Setting()
        if setting.isDefault {
            removeTap(for: app.id)
            failedBuilds[app.id] = nil
            return
        }
        let gain: Float = setting.muted ? 0 : setting.volume
        let existing = taps[app.id]
        let device: AudioObjectID
        do {
            device = try AudioSystem.defaultOutputDevice()
        } catch {
            existing?.gain = gain
            lastError = "Couldn't read the output device: \(describe(error))"
            return
        }
        // Slider path: same processes on the same device only changes the gain, never a rebuild.
        if let existing, existing.processObjectIDs == app.processObjectIDs, existing.outputDeviceID == device {
            existing.gain = gain
            return
        }
        // A failed build is retried only when the processes or the device change, or after the error is dismissed.
        if let failed = failedBuilds[app.id], failed.processObjectIDs == app.processObjectIDs, failed.device == device { return }
        removeTap(for: app.id)
        do {
            taps[app.id] = try AppTap(processObjectIDs: app.processObjectIDs, outputDeviceID: device, name: app.name, gain: gain)
            failedBuilds[app.id] = nil
        } catch {
            failedBuilds[app.id] = (app.processObjectIDs, device)
            lastError = "Couldn't change \(app.name): \(describe(error))"
        }
    }

    private func reconcile(_ newApps: [AudioApp]) {
        apps = newApps
        let live = Set(newApps.map(\.id))
        for id in taps.keys.filter({ !live.contains($0) }) { removeTap(for: id) }
        failedBuilds = failedBuilds.filter { live.contains($0.key) }
        for app in newApps { apply(app) }
    }

    /// Coalesces bursts of default-device notifications into one rebuild on the next main-queue turn.
    private func scheduleDeviceRebuild() {
        guard !deviceChangePending else { return }
        deviceChangePending = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.deviceChangePending = false
                self.rebuildAllTaps()
            }
        }
    }

    private func rebuildAllTaps() {
        bindOutputDevice()
        lastError = nil   // a device change re-evaluates everything; any error still standing is set again by apply
        invalidateAllTaps()
        for app in apps { apply(app) }
    }

    // MARK: - Output device (master channel)

    private static let mainVolume = kAudioHardwareServiceDeviceProperty_VirtualMainVolume
    private static let output = kAudioObjectPropertyScopeOutput

    /// Follows the current default output device: re-reads it and listens for volume/mute changes made elsewhere.
    private func bindOutputDevice() {
        outputDeviceListeners.forEach { $0.cancel() }
        outputDeviceListeners = []
        guard let device = try? AudioSystem.defaultOutputDevice() else {
            outputDeviceID = .unknown
            outputDevice = nil
            return
        }
        outputDeviceID = device
        for selector in [Self.mainVolume, kAudioDevicePropertyMute] {
            let listener = try? PropertyListener(object: device, selector: selector, scope: Self.output) { [weak self] in
                MainActor.assumeIsolated { self?.readOutputDevice() }
            }
            if let listener { outputDeviceListeners.append(listener) }
        }
        readOutputDevice()
    }

    private func readOutputDevice() {
        let device = outputDeviceID
        guard device != .unknown else { outputDevice = nil; return }
        let volume: Float? = device.isSettable(Self.mainVolume, scope: Self.output)
            ? try? device.read(Self.mainVolume, scope: Self.output, default: Float32(0))
            : nil
        let muted: Bool? = device.isSettable(kAudioDevicePropertyMute, scope: Self.output)
            ? (try? device.read(kAudioDevicePropertyMute, scope: Self.output, default: UInt32(0))).map { $0 != 0 }
            : nil
        outputDevice = OutputDevice(name: (try? AudioSystem.deviceName(device)) ?? "Output",
                                    volume: volume, muted: muted)
    }

    private func removeTap(for id: String) {
        taps.removeValue(forKey: id)?.invalidate()
    }

    private func invalidateAllTaps() {
        for tap in taps.values { tap.invalidate() }
        taps.removeAll()
    }

    // MARK: - Persistence and errors

    private func save() {
        let stored = settings.filter { !$0.value.isDefault }
        if stored.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
            return
        }
        guard let data = try? JSONEncoder().encode(stored) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }

    private static func loadSettings() -> [String: Setting] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let stored = try? JSONDecoder().decode([String: Setting].self, from: data) else { return [:] }
        return stored.compactMapValues { s in
            var s = s
            s.volume = s.volume.isFinite ? min(max(s.volume, 0), AppTap.maxGain) : 1
            return s.isDefault ? nil : s
        }
    }

    private func describe(_ error: Error) -> String {
        (error as? CoreAudioError)?.description ?? error.localizedDescription
    }
}
