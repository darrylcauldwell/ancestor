import UIKit
import CloudKit

// Change 4 — CKShare invite acceptance. The system hands share metadata
// to the scene delegate (cold launch via connectionOptions, warm via
// userDidAcceptCloudKitShareWith); the relay buffers it until the
// SwiftUI layer has a ViewerModel to give it to. Requires
// CKSharingSupported=YES in Info.plist or the invite never opens the app.

@MainActor
final class ShareAcceptanceRelay {
    static let shared = ShareAcceptanceRelay()

    var onMetadata: ((CKShare.Metadata) -> Void)? {
        didSet {
            if let pending, let onMetadata {
                self.pending = nil
                onMetadata(pending)
            }
        }
    }
    private var pending: CKShare.Metadata?

    func deliver(_ metadata: CKShare.Metadata) {
        if let onMetadata {
            onMetadata(metadata)
        } else {
            pending = metadata
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(
            name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}

final class SceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        if let metadata = connectionOptions.cloudKitShareMetadata {
            Task { @MainActor in ShareAcceptanceRelay.shared.deliver(metadata) }
        }
    }

    func windowScene(_ windowScene: UIWindowScene,
                     userDidAcceptCloudKitShareWith metadata: CKShare.Metadata) {
        Task { @MainActor in ShareAcceptanceRelay.shared.deliver(metadata) }
    }
}
