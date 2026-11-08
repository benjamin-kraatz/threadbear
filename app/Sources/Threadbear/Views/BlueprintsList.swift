import AppKit
import SwiftUI
import ThreadbearCore

/// The Blueprints view in the sidebar (docs/blueprints-design.md, "Where it
/// shows"): New blueprint at the top, then every blueprint by project and
/// by state, Waiting for you first. A row has the title, its state in words
/// and the cost so far, and opens the blueprint's thread, whose detail is
/// the form.
struct BlueprintsList: View {
    @Environment(AppModel.self) private var app
    @State private var creating = false

    var body: some View {
        let blueprints = app.allBlueprints
        let grouped = BlueprintGroup.grouped(blueprints, projectOrder: app.projects.map(\.id))
        VStack(spacing: 0) {
            ModeHeader(title: "Blueprints", count: app.blueprintsWaiting)
            SidebarButtonRow(icon: "plus", title: "New blueprint", tip: "Describe a feature and answer the agent's questions about it",
                             busy: app.isBusy(BusyKey.newBlueprint)) {
                creating = true
            }
            .padding(.horizontal, SidebarMetrics.outerInset)
            .popover(isPresented: $creating, arrowEdge: .trailing) {
                NewBlueprintForm { creating = false }
            }
            ScrollView {
                // Not lazy: a few dozen rows at most, and a lazy stack kept a
                // row's old state when it moved to another group.
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(grouped, id: \.projectId) { project in
                        Text(projectTitle(project.projectId))
                            .id("project/\(project.projectId)")
                            .font(.system(size: TypeScale.sidebarHeading, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .padding(.leading, SidebarMetrics.leading)
                            .padding(.top, zoomed(18))
                        // Ids unique across the whole stack: two projects
                        // each have a Ready heading.
                        ForEach(project.groups, id: \.group) { group in
                            SectionHeading(title: group.group.title) { EmptyView() }
                                .id("\(project.projectId)/\(group.group.rawValue)")
                            ForEach(group.blueprints) { blueprint in
                                BlueprintRow(blueprint: blueprint)
                                    .transition(Juice.row)
                            }
                        }
                    }
                    if blueprints.isEmpty {
                        EmptyNote(text: "No blueprints yet.")
                    }
                }
                .padding(.horizontal, SidebarMetrics.outerInset)
                .padding(.top, zoomed(4))
                .padding(.bottom, zoomed(32))
            }
            .scrollIndicators(.never)
            .onExitCommand { app.sidebarMode = .inbox }
        }
        .task { app.loadBlueprints() }
    }

    private func projectTitle(_ id: String) -> String {
        if id.isEmpty { return "No project" }
        return app.project(id)?.title ?? "Another project"
    }
}

/// One blueprint: its title, its state in words and what it has cost.
private struct BlueprintRow: View {
    @Environment(AppModel.self) private var app
    let blueprint: Blueprint
    @State private var hovering = false

    var body: some View {
        let selected = blueprint.threadId != nil && app.selection == blueprint.threadId
        VStack(alignment: .leading, spacing: zoomed(3)) {
            Text(blueprint.title.isEmpty ? "Untitled" : blueprint.title)
                .font(.system(size: TypeScale.sidebarTitle))
                .lineLimit(1)
            HStack(alignment: .firstTextBaseline) {
                Text(BlueprintText.state(blueprint))
                    .foregroundStyle(BlueprintLook.stateColor(blueprint))
                    .lineLimit(1)
                Spacer(minLength: zoomed(6))
                Text(BlueprintText.cost(blueprint.costUsd))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .font(.system(size: TypeScale.sidebarPreview))
        }
        .padding(EdgeInsets(top: zoomed(7), leading: SidebarMetrics.leading, bottom: zoomed(7), trailing: SidebarMetrics.trailing))
        .background(selected ? Color.primary.opacity(0.07) : hovering ? SidebarMetrics.hover : .clear,
                    in: RoundedRectangle(cornerRadius: SidebarMetrics.corner))
        .contentShape(RoundedRectangle(cornerRadius: SidebarMetrics.corner))
        .onHover { hovering = $0 }
        .onTapGesture { open() }
        .tip(blueprint.threadId == nil ? "Found in \((blueprint.path as NSString).abbreviatingWithTildeInPath), with no thread: start a build from its menu"
                                       : "Open the blueprint")
        .iconContextMenu {
            if blueprint.threadId != nil {
                Button("Open", systemImage: "list.bullet.rectangle") { open() }
            }
            if blueprint.status == .ready || blueprint.status == .building || blueprint.status == .done {
                Button("Start a thread", systemImage: "play") { app.startBlueprint(blueprint, mode: "thread", fromMenu: true) }
                    .disabled(app.isBusy(BusyKey.blueprintStart(blueprint.threadId ?? blueprint.id, "thread")))
                Button("Start with subagents", systemImage: "person.3") { app.startBlueprint(blueprint, mode: "subagents", fromMenu: true) }
                    .disabled(app.isBusy(BusyKey.blueprintStart(blueprint.threadId ?? blueprint.id, "subagents")))
            }
            if let threadId = blueprint.threadId {
                Divider()
                Button("Delete blueprint…", systemImage: "trash") { app.deleteBlueprint(threadId: threadId) }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { open() }
    }

    private func open() {
        guard let threadId = blueprint.threadId else { return }
        app.select(threadId)
    }
}

/// Colours a blueprint's state reads in, as the mockups have them.
enum BlueprintLook {
    static let waiting = Color(nsColor: .systemOrange)
    static let ready = Color(nsColor: .systemGreen)
    static let moving = Color(nsColor: .controlAccentColor)

    static func stateColor(_ blueprint: Blueprint) -> Color {
        if blueprint.tooSmall != nil, blueprint.rounds.isEmpty { return waiting }
        switch blueprint.status {
        case .waiting: return waiting
        case .drafting: return blueprint.specStale ? waiting : moving
        case .ready: return ready
        case .building: return moving
        case .done: return .secondary
        }
    }
}

/// New blueprint: which project (or a new one, with a title and a folder),
/// and the feature in a line or at length. Start makes it and opens it.
private struct NewBlueprintForm: View {
    @Environment(AppModel.self) private var app
    let close: () -> Void
    @State private var projectId: String = ""
    @State private var newTitle = ""
    @State private var newFolder = ""
    @State private var text = ""

    private static let newProject = "new"

    var body: some View {
        let projects = app.projects.filter { !$0.archived && !$0.folders.isEmpty }
        let isNew = projectId == Self.newProject
        let busy = app.isBusy(BusyKey.newBlueprint)
        let ready = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (isNew ? !newTitle.trimmingCharacters(in: .whitespaces).isEmpty && !newFolder.isEmpty : !projectId.isEmpty)
        VStack(alignment: .leading, spacing: zoomed(10)) {
            Text("New blueprint").font(.headline)
            Picker("Project", selection: $projectId) {
                ForEach(projects) { project in
                    Text(project.title).tag(project.id)
                }
                Divider()
                Text("New project…").tag(Self.newProject)
            }
            .tip("The project the blueprint is for; its spec goes in the project's folder")
            if isNew {
                TextField("Title", text: $newTitle)
                    .textFieldStyle(.roundedBorder)
                    .tip("The new project's name")
                HStack {
                    Text(newFolder.isEmpty ? "No folder chosen" : (newFolder as NSString).abbreviatingWithTildeInPath)
                        .foregroundStyle(newFolder.isEmpty ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Choose…") { chooseFolder() }
                        .tip("Pick the new project's folder")
                }
            }
            Text("What's the feature?")
                .font(.system(size: TypeScale.label))
                .foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.system(size: TypeScale.body))
                .frame(minHeight: zoomed(110))
                .scrollContentBackground(.hidden)
                .padding(zoomed(6))
                .background(Color(nsColor: Theme.codeBackground), in: RoundedRectangle(cornerRadius: zoomed(6)))
                .overlay(RoundedRectangle(cornerRadius: zoomed(6)).strokeBorder(Color(nsColor: Theme.cardBorder), lineWidth: 0.5))
                .tip("Describe it in a line or at length. The agent reads the code and asks what it needs to know.")
            HStack {
                Spacer()
                Button("Cancel") { close() }
                    .keyboardShortcut(.cancelAction)
                    .tip("Close without making a blueprint")
                Button("Start") { start(isNew: isNew) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!ready)
                    .busy(busy)
                    .tip("Make the blueprint and let the agent put its first questions")
            }
        }
        .padding(zoomed(16))
        .frame(width: zoomed(380))
        .onAppear {
            if projectId.isEmpty { projectId = projects.first?.id ?? Self.newProject }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            newFolder = url.path
            if newTitle.isEmpty { newTitle = url.lastPathComponent }
        }
    }

    private func start(isNew: Bool) {
        let description = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let project = isNew ? nil : projectId
        let made = isNew ? (title: newTitle.trimmingCharacters(in: .whitespaces), folder: newFolder) : nil
        app.createBlueprint(projectId: project, newProject: made, text: description) { ok in
            if ok { close() }
        }
    }
}

/// The detail area while the Blueprints view is open and none is picked.
struct BlueprintsHome: View {
    var body: some View {
        VStack(spacing: zoomed(8)) {
            Text("Pick a blueprint, or start a new one")
                .font(.system(size: TypeScale.body))
                .foregroundStyle(.secondary)
            Text("A blueprint plans a feature with you: describe it, answer the agent's questions, and it writes a spec into the repo to build from.")
                .font(.system(size: TypeScale.label))
                .foregroundStyle(SidebarMetrics.faint)
                .multilineTextAlignment(.center)
                .frame(maxWidth: zoomed(420))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
