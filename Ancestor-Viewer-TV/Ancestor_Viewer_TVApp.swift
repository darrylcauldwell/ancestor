import SwiftUI

@main
struct Ancestor_Viewer_TVApp: App {
    @State private var model = ViewerModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
        }
    }
}
