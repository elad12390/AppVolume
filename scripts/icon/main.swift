// Draws the app icon: a macOS-style rounded square with three mixer sliders (the last one boosted, in orange).
// Usage: render <iconset dir>  — writes every size iconutil needs. Run via scripts/make-icon.sh.
import AppKit
import SwiftUI

struct MixerIcon: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.23, green: 0.27, blue: 0.62), Color(red: 0.08, green: 0.09, blue: 0.24)],
                                     startPoint: .top, endPoint: .bottom))
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .strokeBorder(LinearGradient(colors: [.white.opacity(0.28), .white.opacity(0.04)], startPoint: .top, endPoint: .bottom),
                              lineWidth: 4)
            HStack(spacing: 150) {
                Fader(level: 0.42, colors: [Color(red: 0.25, green: 0.85, blue: 1.0), Color(red: 0.16, green: 0.48, blue: 1.0)])
                Fader(level: 0.70, colors: [Color(red: 0.55, green: 0.55, blue: 1.0), Color(red: 0.33, green: 0.33, blue: 0.98)])
                Fader(level: 0.88, colors: [Color(red: 1.0, green: 0.78, blue: 0.25), Color(red: 1.0, green: 0.48, blue: 0.12)])
            }
        }
        .frame(width: 824, height: 824)
        .shadow(color: .black.opacity(0.35), radius: 18, y: 12)
        .frame(width: 1024, height: 1024)
    }
}

struct Fader: View {
    let level: CGFloat
    let colors: [Color]
    private let track: CGFloat = 520
    private let knob: CGFloat = 112

    var body: some View {
        ZStack(alignment: .bottom) {
            Capsule().fill(.white.opacity(0.16)).frame(width: 36, height: track)
            Capsule()
                .fill(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom))
                .frame(width: 36, height: track * level)
            Circle()
                .fill(.white)
                .overlay(Circle().fill(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)).padding(30))
                .frame(width: knob, height: knob)
                .shadow(color: .black.opacity(0.35), radius: 10, y: 6)
                .offset(y: -(track * level) + knob / 2)
        }
        .frame(width: knob, height: track)
    }
}

MainActor.assumeIsolated {
    let dir = URL(fileURLWithPath: CommandLine.arguments[1])
    for (points, scales) in [(16, [1, 2]), (32, [1, 2]), (128, [1, 2]), (256, [1, 2]), (512, [1, 2])] {
        for scale in scales {
            let renderer = ImageRenderer(content: MixerIcon())
            renderer.scale = CGFloat(points * scale) / 1024
            let rep = NSBitmapImageRep(cgImage: renderer.cgImage!)
            let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
            try! rep.representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent(name))
        }
    }
}
