import AppKit
import BifoldCore
import BifoldWorkspace

/// Pasek zadań w tle: postęp, prędkość, pauza/wznowienie, limit prędkości, anulowanie.
final class JobsBar: NSView {
    private let workspace: Workspace
    private let stack = NSStackView()
    private var rows: [UUID: JobRow] = [:]
    private let observations = ObservationBag()
    private var heightConstraint: NSLayoutConstraint!

    init(workspace: Workspace) {
        self.workspace = workspace
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 8, bottom: 2, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        heightConstraint = heightAnchor.constraint(equalToConstant: 0)
        heightConstraint.isActive = true
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
        ])
        observations.add { [weak self] in self?.sync() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func sync() {
        let jobs = workspace.jobs.jobs.suffix(4)
        let ids = Set(jobs.map(\.id))
        for (id, row) in rows where !ids.contains(id) {
            row.removeFromSuperview()
            rows[id] = nil
        }
        for job in jobs where rows[job.id] == nil {
            let row = JobRow(job: job, queue: workspace.jobs)
            rows[job.id] = row
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -16).isActive = true
        }
        let height = CGFloat(rows.count) * 26 + (rows.isEmpty ? 0 : 6)
        heightConstraint.constant = height
        isHidden = rows.isEmpty
        // Zakończone bez błędów znikają po chwili.
        for job in jobs where job.state == .completed {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                guard let self, job.state == .completed else { return }
                self.workspace.jobs.removeFinished()
            }
        }
    }
}

private final class JobRow: NSView {
    private let job: Job
    private let queue: JobQueue
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private let pauseButton = NSButton()
    private let limitButton = NSButton()
    private let cancelButton = NSButton()
    private let observations = ObservationBag()

    init(job: Job, queue: JobQueue) {
        self.job = job
        self.queue = queue
        super.init(frame: .zero)
        title.font = .systemFont(ofSize: 11, weight: .medium)
        title.lineBreakMode = .byTruncatingMiddle
        title.widthAnchor.constraint(lessThanOrEqualToConstant: 320).isActive = true
        detail.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingMiddle
        progress.style = .bar
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.controlSize = .small
        progress.widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        for (b, symbol, tip, action) in [
            (pauseButton, "pause.fill", L10n.tr("Wstrzymaj / wznów"), #selector(togglePause)),
            (limitButton, "speedometer", L10n.tr("Limit prędkości"), #selector(setLimit)),
            (cancelButton, "xmark.circle.fill", L10n.tr("Anuluj"), #selector(cancel)),
        ] {
            b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
            b.isBordered = false
            b.toolTip = tip
            b.target = self
            b.action = action
            b.refusesFirstResponder = true
        }
        let stack = NSStackView(views: [title, progress, detail, pauseButton, limitButton, cancelButton])
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 24),
        ])
        observations.add { [weak self] in self?.update() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func update() {
        title.stringValue = job.title
        let p = job.progress
        progress.doubleValue = p.fraction
        var parts: [String] = []
        if p.bytesTotal > 0 { parts.append("\(Format.bytes(p.bytesDone)) / \(Format.bytes(p.bytesTotal))") }
        if p.filesTotal > 0 { parts.append("\(p.filesDone)/\(p.filesTotal)") }
        if p.bytesPerSecond > 0, job.state == .running {
            parts.append("\(Format.bytes(Int64(p.bytesPerSecond)))/s")
            if p.bytesTotal > p.bytesDone {
                let eta = Double(p.bytesTotal - p.bytesDone) / p.bytesPerSecond
                parts.append("ETA \(Duration.seconds(eta).formatted(.time(pattern: .minuteSecond)))")
            }
        }
        if job.speedLimit > 0 { parts.append(L10n.tr("limit \(Format.bytes(job.speedLimit))/s")) }
        switch job.state {
        case .paused: parts.append(L10n.tr("wstrzymane"))
        case .completed: parts.append(L10n.tr("zakończone"))
        case .cancelled: parts.append(L10n.tr("anulowane"))
        case .failed(let why): parts.append("⚠︎ \(why)")
        case .queued: parts.append(L10n.tr("w kolejce"))
        case .running: if !p.currentItem.isEmpty { parts.append(p.currentItem) }
        }
        if !job.errors.isEmpty { detail.toolTip = job.errors.joined(separator: "\n") }
        detail.stringValue = parts.joined(separator: "  ·  ")
        pauseButton.image = NSImage(systemSymbolName: job.state == .paused ? "play.fill" : "pause.fill", accessibilityDescription: nil)
        let finished = job.state.isFinished
        pauseButton.isHidden = finished
        limitButton.isHidden = finished
        cancelButton.image = NSImage(systemSymbolName: finished ? "xmark" : "xmark.circle.fill", accessibilityDescription: nil)
    }

    @objc private func togglePause() {
        job.state == .paused ? queue.resume(job) : queue.pause(job)
    }

    @objc private func cancel() {
        if job.state.isFinished { queue.removeFinished() } else { queue.cancel(job) }
    }

    @objc private func setLimit() {
        let menu = NSMenu()
        for mb in [0, 1, 5, 10, 25, 50, 100] {
            let item = NSMenuItem(title: mb == 0 ? L10n.tr("Bez limitu") : "\(mb) MB/s", action: #selector(chooseLimit(_:)), keyEquivalent: "")
            item.tag = mb
            item.target = self
            item.state = Int64(mb) * 1024 * 1024 == job.speedLimit ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: limitButton.bounds.height), in: limitButton)
    }

    @objc private func chooseLimit(_ sender: NSMenuItem) {
        queue.setSpeedLimit(job, Int64(sender.tag) * 1024 * 1024)
    }
}
