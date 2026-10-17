import BifoldCore
import Foundation

/// Odpowiedź z okna kopiowania/przenoszenia (F5/F6).
public struct TransferDialogResult: Sendable {
    public var destination: String
    public var conflictPolicy: ConflictResolution?
    public var speedLimit: Int64

    public init(destination: String, conflictPolicy: ConflictResolution? = nil, speedLimit: Int64 = 0) {
        self.destination = destination
        self.conflictPolicy = conflictPolicy
        self.speedLimit = speedLimit
    }
}

/// Usługi interfejsu wywoływane przez komendy. Implementuje je cel aplikacji (AppKit),
/// w testach — atrapa. Komendy wywołane przez agenta nigdy nie pytają przez te okna
/// (z wyjątkiem okna zatwierdzania, które obsługuje warstwa agenta).
@MainActor
public protocol UIServices: AnyObject {
    func promptText(title: String, message: String?, defaultValue: String, selectStem: Bool) async -> String?
    func confirm(title: String, message: String, confirmTitle: String, destructive: Bool) async -> Bool
    func promptTransfer(kind: TransferKind, items: [FileItem], defaultDestination: String) async -> TransferDialogResult?
    func promptAttributes(items: [FileItem]) async -> AttributeChange?
    func promptTags(items: [FileItem], current: [String]) async -> [String]?
    func promptMask(title: String, defaultMask: String) async -> String?
    func confirmUndo(_ plan: UndoPlan, title: String) async -> (proceed: Bool, force: Bool)
    func showError(_ message: String)
    func showMessage(_ message: String)

    func openInEditor(_ urls: [URL])
    func openWithDefaultApp(_ urls: [URL])
    func showViewer(_ item: FileItem)
    func toggleQuickLook(_ items: [FileItem])
    func togglePreviewPanel()
    func runInTerminal(command: String?, directory: VFSPath)
    func toggleTerminal(directory: VFSPath)
    func focusCommandLine()
    func focusQuickFilter()
    func showCommandPalette()
    func showVolumes()
    func share(_ urls: [URL])
    func openWith(_ urls: [URL])
    func copyToPasteboard(_ strings: [String])
    func showSettings()
    func showJournal()
    func transferDelegate() -> any TransferDelegate
    /// Etap 3
    func showSearch(directory: VFSPath, criteria: SearchCriteria?)
    func showMultiRename(items: [FileItem])
    func showReport(title: String, text: String)
}
