import BifoldCore
import Foundation
@testable import BifoldWorkspace

@MainActor
final class MockUI: UIServices {
    var textAnswers: [String?] = []
    var confirmAnswer = true
    var transferAnswer: TransferDialogResult?
    var pasteboard: [String] = []
    var openedInEditor: [URL] = []
    var errors: [String] = []
    var prompts: [String] = []

    func promptText(title: String, message: String?, defaultValue: String, selectStem: Bool) async -> String? {
        prompts.append(title)
        return textAnswers.isEmpty ? defaultValue : textAnswers.removeFirst()
    }
    func confirm(title: String, message: String, confirmTitle: String, destructive: Bool) async -> Bool { confirmAnswer }
    func promptTransfer(kind: TransferKind, items: [FileItem], defaultDestination: String) async -> TransferDialogResult? {
        transferAnswer ?? TransferDialogResult(destination: defaultDestination)
    }
    func promptAttributes(items: [FileItem]) async -> AttributeChange? { AttributeChange(permissions: 0o600) }
    func promptTags(items: [FileItem], current: [String]) async -> [String]? { ["Zielony"] }
    func promptMask(title: String, defaultMask: String) async -> String? { textAnswers.isEmpty ? defaultMask : textAnswers.removeFirst() }
    func confirmUndo(_ plan: UndoPlan, title: String) async -> (proceed: Bool, force: Bool) { (confirmAnswer, false) }
    func showError(_ message: String) { errors.append(message) }
    func showMessage(_ message: String) {}
    func openInEditor(_ urls: [URL]) { openedInEditor += urls }
    func openWithDefaultApp(_ urls: [URL]) {}
    func showViewer(_ item: FileItem) {}
    func toggleQuickLook(_ items: [FileItem]) {}
    func togglePreviewPanel() {}
    func runInTerminal(command: String?, directory: VFSPath) {}
    func toggleTerminal(directory: VFSPath) {}
    func focusCommandLine() {}
    func focusQuickFilter() {}
    func showCommandPalette() {}
    func showVolumes() {}
    func share(_ urls: [URL]) {}
    func openWith(_ urls: [URL]) {}
    func copyToPasteboard(_ strings: [String]) { pasteboard = strings }
    func showSettings() {}
    func showJournal() {}
    func transferDelegate() -> any TransferDelegate { PolicyTransferDelegate(conflict: .skip) }
    var reports: [String] = []
    var multiRenameItems: [FileItem] = []
    func showSearch(directory: VFSPath, criteria: SearchCriteria?) {}
    func showMultiRename(items: [FileItem]) { multiRenameItems = items }
    func showReport(title: String, text: String) { reports.append(text) }
    var passwordAnswer: String?
    func promptPassword(title: String) async -> String? { passwordAnswer }
    func showConnections() {}
    var compared: (FileItem, FileItem)?
    func showCompare(left: FileItem, right: FileItem) { compared = (left, right) }
    func showSync(source: VFSPath, destination: VFSPath, job: SyncJob?) {}
}

/// `Workspace.ui` jest słabą referencją — atrapy muszą żyć do końca testu.
@MainActor var retainedUIs: [MockUI] = []

@MainActor
func makeWorkspace(_ tmp: TempDir, left: String = "", right: String = "") async throws -> (Workspace, MockUI) {
    let ws = Workspace(paths: AppPaths(root: tmp.url.appending(path: ".app")), persists: false, home: tmp.path)
    let ui = MockUI()
    retainedUIs.append(ui)
    ws.ui = ui
    try await ws.left.activeTab.navigate(to: left.isEmpty ? tmp.path : tmp.path.appending(left))
    try await ws.right.activeTab.navigate(to: right.isEmpty ? tmp.path : tmp.path.appending(right))
    return (ws, ui)
}
