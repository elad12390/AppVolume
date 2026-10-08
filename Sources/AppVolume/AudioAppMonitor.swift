import AppKit
import CoreAudio

struct AudioApp: Identifiable, Equatable {
    let id: String
    var name: String
    var bundleID: String?
    var icon: NSImage?
    var processObjectIDs: [AudioObjectID]   // sorted ascending
    var isPlaying: Bool

    /// Compares the icon only by presence: NSImage compares by identity, so fresh instances would look like a change on every refresh.
    static func == (lhs: AudioApp, rhs: AudioApp) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.bundleID == rhs.bundleID
            && lhs.processObjectIDs == rhs.processObjectIDs && lhs.isPlaying == rhs.isPlaying
            && (lhs.icon == nil) == (rhs.icon == nil)
    }
}

@MainActor final class AudioAppMonitor {
    private(set) var apps: [AudioApp] = []
    var onChange: (([AudioApp]) -> Void)?
    /// Keeps a group whose key matches even when it is neither a regular app nor playing.
    var shouldRetain: ((String) -> Bool)?

    private var started = false
    private var refreshScheduled = false
    private var systemListener: PropertyListener?
    private var processListeners: [AudioObjectID: PropertyListener] = [:]
    private var workspaceObservers: [NSObjectProtocol] = []

    private struct Group {
        var name: String
        var bundleID: String?
        var icon: NSImage?
        var resolved: Bool              // grouped under a .regular app
        var objects: [AudioObjectID] = []
        var isPlaying = false
    }

    func start() {
        guard !started else { return }
        started = true
        // Register before the first read so a change in between still triggers a refresh.
        systemListener = try? PropertyListener(object: .system, selector: kAudioHardwarePropertyProcessObjectList, queue: .main) { [weak self] in
            MainActor.assumeIsolated { self?.scheduleRefresh() }
        }
        // Launch and quit can change the regular-app grouping without any Core Audio change.
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers = [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification].map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleRefresh() }
            }
        }
        refresh()
    }

    func stop() {
        started = false
        systemListener?.cancel()
        systemListener = nil
        processListeners.values.forEach { $0.cancel() }
        processListeners.removeAll()
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceObservers.removeAll()
    }

    /// Coalesces a burst of listener callbacks into one refresh on the next main-queue turn.
    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refreshScheduled = false
                if self.started { self.refresh() }
            }
        }
    }

    func refresh() {
        guard let objects = try? AudioSystem.processObjectIDs() else { return }   // keep last snapshot on failure
        let me = getpid()
        let probed = objects.map { ($0, AudioSystem.processInfo($0)) }
        // Our own process object changes with every IOProc start and stop, so it gets no listener. Unreadable ones are retried.
        if started { syncProcessListeners(probed.filter { $0.1?.pid != me }.map { $0.0 }) }
        let infos = probed.compactMap { $0.1 }.filter { $0.pid != me }
        let next = regroup(infos)
        guard next != apps else { return }
        apps = next
        onChange?(next)
    }

    private func syncProcessListeners(_ objects: [AudioObjectID]) {
        let live = Set(objects)
        for id in processListeners.keys where !live.contains(id) {
            processListeners.removeValue(forKey: id)?.cancel()
        }
        for id in live where processListeners[id] == nil {
            processListeners[id] = try? PropertyListener(object: id, selector: kAudioProcessPropertyIsRunningOutput, queue: .main) { [weak self] in
                MainActor.assumeIsolated { self?.scheduleRefresh() }
            }
        }
    }

    private func regroup(_ infos: [AudioProcessInfo]) -> [AudioApp] {
        let regular = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        var groups: [String: Group] = [:]
        for info in infos {
            let running = NSRunningApplication(processIdentifier: info.pid)
            // Rule 1: the process is a regular app. Rule 2: longest regular-app bundle ID prefix.
            let parent = running?.activationPolicy == .regular ? running : Self.parent(of: info.bundleID, in: regular)
            let key: String
            var group: Group
            if let parent {
                key = parent.bundleIdentifier ?? "pid:\(parent.processIdentifier)"
                group = groups[key] ?? Group(name: parent.localizedName ?? key, bundleID: parent.bundleIdentifier, icon: parent.icon, resolved: true)
            } else {
                // Rule 3: own identity.
                key = info.bundleID ?? "pid:\(info.pid)"
                group = groups[key] ?? Group(name: running?.localizedName ?? info.bundleID ?? "Process \(info.pid)",
                                             bundleID: info.bundleID, icon: running?.icon, resolved: false)
            }
            group.objects.append(info.objectID)
            group.isPlaying = group.isPlaying || info.isRunningOutput
            groups[key] = group
        }
        return groups
            .filter { $0.value.resolved || $0.value.isPlaying || shouldRetain?($0.key) == true }
            .map { AudioApp(id: $0.key, name: $0.value.name, bundleID: $0.value.bundleID, icon: $0.value.icon,
                            processObjectIDs: $0.value.objects.sorted(), isPlaying: $0.value.isPlaying) }
            .sorted { a, b in   // playing first, then name, then id (deterministic order, so equality is stable)
                if a.isPlaying != b.isPlaying { return a.isPlaying }
                let order = a.name.localizedCaseInsensitiveCompare(b.name)
                return order == .orderedSame ? a.id < b.id : order == .orderedAscending
            }
    }

    /// Longest regular-app bundle ID equal to `bundleID` or a dot-boundary prefix of it.
    private static func parent(of bundleID: String?, in regular: [NSRunningApplication]) -> NSRunningApplication? {
        guard let bundleID else { return nil }
        return regular
            .filter { app in app.bundleIdentifier.map { bundleID == $0 || bundleID.hasPrefix($0 + ".") } ?? false }
            .max { ($0.bundleIdentifier?.count ?? 0) < ($1.bundleIdentifier?.count ?? 0) }
    }
}
