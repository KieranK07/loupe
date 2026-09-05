import SwiftUI

@main
struct LoupeApp: App {
    @State private var model: AppModel
    @State private var controller: ScanController
    @State private var reclaim: ReclaimController

    init() {
        let model = AppModel()
        _model = State(initialValue: model)
        _controller = State(initialValue: ScanController(model: model))
        _reclaim = State(initialValue: ReclaimController(model: model, engine: LiveReclaimEngine()))
    }

    var body: some Scene {
        WindowGroup {
            RootView(controller: controller, reclaim: reclaim)
                .environment(model)
                .task {
                    model.access.refresh()
                    controller.loadVolumes()
                }
        }
        .defaultSize(width: 1080, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) { }   // Loupe does not create documents
        }
    }
}
