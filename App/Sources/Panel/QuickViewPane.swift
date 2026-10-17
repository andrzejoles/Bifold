import AppKit
import BifoldCore
import BifoldWorkspace
import Quartz

/// Szybki podgląd (Ctrl+Q): drugi panel pokazuje podgląd elementu pod kursorem aktywnego panelu.
final class QuickViewPane: NSView {
    private let workspace: Workspace
    private let preview: QLPreviewView
    private let info = NSTextField(wrappingLabelWithString: "")
    private let observations = ObservationBag()
    private var shownPath: VFSPath?

    init(workspace: Workspace) {
        self.workspace = workspace
        preview = QLPreviewView(frame: .zero, style: .normal)!
        super.init(frame: .zero)
        preview.autostarts = true
        preview.translatesAutoresizingMaskIntoConstraints = false
        info.font = .systemFont(ofSize: 11)
        info.textColor = .secondaryLabelColor
        info.translatesAutoresizingMaskIntoConstraints = false
        addSubview(preview)
        addSubview(info)
        NSLayoutConstraint.activate([
            preview.leadingAnchor.constraint(equalTo: leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: trailingAnchor),
            preview.topAnchor.constraint(equalTo: topAnchor),
            preview.bottomAnchor.constraint(equalTo: info.topAnchor, constant: -4),
            info.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            info.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            info.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
        observations.add { [weak self] in
            guard let self else { return }
            let item = self.workspace.activeTab.cursorItem
            self.show(item)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func show(_ item: FileItem?) {
        guard let item, !item.isParentLink, let url = item.path.url else {
            preview.previewItem = nil
            info.stringValue = ""
            shownPath = nil
            return
        }
        guard item.path != shownPath else { return }
        shownPath = item.path
        preview.previewItem = url as NSURL
        let size = item.isNavigable ? "" : Format.bytes(item.size)
        let date = item.modified.map { Formatters.date.string(from: $0) } ?? ""
        info.stringValue = "\(item.name)   \(size)   \(date)"
    }

    override func removeFromSuperview() {
        preview.close()
        observations.cancelAll()
        super.removeFromSuperview()
    }
}
