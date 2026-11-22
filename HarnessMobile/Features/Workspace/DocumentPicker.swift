import SwiftUI
import UniformTypeIdentifiers
import UIKit

/// Presents `UIDocumentPickerViewController` straight from the top-most view
/// controller instead of through SwiftUI's `.fileImporter`.
///
/// Why: `.fileImporter` always opens documents in place. On resigned
/// (Impactor / Feather) installs iOS often refuses the File Provider grant,
/// so every item is greyed out or "Open" silently does nothing and the
/// completion handler never runs. Copy mode (`asCopy: true`) does not need
/// the grant: iOS copies the picked file into the app's tmp/Inbox and hands
/// back a plain file URL. Folders cannot be copied (UIKit throws), so they
/// stay in open-in-place mode and have an in-sandbox Documents fallback.
///
/// Presenting from UIKit also avoids SwiftUI's one-presentation-per-view-node
/// problem when several importers/exporters/dialogs live on the same view.
@MainActor
enum DocumentPicker {
    private static var activeCoordinator: Coordinator?

    /// Pick one file as a private copy (works on sideloaded builds).
    static func pickFileCopy(
        types: [UTType],
        onPick: @escaping @MainActor (URL) -> Void,
        onCancel: @escaping @MainActor () -> Void = {}
    ) {
        present(types: types, asCopy: true, onPick: onPick, onCancel: onCancel)
    }

    /// Pick a folder in place (security-scoped URL, needed for a bookmark).
    static func pickFolderInPlace(
        onPick: @escaping @MainActor (URL) -> Void,
        onCancel: @escaping @MainActor () -> Void = {}
    ) {
        present(types: [.folder], asCopy: false, onPick: onPick, onCancel: onCancel)
    }

    private static func present(
        types: [UTType],
        asCopy: Bool,
        onPick: @escaping @MainActor (URL) -> Void,
        onCancel: @escaping @MainActor () -> Void
    ) {
        guard let presenter = topViewController() else {
            onCancel()
            return
        }
        // UIKit raises an exception for folders with asCopy == true.
        let copy = asCopy && !types.contains(where: { $0.conforms(to: .folder) })
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: types,
            asCopy: copy
        )
        picker.allowsMultipleSelection = false
        let coordinator = Coordinator(
            onPick: { url in
                activeCoordinator = nil
                onPick(url)
            },
            onCancel: {
                activeCoordinator = nil
                onCancel()
            }
        )
        activeCoordinator = coordinator
        picker.delegate = coordinator
        picker.presentationController?.delegate = coordinator
        presenter.present(picker, animated: true)
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first(where: { $0.activationState == .foregroundActive })
            ?? scenes.first(where: { $0.activationState == .foregroundInactive })
            ?? scenes.first
        var top = scene?.windows.first(where: \.isKeyWindow)?.rootViewController
            ?? scene?.windows.first?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }

    private final class Coordinator: NSObject,
        UIDocumentPickerDelegate,
        UIAdaptivePresentationControllerDelegate
    {
        let onPick: @MainActor (URL) -> Void
        let onCancel: @MainActor () -> Void

        init(
            onPick: @escaping @MainActor (URL) -> Void,
            onCancel: @escaping @MainActor () -> Void
        ) {
            self.onPick = onPick
            self.onCancel = onCancel
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            MainActor.assumeIsolated { onCancel() }
        }

        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            MainActor.assumeIsolated { onCancel() }
        }

        func documentPicker(
            _ controller: UIDocumentPickerViewController,
            didPickDocumentsAt urls: [URL]
        ) {
            MainActor.assumeIsolated {
                if let url = urls.first {
                    onPick(url)
                } else {
                    onCancel()
                }
            }
        }
    }
}

enum SideloadAppIdentity {
    static var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? ""
    }

    /// True when the running binary includes an embedded provisioning profile
    /// (development, Ad Hoc, Impactor, Feather). App Store / TestFlight builds
    /// typically do not.
    static var hasEmbeddedProvision: Bool {
        Bundle.main.path(forResource: "embedded", ofType: "mobileprovision") != nil
    }

    /// Bundle ID portion of the profile `application-identifier` (after the
    /// team prefix). Wildcard profiles end in `.*` or are `*`.
    static var profileBundleIdentifier: String? {
        guard let applicationIdentifier = applicationIdentifierFromEmbeddedProfile() else {
            return nil
        }
        guard let dot = applicationIdentifier.firstIndex(of: ".") else {
            return applicationIdentifier
        }
        return String(applicationIdentifier[applicationIdentifier.index(after: dot)...])
    }

    static var identifiersMatch: Bool {
        guard let profileID = profileBundleIdentifier else {
            return true
        }
        if profileID == "*" {
            return true
        }
        if profileID.hasSuffix(".*") {
            let prefix = String(profileID.dropLast(2))
            return bundleIdentifier == prefix || bundleIdentifier.hasPrefix(prefix + ".")
        }
        return profileID == bundleIdentifier
    }

    /// Sideloaded install whose signed bundle ID does not match the profile.
    /// Open-in-place folder picks commonly no-op in this state.
    static var openInPlaceGrantLikelyDenied: Bool {
        hasEmbeddedProvision && !identifiersMatch
    }

    static var mismatchWarning: String {
        let profile = profileBundleIdentifier ?? "(unknown)"
        return "This sideloaded build's bundle ID (\(bundleIdentifier)) does not match the signing profile App ID (\(profile)). The system folder picker may ignore Open. In Files, copy the folder to On My iPhone → Harness Mobile, then use Mount from app Documents."
    }

    private static func applicationIdentifierFromEmbeddedProfile() -> String? {
        guard let path = Bundle.main.path(forResource: "embedded", ofType: "mobileprovision"),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let text = String(data: data, encoding: .ascii)
                ?? String(data: data, encoding: .utf8),
              let start = text.range(of: "<?xml"),
              let end = text.range(of: "</plist>") else {
            return nil
        }
        let plistText = String(text[start.lowerBound...end.upperBound])
        guard let plistData = plistText.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(
                from: plistData,
                options: [],
                format: nil
              ) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any],
              let applicationIdentifier = entitlements["application-identifier"] as? String else {
            return nil
        }
        return applicationIdentifier
    }
}
