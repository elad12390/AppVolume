import AppKit
import SwiftUI

/// Windows-style Volume Mixer: a "Device" channel for the output device, then one vertical channel per app.
struct ContentView: View {
    let controller: VolumeController

    var body: some View {
        let device = controller.outputDevice
        MixerView(
            deviceName: device?.name,
            error: controller.lastError,
            isBoosting: controller.isBoosting,
            canReset: controller.hasAdjustments,
            onDismissError: { controller.dismissError() },
            onReset: { withAnimation(.snappy) { controller.resetAll() } },
            onQuit: { NSApplication.shared.terminate(nil) },
            device: {
                ChannelStrip(
                    name: device?.name ?? "Output",
                    volume: device?.volume ?? 1,
                    maxValue: 1,
                    isMuted: device?.muted ?? false,
                    isEnabled: device?.volume != nil,
                    canMute: device?.muted != nil,
                    isPlaying: false,
                    isAdjusted: false,
                    onVolume: { controller.setDeviceVolume($0) },
                    onToggleMute: { controller.toggleDeviceMute() },
                    onReset: {}
                ) {
                    DeviceIcon()
                }
            },
            apps: controller.apps.map { app in
                ChannelStrip(
                    name: app.name,
                    volume: controller.volume(for: app),
                    maxValue: AppTap.maxGain,
                    isMuted: controller.isMuted(app),
                    isEnabled: true,
                    canMute: true,
                    isPlaying: app.isPlaying,
                    isAdjusted: controller.isAdjusted(app),
                    onVolume: { controller.setVolume($0, for: app) },
                    onToggleMute: { controller.toggleMute(app) },
                    onReset: { withAnimation(.snappy) { controller.reset(app) } }
                ) {
                    AppIcon(icon: app.icon)
                }
            }
        )
    }
}

/// Pure layout, so it can be rendered with sample data.
struct MixerView<Device: View, AppIconView: View>: View {
    let deviceName: String?
    let error: String?
    let isBoosting: Bool
    let canReset: Bool
    let onDismissError: () -> Void
    let onReset: () -> Void
    let onQuit: () -> Void
    @ViewBuilder let device: () -> Device
    let apps: [ChannelStrip<AppIconView>]

    private static var visibleApps: Int { 6 }
    @State private var scrollPosition = ScrollPosition(edge: .leading)
    @State private var scrollMetrics = ScrollMetrics()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TitleBar(deviceName: deviceName)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 8)

            if let error {
                ErrorBanner(message: error, onDismiss: onDismissError)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
            }

            if isBoosting {
                BoostNotice()
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    GroupLabel(title: "Device")
                    device()
                }
                .padding(.horizontal, 8)

                Divider().padding(.vertical, 6)

                VStack(alignment: .leading, spacing: 8) {
                    GroupLabel(title: "Applications")
                    if apps.isEmpty {
                        EmptyStateView()
                    } else {
                        // fixedSize: the menu window proposes a tiny size, which would collapse the ScrollView.
                        // Its ideal width is the content's, capped at `visibleApps` channels.
                        // The system overlay scroller first lays out as a vertical stub, so it is hidden
                        // and HorizontalScrollBar below draws the position instead.
                        ScrollView(.horizontal) {
                            HStack(alignment: .top, spacing: ChannelMetrics.spacing) {
                                ForEach(apps.indices, id: \.self) { apps[$0] }
                            }
                        }
                        .scrollIndicators(.never)
                        .scrollPosition($scrollPosition)
                        .onScrollGeometryChange(for: ScrollMetrics.self) { geo in
                            ScrollMetrics(offset: geo.contentOffset.x, content: geo.contentSize.width, visible: geo.containerSize.width)
                        } action: { _, metrics in
                            scrollMetrics = metrics
                        }
                        .frame(maxWidth: CGFloat(Self.visibleApps) * (ChannelMetrics.width + ChannelMetrics.spacing) - ChannelMetrics.spacing)
                        .fixedSize(horizontal: true, vertical: false)
                        .overlay(alignment: .bottom) {
                            if apps.count > Self.visibleApps {
                                HorizontalScrollBar(metrics: scrollMetrics) { scrollPosition.scrollTo(x: $0) }
                                    .padding(.horizontal, 6)
                                    .offset(y: 12)
                            }
                        }
                        .padding(.bottom, apps.count > Self.visibleApps ? 12 : 0)
                    }
                }
                .padding(.horizontal, 8)
            }
            .padding(.bottom, 10)

            Divider().padding(.horizontal, 12)

            HStack(spacing: 4) {
                FooterButton(title: "Reset All", systemImage: "arrow.counterclockwise", action: onReset)
                    .disabled(!canReset)
                Spacer(minLength: 0)
                FooterButton(title: "Quit", systemImage: "power", action: onQuit)
                    .keyboardShortcut("q")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .fixedSize()
        .animation(.snappy, value: isBoosting)
    }
}

// MARK: - Scrolling

struct ScrollMetrics: Equatable {
    var offset: CGFloat = 0
    var content: CGFloat = 0
    var visible: CGFloat = 0
    var maxOffset: CGFloat { max(content - visible, 0) }
}

/// Always-horizontal scrollbar: drag the knob, or click the track to jump there.
private struct HorizontalScrollBar: View {
    let metrics: ScrollMetrics
    let scrollTo: (CGFloat) -> Void
    @State private var hovering = false
    @State private var dragStart: CGFloat?

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let ratio = metrics.content > 0 ? min(metrics.visible / metrics.content, 1) : 1
            let knob = max(width * ratio, 28)
            let room = max(width - knob, 1)
            let x = metrics.maxOffset > 0 ? room * min(max(metrics.offset / metrics.maxOffset, 0), 1) : 0
            let thickness: CGFloat = hovering || dragStart != nil ? 7 : 5
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(hovering ? 0.08 : 0.05))
                    .frame(height: thickness)
                    .contentShape(Rectangle())
                    .onTapGesture { location in
                        let target = (location.x - knob / 2) / room
                        scrollTo(min(max(target, 0), 1) * metrics.maxOffset)
                    }
                Capsule()
                    .fill(Color.primary.opacity(dragStart != nil ? 0.45 : hovering ? 0.35 : 0.25))
                    .frame(width: knob, height: thickness)
                    .offset(x: x)
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            let start = dragStart ?? metrics.offset
                            dragStart = start
                            let target = start + drag.translation.width / room * metrics.maxOffset
                            scrollTo(min(max(target, 0), metrics.maxOffset))
                        }
                        .onEnded { _ in dragStart = nil })
            }
            .frame(height: geo.size.height)
            .animation(.easeOut(duration: 0.12), value: thickness)
        }
        .frame(height: 12)
        .onHover { hovering = $0 }
    }
}

// MARK: - Chrome

private struct BoostNotice: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("Above 100 the sound can distort or clip.")
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 11, weight: .medium))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.orange.opacity(0.12)))
    }
}

private struct TitleBar: View {
    let deviceName: String?

    var body: some View {
        HStack(spacing: 6) {
            Text("Volume Mixer")
                .font(.system(size: 13, weight: .semibold))
            if let deviceName {
                Text("–  \(deviceName)")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

private struct GroupLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, 6)
    }
}

private struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "speaker.zzz.fill")
                .font(.system(size: 24))
                .foregroundStyle(.tertiary)
            Text("No apps are\nusing audio")
                .font(.system(size: 11, weight: .medium))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .frame(width: ChannelMetrics.width * 2, height: ChannelMetrics.height)
    }
}

private struct FooterButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                Text(title)
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(hovering && isEnabled ? 0.08 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isEnabled ? .primary : .tertiary)
        .onHover { hovering = $0 }
    }
}

private struct ErrorBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(message)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Privacy Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.link)
                .font(.caption.weight(.medium))
            }
            Spacer(minLength: 0)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .frame(maxWidth: 420, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.14)))
    }
}

// MARK: - Channel strip

enum ChannelMetrics {
    static let width: CGFloat = 82
    static let inset: CGFloat = 12
    /// Natural strip height: insets + icon 32 + name 28 + slider + level 15 + mute 26 + 4 gaps of 8.
    static var height: CGFloat { inset * 2 - 2 + 32 + 28 + sliderHeight + 15 + 26 + 4 * 8 }
    static let sliderHeight: CGFloat = 140
    static let spacing: CGFloat = 4
}

private struct PreviewHoveredChannelKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    /// Draws the channel with this name as hovered without a pointer (offscreen renders such as the README demo).
    var previewHoveredChannel: String? {
        get { self[PreviewHoveredChannelKey.self] }
        set { self[PreviewHoveredChannelKey.self] = newValue }
    }
}

/// One mixer column: icon, name, vertical slider, level, mute button.
struct ChannelStrip<Icon: View>: View {
    let name: String
    let volume: Float
    let maxValue: Float
    let isMuted: Bool
    let isEnabled: Bool
    let canMute: Bool
    let isPlaying: Bool
    let isAdjusted: Bool
    let onVolume: (Float) -> Void
    let onToggleMute: () -> Void
    let onReset: () -> Void
    @ViewBuilder let icon: () -> Icon

    @State private var hovering = false
    @Environment(\.previewHoveredChannel) private var previewHoveredChannel

    var body: some View {
        let hovered = hovering || previewHoveredChannel == name
        VStack(spacing: 8) {
            icon()
                .frame(width: 32, height: 32)
                .overlay(alignment: .bottomTrailing) {
                    if isPlaying {
                        Circle()
                            .fill(.green)
                            .overlay(Circle().stroke(.background, lineWidth: 1.5))
                            .frame(width: 9, height: 9)
                            .offset(x: 2, y: 2)
                            .help("Playing")
                    }
                }

            Text(name)
                .font(.system(size: 11))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(width: ChannelMetrics.width - 10, height: 28, alignment: .top)
                .help(name)

            VerticalSlider(value: volume, maxValue: maxValue, isMuted: isMuted, onChange: onVolume)
                .frame(height: ChannelMetrics.sliderHeight)
                .disabled(!isEnabled)
                .compositingGroup()  // fade as one layer, so the track doesn't show through the thumb
                .opacity(isEnabled ? 1 : 0.4)

            Text(isEnabled ? "\(Int((volume * 100).rounded()))" : "–")
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(isMuted ? AnyShapeStyle(.secondary)
                                 : volume > 1.001 ? AnyShapeStyle(.orange) : AnyShapeStyle(.primary))
                .contentTransition(.numericText())
                .help(volume > 1.001 ? "Boosted above 100 — the sound can distort" : "")

            MuteButton(volume: volume, isMuted: isMuted, action: onToggleMute)
                .disabled(!canMute)
                .compositingGroup()
                .opacity(canMute ? 1 : 0.4)
        }
        .padding(.top, ChannelMetrics.inset)
        .padding(.bottom, ChannelMetrics.inset - 2)  // the mute button's hit area already carries ~2pt of air
        .frame(width: ChannelMetrics.width)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.primary.opacity(hovered ? 0.06 : 0)))
        .overlay(alignment: .topTrailing) {
            if isAdjusted && hovered {
                Button(action: onReset) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Reset to 100")
                .padding(5)
                .transition(.opacity)
            }
        }
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
    }
}

private struct AppIcon: View {
    let icon: NSImage?

    var body: some View {
        if let icon {
            Image(nsImage: icon).resizable().interpolation(.high).scaledToFit()
        } else {
            Image(systemName: "app.dashed").resizable().scaledToFit().padding(3)
                .foregroundStyle(.secondary)
        }
    }
}

/// Output-device tile, sized like an app icon's artwork so the Device channel lines up with the apps.
struct DeviceIcon: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 6.5, style: .continuous)
            .fill(LinearGradient(colors: [Color(white: 0.56), Color(white: 0.38)], startPoint: .top, endPoint: .bottom))
            .overlay(Image(systemName: "hifispeaker.fill")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white))
            .shadow(color: .black.opacity(0.18), radius: 0.5, y: 0.5)
            .padding(3)
    }
}

/// Windows-style mute toggle: a speaker whose waves follow the level, with a red "no" badge when muted.
private struct MuteButton: View {
    let volume: Float
    let isMuted: Bool
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    private var symbol: String {
        if isMuted || volume == 0 { return "speaker.fill" }
        if volume < 0.34 { return "speaker.wave.1.fill" }
        if volume < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    var body: some View {
        Button(action: action) {
            // The widest glyph reserves the space and the real one is pinned to its leading edge,
            // so the speaker body stays put as the waves change and the whole glyph stays centered.
            Image(systemName: "speaker.wave.3.fill")
                .hidden()
                .overlay(alignment: .leading) {
                    Image(systemName: symbol)
                        .foregroundStyle(Color.primary.opacity(isMuted ? 0.55 : 0.8))
                }
                .overlay(alignment: .trailing) {
                    if isMuted {
                        Image(systemName: "nosign")
                            .font(.system(size: 10, weight: .heavy))
                            .foregroundStyle(.red)
                            .offset(x: 1, y: 3)
                    }
                }
                .font(.system(size: 13))
                .frame(width: 36, height: 26)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(hovering && isEnabled ? 0.1 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(isMuted ? "Unmute" : "Mute")
        .accessibilityLabel(isMuted ? "Unmute" : "Mute")
    }
}

/// Windows 11–style vertical slider: thin track filled from the bottom, round thumb with an accent core.
/// With `maxValue` > 1, 100% sits at `unity` of the travel (marked with a notch) and the boost range above it is orange.
struct VerticalSlider: View {
    let value: Float
    var maxValue: Float = 1
    let isMuted: Bool
    let onChange: (Float) -> Void

    @State private var hovering = false
    @State private var dragging = false
    @State private var wheelMonitor: Any?
    @State private var wheelValue: Float = 0   // the monitor closure outlives this struct copy, so it reads state, not `value`
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    private let thumb: CGFloat = 20
    private let track: CGFloat = 4
    private let unity: CGFloat = 0.75
    private var canBoost: Bool { maxValue > 1 }

    /// Value -> fraction of the travel.
    private func position(_ v: Float) -> CGFloat {
        let v = min(max(v, 0), maxValue)
        guard canBoost else { return CGFloat(v) }
        return v <= 1 ? CGFloat(v) * unity : unity + CGFloat((v - 1) / (maxValue - 1)) * (1 - unity)
    }

    /// Fraction of the travel -> value, snapping onto 100% (which removes the tap) near the notch or the top.
    private func value(at p: CGFloat) -> Float {
        let p = min(max(p, 0), 1)
        if canBoost {
            if abs(p - unity) < 0.025 { return 1 }
            return p <= unity ? Float(p / unity) : 1 + Float((p - unity) / (1 - unity)) * (maxValue - 1)
        }
        return p > 0.98 ? 1 : Float(p)
    }

    var body: some View {
        GeometryReader { geo in
            let travel = max(geo.size.height - thumb, 1)
            let level = position(value)
            let fill: Color = isMuted ? .secondary.opacity(0.6) : .accentColor
            ZStack(alignment: .bottom) {
                Capsule()
                    .fill(Color.primary.opacity(0.18))
                    .frame(width: track)
                    .padding(.vertical, thumb / 2)
                if canBoost {
                    Capsule()
                        .fill(Color.primary.opacity(0.35))
                        .frame(width: 12, height: 1.5)
                        .padding(.bottom, thumb / 2 + travel * unity - 0.75)
                }
                Capsule()
                    .fill(fill)
                    .frame(width: track, height: travel * level)
                    .padding(.bottom, thumb / 2)
                if canBoost && level > unity {
                    Rectangle()
                        .fill(isMuted ? fill : .orange)
                        .frame(width: track, height: travel * (level - unity))
                        .padding(.bottom, thumb / 2 + travel * unity)
                }
                Circle()
                    .fill(colorScheme == .dark ? Color(white: 0.27) : .white)
                    .overlay(Circle().stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.2), radius: 1.5, y: 0.5)
                    .overlay(Circle()
                        .fill(canBoost && level > unity && !isMuted ? .orange : fill)
                        .padding(dragging ? 6 : hovering ? 4 : 5))
                    .frame(width: thumb, height: thumb)
                    .offset(y: -travel * level)
                    .animation(.easeOut(duration: 0.1), value: hovering)
                    .animation(.easeOut(duration: 0.1), value: dragging)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .onHover { hovering = $0 && isEnabled }
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    dragging = true
                    onChange(value(at: 1 - (drag.location.y - thumb / 2) / travel))
                }
                .onEnded { _ in dragging = false })
        }
        .frame(width: 44)
        .onChange(of: value, initial: true) { wheelValue = value }
        .onAppear(perform: installWheelMonitor)
        .onDisappear(perform: removeWheelMonitor)
        .accessibilityElement()
        .accessibilityLabel("Volume")
        .accessibilityValue("\(Int((value * 100).rounded())) percent")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onChange(min(value + 0.05, maxValue))
            case .decrement: onChange(max(value - 0.05, 0))
            @unknown default: break
            }
        }
    }

    /// Mouse wheel / two-finger scroll over the hovered slider changes the level, like on Windows.
    /// Crossing 100% stops there once, so it's easy to land on exactly 100.
    private func installWheelMonitor() {
        guard wheelMonitor == nil else { return }
        wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard hovering, isEnabled, abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) else { return event }
            // Positive = physically scrolled up, regardless of the natural-scrolling setting.
            let delta = Float(event.isDirectionInvertedFromDevice ? -event.scrollingDeltaY : event.scrollingDeltaY)
            let step = event.hasPreciseScrollingDeltas ? delta / 250 : delta * 0.02
            let old = wheelValue
            var v = min(max(old + step, 0), maxValue)
            if (old < 1 && v > 1) || (old > 1 && v < 1) || abs(v - 1) < 0.005 { v = 1 }
            wheelValue = v
            onChange(v)
            return nil
        }
    }

    private func removeWheelMonitor() {
        if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor) }
        wheelMonitor = nil
    }
}
