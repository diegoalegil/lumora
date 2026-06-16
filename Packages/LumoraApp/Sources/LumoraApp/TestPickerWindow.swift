// SPDX-License-Identifier: MIT
// Provenance: clean-room. TEST-ONLY helper: a bare window that lists every installed wallpaper so a
// real-machine pass can flip through them quickly (arrow keys, Prev/Next, or a click) and eyeball live
// rendering. Not part of the shipping UI — kept deliberately plain.
import AppKit

@MainActor
final class TestPickerWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let rows: [String]
    private let onSelect: (Int) -> Void
    private let table = NSTableView()
    private let status = NSTextField(labelWithString: "")

    /// - Parameters:
    ///   - rows: a display line per wallpaper, in the same order the caller will index back into.
    ///   - current: the index to pre-select (the active wallpaper).
    ///   - onSelect: invoked with the chosen index whenever the selection changes by the user.
    init(rows: [String], current: Int, onSelect: @escaping (Int) -> Void) {
        self.rows = rows
        self.onSelect = onSelect
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 500),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "Lumora — Test Picker"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildUI()
        window.initialFirstResponder = table
        if rows.indices.contains(current) {
            table.selectRowIndexes([current], byExtendingSelection: false)
            table.scrollRowToVisible(current)
        }
        updateStatus()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        let prev = NSButton(title: "◀ Prev", target: self, action: #selector(prevTapped))
        let next = NSButton(title: "Next ▶", target: self, action: #selector(nextTapped))
        status.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        status.textColor = .secondaryLabelColor

        let header = NSStackView(views: [prev, next, status])
        header.orientation = .horizontal
        header.spacing = 8
        header.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("title"))
        table.addTableColumn(column)
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 22
        table.allowsEmptySelection = false
        table.usesAlternatingRowBackgroundColors = true

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(header)
        content.addSubview(scroll)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            header.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -10),
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
        ])
    }

    @objc private func prevTapped() { move(by: -1) }
    @objc private func nextTapped() { move(by: 1) }

    /// Step the selection, wrapping around, so the whole library can be cycled with two buttons.
    private func move(by delta: Int) {
        guard !rows.isEmpty else { return }
        let count = rows.count
        let current = table.selectedRow < 0 ? 0 : table.selectedRow
        let target = ((current + delta) % count + count) % count
        table.selectRowIndexes([target], byExtendingSelection: false)
        table.scrollRowToVisible(target)
    }

    private func updateStatus() {
        status.stringValue = rows.isEmpty ? "0 / 0" : "\(table.selectedRow + 1) / \(rows.count)"
    }

    // MARK: - NSTableView

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell")
        let field = (tableView.makeView(withIdentifier: id, owner: self) as? NSTextField) ?? {
            let f = NSTextField(labelWithString: "")
            f.identifier = id
            f.lineBreakMode = .byTruncatingTail
            return f
        }()
        field.stringValue = rows.indices.contains(row) ? rows[row] : ""
        return field
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateStatus()
        let row = table.selectedRow
        guard row >= 0 else { return }
        onSelect(row)
    }
}
