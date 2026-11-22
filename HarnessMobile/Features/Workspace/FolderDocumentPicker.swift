import SwiftUI
import UniformTypeIdentifiers
import UIKit

/// System folder picker in open-in-place mode (`asCopy: false`).
///
/// SwiftUI `.fileImporter` is an import (copy) presentation and, when stacked
/// with another importer/exporter on the same view, can leave the Files sheet
/// open after the user taps Open on a folder. UIKit's document picker with
/// `asCopy: false` is the supported way to get a security-scoped directory
/// URL for a durable bookmark.
///
/// On sideloaded/resigned builds, iOS may still refuse the File Provider
/// grant when `CFBundleIdentifier` does not match the profile's
/// `application-identifier`. In that case Open does nothing and the caller
/// should use the in-sandbox Documents fallback instead.
@MainActor
struct FolderDocumentPicker: UIViewControllerRepresentable {
    var onPick: @MainActor (URL) -> Void
    var onCancel: @MainActor () -> Void = {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // UIKit rejects folder picks when asCopy is true
        // ("folder import is not supported, use asCopy:false").
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [.folder],
            asCopy: false
        )
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(
        _ uiViewController: UIDocumentPickerViewController,
        context: Context
    ) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
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
            onCancel()
        }

        func documentPicker(
            _ controller: UIDocumentPickerViewController,
            didPickDocumentsAt urls: [URL]
        ) {
            guard let url = urls.first else {
                onCancel()
                return
            }
            // The caller must startAccessingSecurityScopedResource on this
            // URL before any await / actor hop.
            onPick(url)
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
