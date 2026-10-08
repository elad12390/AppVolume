// Renders the README demo: the real mixer views with sample apps, animated frame by frame.
// Built by scripts/make-demo.sh together with the app sources (minus the @main entry point).
import AppKit
import SwiftUI

// MARK: - Scene

struct DemoApp {
    let name: String
    let iconPath: String
    var volume: Float = 1
    var muted = false
    var playing = false
}

struct DemoState {
    var apps: [DemoApp]
    var device: Float = 0.6
    var hovered: String?
}

func icon(_ path: String) -> NSImage {
    FileManager.default.fileExists(atPath: path) ? NSWorkspace.shared.icon(forFile: path)
        : NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil)!
}

struct Scene: View {
    let state: DemoState
    let panelHeight: CGFloat

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.16, green: 0.12, blue: 0.36), Color(red: 0.05, green: 0.25, blue: 0.45)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(alignment: .trailing, spacing: 6) {
                MenuBar()
                panel
                    .padding(.trailing, 28)
            }
        }
    }

    private var panel: some View {
        MixerView(
            deviceName: "MacBook Pro Speakers",
            error: nil,
            isBoosting: state.apps.contains { $0.volume > 1.001 && !$0.muted },
            canReset: state.apps.contains { $0.volume != 1 || $0.muted },
            onDismissError: {}, onReset: {}, onQuit: {},
            device: {
                ChannelStrip(name: "MacBook Pro Speakers", volume: state.device, maxValue: 1, isMuted: false,
                             isEnabled: true, canMute: true, isPlaying: false, isAdjusted: false,
                             onVolume: { _ in }, onToggleMute: {}, onReset: {}) { DeviceIcon() }
            },
            apps: state.apps.map { app in
                ChannelStrip(name: app.name, volume: app.volume, maxValue: 2, isMuted: app.muted,
                             isEnabled: true, canMute: true, isPlaying: app.playing,
                             isAdjusted: app.volume != 1 || app.muted,
                             onVolume: { _ in }, onToggleMute: {}, onReset: {}) {
                    Image(nsImage: icon(app.iconPath)).resizable().scaledToFit()
                }
            }
        )
        .environment(\.previewHoveredChannel, state.hovered)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(white: 0.16)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.12), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.45), radius: 24, y: 10)
        .frame(height: panelHeight, alignment: .top)
    }
}

struct MenuBar: View {
    var body: some View {
        HStack(spacing: 16) {
            Spacer()
            Image(systemName: "slider.vertical.3")
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.22)))
            Image(systemName: "wifi")
            Image(systemName: "battery.75percent")
            Image(systemName: "magnifyingglass")
            Text("Thu 9:41")
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .frame(height: 28)
        .background(Color.black.opacity(0.28))
    }
}

// MARK: - Timeline

func ease(_ t: Double) -> Float { Float(t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2) }

let fps = 20.0
var base = DemoState(apps: [
    DemoApp(name: "Music", iconPath: "/System/Applications/Music.app", playing: true),
    DemoApp(name: "Discord", iconPath: "/Applications/Discord.app", playing: true),
    DemoApp(name: "Google Chrome", iconPath: "/Applications/Google Chrome.app", playing: true),
    DemoApp(name: "Slack", iconPath: "/Applications/Slack.app"),
    DemoApp(name: "Telegram", iconPath: "/Applications/Telegram.app"),
])

/// (duration in seconds, frame builder given progress 0...1)
var steps: [(Double, (Double) -> DemoState)] = []
func hold(_ d: Double, hovered: String? = nil) {
    let s = base
    steps.append((d, { _ in var x = s; x.hovered = hovered; return x }))
}
func drag(_ index: Int, to target: Float, over d: Double) {
    let s = base
    let from = s.apps[index].volume
    steps.append((d, { p in var x = s; x.hovered = s.apps[index].name; x.apps[index].volume = from + (target - from) * ease(p); return x }))
    base.apps[index].volume = target
}
func dragDevice(to target: Float, over d: Double) {
    let s = base
    let from = s.device
    steps.append((d, { p in var x = s; x.device = from + (target - from) * ease(p); return x }))
    base.device = target
}

hold(1.0)
hold(0.4, hovered: "Music")
drag(0, to: 0.35, over: 1.1)            // turn the music down for a call
hold(0.6, hovered: "Music")
hold(0.4, hovered: "Slack")
base.apps[3].muted = true               // silence Slack pings
hold(0.9, hovered: "Slack")
hold(0.3, hovered: "Discord")
drag(1, to: 1.45, over: 1.1)            // boost a quiet friend
hold(1.6, hovered: "Discord")
dragDevice(to: 0.45, over: 0.8)
hold(1.2)

// MARK: - Render

MainActor.assumeIsolated {
    _ = NSApplication.shared
    let out = CommandLine.arguments[1]
    let size = NSSize(width: 640, height: 520)
    let host = NSHostingView(rootView: AnyView(EmptyView()))
    host.appearance = NSAppearance(named: .darkAqua)
    host.frame = NSRect(origin: .zero, size: size)
    let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.appearance = host.appearance
    window.contentView = host

    var frame = 0
    for (duration, build) in steps {
        let count = max(Int((duration * fps).rounded()), 1)
        for i in 0..<count {
            let state = build(count == 1 ? 1 : Double(i) / Double(count - 1))
            host.rootView = AnyView(Scene(state: state, panelHeight: 440).frame(width: size.width, height: size.height))
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: rep)
            let url = URL(fileURLWithPath: out).appendingPathComponent(String(format: "f%04d.png", frame))
            try! rep.representation(using: .png, properties: [:])!.write(to: url)
            frame += 1
        }
    }
    print("rendered \(frame) frames")

    // Static screenshots for the README, light and dark.
    for (name, appearance) in [("screenshot-dark", NSAppearance.Name.darkAqua), ("screenshot-light", .aqua)] {
        var state = base
        state.hovered = nil
        let bg: Color = appearance == .darkAqua ? Color(white: 0.16) : Color(white: 0.95)
        let view = NSHostingView(rootView: Scene(state: state, panelHeight: 440).panelOnly(bg))
        view.appearance = NSAppearance(named: appearance)
        view.frame = NSRect(origin: .zero, size: view.fittingSize)
        let w = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.appearance = view.appearance
        w.contentView = view
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        try! rep.representation(using: .png, properties: [:])!
            .write(to: URL(fileURLWithPath: CommandLine.arguments[2]).appendingPathComponent("\(name).png"))
    }
}

extension Scene {
    func panelOnly(_ bg: Color) -> some View {
        MixerView(
            deviceName: "MacBook Pro Speakers", error: nil,
            isBoosting: state.apps.contains { $0.volume > 1.001 && !$0.muted },
            canReset: true, onDismissError: {}, onReset: {}, onQuit: {},
            device: {
                ChannelStrip(name: "MacBook Pro Speakers", volume: state.device, maxValue: 1, isMuted: false,
                             isEnabled: true, canMute: true, isPlaying: false, isAdjusted: false,
                             onVolume: { _ in }, onToggleMute: {}, onReset: {}) { DeviceIcon() }
            },
            apps: state.apps.map { app in
                ChannelStrip(name: app.name, volume: app.volume, maxValue: 2, isMuted: app.muted,
                             isEnabled: true, canMute: true, isPlaying: app.playing,
                             isAdjusted: app.volume != 1 || app.muted,
                             onVolume: { _ in }, onToggleMute: {}, onReset: {}) {
                    Image(nsImage: icon(app.iconPath)).resizable().scaledToFit()
                }
            }
        )
        .background(bg)
    }
}
