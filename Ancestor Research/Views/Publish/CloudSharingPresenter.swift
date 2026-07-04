import AppKit
import CloudKit

// PUBLISHER_SPEC Change 5 — Apple's own macOS cloud-sharing window.
//
// SQLiteData's bundled CloudSharingView is UIKit-only, but AppKit has a
// first-party equivalent: NSSharingService(.cloudSharing) driven by an
// NSItemProvider carrying the CKShare. It handles both flows: inviting
// participants to a new share AND managing an existing one (participant
// list, permissions, stop sharing). Family accept the invitation once on
// iPhone/iPad/Mac; the shared tree then appears on all their devices.
@MainActor
enum CloudSharingPresenter {

    static func present(share: CKShare, container: CKContainer) {
        let provider = NSItemProvider()
        provider.registerCloudKitShare(share, container: container)
        guard let service = NSSharingService(named: .cloudSharing) else {
            NSSound.beep()
            return
        }
        service.perform(withItems: [provider])
    }
}
