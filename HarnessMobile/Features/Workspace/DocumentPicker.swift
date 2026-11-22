import SwiftUI
import UniformTypeIdentifiers
import UIKit

/// Presents `UIDocumentPickerViewController` from the top-most view controller
/// instead of through SwiftUI's `.fileImporter`.
///
/// `.fileImporter` always opens documents in place, which needs a File Provider
/// grant. On a resigned Feather/Impactor install that grant is denied when the
/// app's bundle ID does not match the signing profile App ID, so items are
/// greyed out or Open does nothing.
///
/// Copy mode (`asCopy: true`) does not need the grant: iOS copies the file
/// into the app tmp/Inbox and returns a plain file URL. UIKit rejects
/// `asCopy: true` for folders, so folder access has to go through the
/// in-sandbox Documents directory (Files → On My iPhone → Harness Mobile).
/// There is no known entitlement or alternate picker that restores durable
/// access to an external folder while the identifiers differ.
@MainActor
enum DocumentPicker {
    fileprivate static var activeCoordinator: DocumentPickerCoordinator?

    static func pickFileCopy(
        types: [UTType],
        onPick: @escaping @MainActor (URL) -> Void,
        onCancel: @escaping @MainActor () -> Void = {}
    ) {
        present(types: types, asCopy: true, multiple: false) { urls in
            if let url = urls.first {
                onPick(url)
            } else {
                onCancel()
            }
        } onCancel: {
            onCancel()
        }
    }

    static func pickFilesCopy(
        types: [UTType],
        onPick: @escaping @MainActor ([URL]) -> Void,
        onCancel: @escaping @MainActor () -> Void = {}
    ) {
        present(types: types, asCopy: true, multiple: true, onPick: onPick, onCancel: onCancel)
    }

    /// Optional. Often a no-op on resigned installs (Open does nothing).
    /// The system Cancel button still works; prefer the Documents fallback.
    static func pickFolderInPlace(
        onPick: @escaping @MainActor (URL) -> Void,
        onCancel: @escaping @MainActor () -> Void = {}
    ) {
        present(types: [.folder], asCopy: false, multiple: false) { urls in
            if let url = urls.first {
                onPick(url)
            } else {
                onCancel()
            }
        } onCancel: {
            onCancel()
        }
    }

    fileprivate static func clearCoordinator() {
        activeCoordinator = nil
    }

    private static func present(
        types: [UTType],
        asCopy: Bool,
        multiple: Bool,
        onPick: @escaping @MainActor ([URL]) -> Void,
        onCancel: @escaping @MainActor () -> Void
    ) {
        guard let presenter = topViewController() else {
            onCancel()
            return
        }
        // UIKit raises if asCopy is true and the types include a folder.
        let copy = asCopy && !types.contains(where: { $0.conforms(to: .folder) })
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: types,
            asCopy: copy
        )
        picker.allowsMultipleSelection = multiple
        let coordinator = DocumentPickerCoordinator(onPick: onPick, onCancel: onCancel)
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
}

/// Kept off the `@MainActor` enum so it can be assigned to UIKit delegate
/// properties under complete concurrency checking.
final class DocumentPickerCoordinator: NSObject,
    UIDocumentPickerDelegate,
    UIAdaptivePresentationControllerDelegate
{
    private let onPick: @MainActor ([URL]) -> Void
    private let onCancel: @MainActor () -> Void
    private var didFinish = false

    init(
        onPick: @escaping @MainActor ([URL]) -> Void,
        onCancel: @escaping @MainActor () -> Void
    ) {
        self.onPick = onPick
        self.onCancel = onCancel
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        finishCancel()
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        finishCancel()
    }

    func documentPicker(
        _ controller: UIDocumentPickerViewController,
        didPickDocumentsAt urls: [URL]
    ) {
        let picked = urls
        Task { @MainActor in
            guard !self.didFinish else { return }
            self.didFinish = true
            DocumentPicker.clearCoordinator()
            if picked.isEmpty {
                self.onCancel()
            } else {
                self.onPick(picked)
            }
        }
    }

    private func finishCancel() {
        Task { @MainActor in
            guard !self.didFinish else { return }
            self.didFinish = true
            DocumentPicker.clearCoordinator()
            self.onCancel()
        }
    }
}
