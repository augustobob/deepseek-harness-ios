import SwiftUI
import UniformTypeIdentifiers

struct WorkspaceView: View {
    @Environment(AppModel.self) private var model
    @State private var isAppDocumentsPickerPresented = false
    @State private var appDocumentFolders: [URL] = []
    @State private var reauthorizingMountID: UUID?
    @State private var mountPendingRemoval: WorkspaceStore.MountSnapshot?
    @State private var isRemovalConfirmationPresented = false
    @State private var isFileExporterPresented = false
    @State private var exportDocument: ConversationExportFileDocument?
    @State private var exportContentType: UTType = .data
    @State private var exportFilename = "workspace-file"

    var body: some View {
        List {
            WorkspaceMountsSection(
                mounts: model.workspaceMounts,
                onToggleWritable: toggleWritable,
                onReauthorize: reauthorize,
                onRemove: requestRemoval
            )

            Section {
                if model.workspaceFiles.isEmpty {
                    VStack(spacing: HarnessTheme.Spacing.medium) {
                        ContentUnavailableView(
                            "No files yet",
                            systemImage: "folder.badge.plus",
                            description: Text("Import a file or mount an external folder to start using the workspace.")
                        )

                        VStack(spacing: HarnessTheme.Spacing.small) {
                            HStack(spacing: HarnessTheme.Spacing.small) {
                                Button("Import file", systemImage: "doc.badge.plus") {
                                    presentFileImporter()
                                }
                                .buttonStyle(.bordered)

                                Button("Mount folder", systemImage: "externaldrive.badge.plus") {
                                    presentSystemFolderPicker()
                                }
                                .buttonStyle(.borderedProminent)
                            }
                            Button("Mount from app Documents", systemImage: "folder.badge.plus") {
                                reauthorizingMountID = nil
                                presentAppDocumentsPicker()
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, HarnessTheme.Spacing.large)
                } else {
                    ForEach(model.workspaceFiles, id: \.path) { file in
                        WorkspaceFileRow(
                            file: file,
                            onExport: { export(file) }
                        )
                    }
                }
            } header: { Label("File", systemImage: "doc.text") }
        }
        .listStyle(.insetGrouped)
        .environment(\.defaultMinListRowHeight, 44)
        .scrollContentBackground(.hidden)
        .background(HarnessTheme.pageBackground)
        .navigationTitle("Workspace")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Import file", systemImage: "doc.badge.plus") {
                        presentFileImporter()
                    }
                    Button("Mount folder", systemImage: "externaldrive.badge.plus") {
                        presentSystemFolderPicker()
                    }
                    Button("Mount from app Documents", systemImage: "folder.badge.plus") {
                        reauthorizingMountID = nil
                        presentAppDocumentsPicker()
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add to workspace")
            }
        }
        .refreshable {
            await model.refreshWorkspace(forceMountRefresh: true)
        }
        .background {
            Color.clear
                .fileExporter(
                    isPresented: $isFileExporterPresented,
                    document: exportDocument,
                    contentType: exportContentType,
                    defaultFilename: exportFilename
                ) { result in
                    exportDocument = nil
                    if case let .failure(error) = result {
                        model.presentError(error)
                    }
                }
        }
        .sheet(isPresented: $isAppDocumentsPickerPresented) {
            NavigationStack {
                AppDocumentsFolderPicker(
                    folders: appDocumentFolders,
                    onPick: { url in
                        isAppDocumentsPickerPresented = false
                        handlePickedFolder(url)
                    }
                )
            }
        }
        .confirmationDialog(
            "Unmount this folder?",
            isPresented: $isRemovalConfirmationPresented,
            titleVisibility: .visible,
            presenting: mountPendingRemoval
        ) { mount in
            Button("Unmount \(mount.name)", role: .destructive) {
                mountPendingRemoval = nil
                Task {
                    await model.removeWorkspaceMount(id: mount.id)
                }
            }
            Button("Cancel", role: .cancel) {
                mountPendingRemoval = nil
            }
        } message: { mount in
            Text("The source folder is not deleted; it is only removed from /workspace/mounts/\(mount.name).")
        }
    }

    private func toggleWritable(_ mount: WorkspaceStore.MountSnapshot) {
        Task {
            await model.setWorkspaceMountWritable(
                id: mount.id,
                writable: !mount.access.allowsWriting
            )
        }
    }

    private func presentFileImporter() {
        // Broad type list: the store validates size and extension itself, and
        // narrow lists leave many files greyed out in Files.
        DocumentPicker.pickFileCopy(types: [.item]) { url in
            Task { await model.importDocument(url) }
        }
    }

    private func presentSystemFolderPicker(keepingReauthorization: Bool = false) {
        if !keepingReauthorization { reauthorizingMountID = nil }
        DocumentPicker.pickFolderInPlace(
            onPick: { url in handlePickedFolder(url) },
            onCancel: { reauthorizingMountID = nil }
        )
    }

    private func presentAppDocumentsPicker() {
        Task {
            appDocumentFolders = await model.listAppDocumentFolders()
            isAppDocumentsPickerPresented = true
        }
    }

    private func handlePickedFolder(_ url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        let mountID = reauthorizingMountID
        reauthorizingMountID = nil
        Task {
            defer {
                if accessed {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            if let mountID {
                await model.reauthorizeWorkspaceMount(id: mountID, url: url)
            } else {
                await model.mountWorkspaceFolder(url)
            }
        }
    }

    private func reauthorize(_ mount: WorkspaceStore.MountSnapshot) {
        reauthorizingMountID = mount.id
        if SideloadAppIdentity.openInPlaceGrantLikelyDenied {
            presentAppDocumentsPicker()
        } else {
            presentSystemFolderPicker(keepingReauthorization: true)
        }
    }

    private func requestRemoval(_ mount: WorkspaceStore.MountSnapshot) {
        mountPendingRemoval = mount
        isRemovalConfirmationPresented = true
    }

    private func export(_ file: WorkspaceStore.FileEntry) {
        Task {
            do {
                let data = try await model.workspaceFileData(path: file.path)
                exportDocument = ConversationExportFileDocument(data: data)
                exportContentType = UTType(filenameExtension: URL(fileURLWithPath: file.path).pathExtension) ?? .data
                exportFilename = URL(fileURLWithPath: file.path).lastPathComponent
                isFileExporterPresented = true
            } catch {
                model.presentError(error)
            }
        }
    }
}

private struct WorkspaceMountsSection: View {
    let mounts: [WorkspaceStore.MountSnapshot]
    let onToggleWritable: (WorkspaceStore.MountSnapshot) -> Void
    let onReauthorize: (WorkspaceStore.MountSnapshot) -> Void
    let onRemove: (WorkspaceStore.MountSnapshot) -> Void

    var body: some View {
        Section {
            if mounts.isEmpty {
                Label("No external folder mounted", systemImage: "externaldrive")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(mounts) { mount in
                    WorkspaceMountRow(
                        mount: mount,
                        onToggleWritable: { onToggleWritable(mount) },
                        onReauthorize: { onReauthorize(mount) },
                        onRemove: { onRemove(mount) }
                    )
                }
            }
        } header: { Label("Mounted directories", systemImage: "externaldrive") }
        footer: {
            if SideloadAppIdentity.openInPlaceGrantLikelyDenied {
                Text(SideloadAppIdentity.mismatchWarning)
            } else if SideloadAppIdentity.hasEmbeddedProvision {
                Text("If Open in the system picker does nothing, copy the folder in Files to On My iPhone → Harness Mobile, then use Mount from app Documents.")
            }
        }
    }
}

private struct WorkspaceMountRow: View {
    let mount: WorkspaceStore.MountSnapshot
    let onToggleWritable: () -> Void
    let onReauthorize: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            HarnessIconTile(systemImage: statusIcon, tint: statusColor)

            VStack(alignment: .leading, spacing: 3) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        Text(mount.name).lineLimit(1)
                        accessPill
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(mount.name)
                            .fixedSize(horizontal: false, vertical: true)
                        accessPill
                    }
                }
                Text(mount.guestPath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(statusColor)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            Menu {
                Button(
                    mount.access.allowsWriting ? "Switch to read-only" : "Allow writing",
                    systemImage: mount.access.allowsWriting ? "lock" : "lock.open"
                ) {
                    onToggleWritable()
                }
                .disabled(!mount.sourceWritable && !mount.access.allowsWriting)

                Button("Re-authorize", systemImage: "arrow.clockwise") {
                    onReauthorize()
                }

                Button("Uninstall", systemImage: "eject", role: .destructive) {
                    onRemove()
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Manage mount \(mount.name)")
        }
    }

    private var statusIcon: String {
        switch mount.status {
        case .active:
            mount.effectiveWritable
                ? "externaldrive.fill.badge.checkmark"
                : "externaldrive.badge.checkmark"
        case .staleBookmark:
            "externaldrive.badge.exclamationmark"
        case .permissionDenied, .unavailable:
            "externaldrive.badge.xmark"
        }
    }

    private var statusColor: Color {
        switch mount.status {
        case .active: .green
        case .staleBookmark: .orange
        case .permissionDenied, .unavailable: .red
        }
    }

    private var statusText: String {
        switch mount.status {
        case .active:
            mount.sourceDisplayName
        case .staleBookmark:
            mount.failureMessage ?? "Authorization expired"
        case .permissionDenied:
            mount.failureMessage ?? "Reauthorization needed"
        case .unavailable:
            mount.failureMessage ?? "Folder currently unavailable"
        }
    }

    private var accessPill: some View {
        HarnessStatusPill(
            title: mount.effectiveWritable ? "Read/write" : "Read-only",
            systemImage: mount.effectiveWritable ? "lock.open" : "lock",
            tint: mount.effectiveWritable ? .green : .secondary
        )
    }
}

private struct WorkspaceFileRow: View {
    let file: WorkspaceStore.FileEntry
    let onExport: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            HarnessIconTile(
                systemImage: file.path.hasPrefix("mounts/") ? "doc.on.doc" : "doc.text",
                tint: .secondary
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(file.path)
                    .lineLimit(2)
                Text(
                    ByteCountFormatter.string(
                        fromByteCount: file.size,
                        countStyle: .file
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Menu {
                Button("Export file", systemImage: "square.and.arrow.up", action: onExport)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Export \(file.path)")
        }
    }
}

private struct AppDocumentsFolderPicker: View {
    let folders: [URL]
    let onPick: (URL) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            if folders.isEmpty {
                ContentUnavailableView(
                    "No folders in app Documents",
                    systemImage: "folder",
                    description: Text("In the Files app, copy a folder to On My iPhone → Harness Mobile, then return here.")
                )
            } else {
                ForEach(folders, id: \.path) { url in
                    Button {
                        onPick(url)
                    } label: {
                        Label(url.lastPathComponent, systemImage: "folder")
                    }
                }
            }
        }
        .navigationTitle("App Documents")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
        }
    }
}
