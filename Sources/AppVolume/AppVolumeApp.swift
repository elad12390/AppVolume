import SwiftUI

@main
struct AppVolumeApp: App {
    @State private var controller = VolumeController()

    var body: some Scene {
        MenuBarExtra("AppVolume", systemImage: "slider.vertical.3") {
            ContentView(controller: controller)
        }
        .menuBarExtraStyle(.window)
    }
}
