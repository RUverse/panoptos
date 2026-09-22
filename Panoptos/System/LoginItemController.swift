import Foundation
import ServiceManagement

/// macOS owns login-item state, so Panoptos mirrors the system value instead of
/// storing its own copy. The user can also change it in System Settings.
enum LoginItemState: Equatable {
    case enabled
    case disabled
    /// Registered, but switched off by the user in System Settings.
    case requiresApproval
    /// The system cannot manage this bundle as a login item.
    case unavailable
}

protocol LoginItemControlling: AnyObject {
    var state: LoginItemState { get }
    func setEnabled(_ enabled: Bool) throws
}

final class SMAppServiceLoginItemController: LoginItemControlling {
    var state: LoginItemState {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .notRegistered: .disabled
        case .requiresApproval: .requiresApproval
        case .notFound: .unavailable
        @unknown default: .unavailable
        }
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
