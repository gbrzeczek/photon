import PhotonCore
import SwiftUI

/// What the smart album sheet edits: an album to change, or nil for a new one.
struct SmartAlbumRequest: Identifiable {
    let id = UUID()
    var album: Album?
}

/// A sheet like Photos' and Finder's smart folder editors: a name, Match All or Any, and a row of pop-ups
/// and a value per rule. The rules become SQL in `PhotonCore`, never here.
struct SmartAlbumEditor: View {
    let library: BrowserLibrary
    let model: BrowserModel
    let album: Album?
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var match: SmartQuery.Match
    @State private var rules: [EditableRule]

    init(library: BrowserLibrary, model: BrowserModel, album: Album?) {
        self.library = library
        self.model = model
        self.album = album
        let query = album?.smartQuery ?? SmartQuery(rules: [.favorite(true)])
        _name = State(initialValue: album?.name ?? "Untitled Smart Album")
        _match = State(initialValue: query.match)
        _rules = State(initialValue: query.rules.map(EditableRule.init))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            TextField("Smart Album Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("photon.smart.name")
            HStack {
                Text("Match")
                Picker("Match", selection: $match) {
                    Text("all").tag(SmartQuery.Match.all)
                    Text("any").tag(SmartQuery.Match.any)
                }
                .labelsHidden()
                .fixedSize()
                Text("of the following conditions:")
            }
            VStack(spacing: 8) {
                ForEach($rules) { $rule in
                    RuleRow(rule: $rule, library: library, canRemove: rules.count > 1) {
                        rules.removeAll { $0.id == rule.id }
                    } add: {
                        let index = rules.firstIndex { $0.id == rule.id }.map { $0 + 1 } ?? rules.endIndex
                        rules.insert(EditableRule(.kind(.photo)), at: index)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(album == nil ? "Create" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 560)
    }

    private func save() {
        let query = SmartQuery(match: match, rules: rules.map(\.rule))
        let name = name.trimmingCharacters(in: .whitespaces)
        if let album {
            model.editSmartAlbum(album.id, name: name, query: query)
        } else {
            model.newSmartAlbum(named: name, query: query)
        }
        dismiss()
    }
}

/// One rule, flattened into the values its pop-ups and field edit.
struct EditableRule: Identifiable, Hashable {
    enum Field: String, CaseIterable, Identifiable {
        case favorite, kind, tag, album, name, folder, fileType, captureDate, duration
        var id: Self { self }

        var title: String {
            switch self {
            case .favorite: "Favorite"
            case .kind: "Kind"
            case .tag: "Tag"
            case .album: "Album"
            case .name: "File Name"
            case .folder: "Folder"
            case .fileType: "File Type"
            case .captureDate: "Capture Date"
            case .duration: "Duration"
            }
        }

        /// The operators each field offers, in order.
        var operators: [String] {
            switch self {
            case .favorite: ["is", "is not"]
            case .kind: ["is photo", "is video"]
            case .tag: ["is", "is not"]
            case .album: ["is in", "is not in"]
            case .name, .folder: ["contains", "doesn't contain"]
            case .fileType: ["is"]
            case .captureDate: ["is in the last", "is before", "is after", "is in year"]
            case .duration: ["is longer than", "is shorter than"]
            }
        }
    }

    let id = UUID()
    var field: Field
    var op = 0
    var text = ""
    var number = 30.0
    var date = Date()
    var tag: TagID?
    var album: AlbumID?

    init(_ rule: SmartRule) {
        switch rule {
        case .favorite(let flag): field = .favorite; op = flag ? 0 : 1
        case .kind(let kind): field = .kind; op = kind == .photo ? 0 : 1
        case .tag(let tag, let matches): field = .tag; self.tag = tag; op = matches ? 0 : 1
        case .album(let album, let contains): field = .album; self.album = album; op = contains ? 0 : 1
        case .name(let text, let contains): field = .name; self.text = text; op = contains ? 0 : 1
        case .folder(let text, let contains): field = .folder; self.text = text; op = contains ? 0 : 1
        case .fileType(let type): field = .fileType; text = type
        case .capturedWithin(let days): field = .captureDate; op = 0; number = Double(days)
        case .capturedBefore(let date): field = .captureDate; op = 1; self.date = date
        case .capturedAfter(let date): field = .captureDate; op = 2; self.date = date
        case .capturedInYear(let year): field = .captureDate; op = 3; number = Double(year)
        case .durationLonger(let seconds): field = .duration; op = 0; number = seconds
        case .durationShorter(let seconds): field = .duration; op = 1; number = seconds
        }
    }

    var rule: SmartRule {
        let yes = op == 0
        switch field {
        case .favorite: return .favorite(yes)
        case .kind: return .kind(yes ? .photo : .video)
        // A rule left without a tag or an album matches nothing, which is what it says.
        case .tag: return .tag(tag ?? TagID(rawValue: 0), matches: yes)
        case .album: return .album(album ?? AlbumID(rawValue: 0), contains: yes)
        case .name: return .name(text, contains: yes)
        case .folder: return .folder(text, contains: yes)
        case .fileType: return .fileType(text)
        case .captureDate:
            switch op {
            case 1: return .capturedBefore(date)
            case 2: return .capturedAfter(date)
            case 3: return .capturedInYear(Int(number))
            default: return .capturedWithin(days: Int(number))
            }
        case .duration: return yes ? .durationLonger(seconds: number) : .durationShorter(seconds: number)
        }
    }
}

private struct RuleRow: View {
    @Binding var rule: EditableRule
    let library: BrowserLibrary
    let canRemove: Bool
    let remove: () -> Void
    let add: () -> Void

    var body: some View {
        HStack {
            Picker("Field", selection: $rule.field) {
                ForEach(EditableRule.Field.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .frame(width: 130)
            .onChange(of: rule.field) { _, field in
                rule.op = 0
                if field == .captureDate { rule.number = 30 }
                if field == .duration { rule.number = 10 }
            }
            Picker("Operator", selection: $rule.op) {
                ForEach(Array(rule.field.operators.enumerated()), id: \.offset) { Text($1).tag($0) }
            }
            .labelsHidden()
            .frame(width: 140)
            value
            Spacer(minLength: 0)
            Button("Remove Rule", systemImage: "minus") { remove() }
                .labelStyle(.iconOnly)
                .disabled(!canRemove)
            Button("Add Rule", systemImage: "plus") { add() }
                .labelStyle(.iconOnly)
        }
    }

    @ViewBuilder
    private var value: some View {
        switch rule.field {
        case .favorite, .kind:
            EmptyView()
        case .tag:
            Picker("Tag", selection: $rule.tag) {
                Text("Choose a Tag").tag(TagID?.none)
                ForEach(library.tags) { Text($0.name).tag(Optional($0.id)) }
            }
            .labelsHidden()
        case .album:
            Picker("Album", selection: $rule.album) {
                Text("Choose an Album").tag(AlbumID?.none)
                ForEach(library.albums.filter { !$0.isSmart }) { Text($0.name).tag(Optional($0.id)) }
            }
            .labelsHidden()
        case .name, .folder:
            TextField("Text", text: $rule.text).textFieldStyle(.roundedBorder)
        case .fileType:
            TextField("Extension, such as dng", text: $rule.text).textFieldStyle(.roundedBorder)
        case .captureDate:
            switch rule.op {
            case 1, 2:
                DatePicker("Date", selection: $rule.date, displayedComponents: .date).labelsHidden()
            case 3:
                TextField("Year", value: $rule.number, format: .number.grouping(.never))
                    .textFieldStyle(.roundedBorder).frame(width: 70)
            default:
                TextField("Days", value: $rule.number, format: .number).textFieldStyle(.roundedBorder).frame(width: 60)
                Text("days")
            }
        case .duration:
            TextField("Seconds", value: $rule.number, format: .number).textFieldStyle(.roundedBorder).frame(width: 60)
            Text("seconds")
        }
    }
}
