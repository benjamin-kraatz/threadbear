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

    var body: some View {
        let blueprints = app.allBlueprints
        let grouped = BlueprintGroup.grouped(blueprints, projectOrder: app.projects.map(\.id))
        VStack(spacing: 0) {
            ModeHeader(title: "Blueprints", count: app.blueprintsWaiting)
            SidebarButtonRow(icon: "plus", title: "New blueprint", tip: "Describe a feature and answer the agent's questions about it",
                             active: app.showsBlueprintsHome && app.selection == nil, busy: app.isBusy(BusyKey.newBlueprint)) {
                app.newBlueprint()
            }
            .padding(.horizontal, SidebarMetrics.outerInset)
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

/// The New blueprint page, in the detail area while the Blueprints view is
/// open and no blueprint is picked: which project (or a new one, with a
/// title and a folder), and the feature in a line or at length. Start makes
/// it and opens it. What's typed stays while Mike looks around.
struct BlueprintsHome: View {
    @Environment(AppModel.self) private var app
    @FocusState private var describing: Bool

    var body: some View {
        @Bindable var app = app
        let draft = app.newBlueprintDraft
        let projects = app.projects.filter { !$0.archived }
        let isNew = draft.projectId == NewBlueprintDraft.newProject
        let picked = projects.first { $0.id == draft.projectId }
        let noFolders = picked.map { $0.folders.isEmpty } ?? false
        let busy = app.isBusy(BusyKey.newBlueprint)
        let ready = !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (isNew ? !draft.newTitle.trimmingCharacters(in: .whitespaces).isEmpty && !draft.newFolder.isEmpty
                      : picked != nil && !noFolders)
        ScrollView {
            VStack(alignment: .leading, spacing: zoomed(14)) {
                VStack(alignment: .leading, spacing: zoomed(6)) {
                    Text("New blueprint")
                        .font(.system(size: TypeScale.headings.0, weight: .semibold))
                    Text("Describe a feature. The agent reads the code, asks you rounds of questions and writes a spec into the repo.")
                        .font(.system(size: TypeScale.label))
                        .foregroundStyle(Color(nsColor: Theme.faintText))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.bottom, zoomed(6))
                field("Project") {
                    Picker("Project", selection: $app.newBlueprintDraft.projectId) {
                        if draft.projectId.isEmpty { Text("Pick a project").tag("") }
                        ForEach(projects) { project in Text(project.title).tag(project.id) }
                        Divider()
                        Text("New project…").tag(NewBlueprintDraft.newProject)
                    }
                    .labelsHidden()
                    .fixedSize()
                    .tip("The project the blueprint is for; its spec goes in the project's folder")
                }
                if isNew {
                    field("Title") {
                        TextField("The new project's name", text: $app.newBlueprintDraft.newTitle)
                            .textFieldStyle(.roundedBorder)
                            .tip("The new project's name")
                    }
                    field("Folder") {
                        HStack(spacing: zoomed(10)) {
                            Text(draft.newFolder.isEmpty ? "No folder chosen" : draft.newFolder.abbreviatingHome)
                                .foregroundStyle(draft.newFolder.isEmpty ? .secondary : .primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button("Choose…") { chooseFolder() }
                                .tip("Pick the new project's folder: the spec is written into it")
                            Spacer(minLength: 0)
                        }
                    }
                } else if let picked {
                    field("Folder") {
                        VStack(alignment: .leading, spacing: zoomed(4)) {
                            if let folder = ProjectBlueprints.folder(of: picked) {
                                Text(folder.abbreviatingHome)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .tip("Where the spec is written; change it on the project's page")
                            } else {
                                Text("\(picked.title) has no folders yet. Add one on its page, or pick New project.")
                                    .foregroundStyle(.orange)
                                    .fixedSize(horizontal: false, vertical: true)
                                Button("Open \(picked.title)") { app.openProjectPage(picked.id) }
                                    .buttonStyle(.link)
                                    .tip("The project's page, where folders are added")
                            }
                        }
                    }
                }
                Text("What's the feature?")
                    .font(.system(size: TypeScale.label, weight: .medium))
                    .padding(.top, zoomed(4))
                TextEditor(text: $app.newBlueprintDraft.text)
                    .font(.system(size: TypeScale.body))
                    .focused($describing)
                    .frame(minHeight: zoomed(160))
                    .scrollContentBackground(.hidden)
                    .padding(zoomed(8))
                    .background(Color(nsColor: Theme.codeBackground), in: RoundedRectangle(cornerRadius: zoomed(8)))
                    .overlay(RoundedRectangle(cornerRadius: zoomed(8)).strokeBorder(Color(nsColor: describing ? .controlAccentColor : Theme.cardBorder),
                                                                                      lineWidth: describing ? 1 : 0.5))
                    .tip("Describe it in a line or at length. The agent reads the code and asks what it needs to know.")
                HStack {
                    Button("Start") { start() }
                        .buttonStyle(BlueprintButtonStyle(kind: .primary, large: true))
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(!ready)
                        .busy(busy)
                        .tip(ready ? "Make the blueprint and let the agent put its first questions"
                                   : "Pick a project with a folder (or make one) and describe the feature first")
                    Spacer()
                }
                .padding(.top, zoomed(4))
            }
            .frame(maxWidth: zoomed(560), alignment: .leading)
            .padding(.horizontal, zoomed(32))
            .padding(.vertical, zoomed(40))
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            if app.newBlueprintDraft.projectId.isEmpty, let first = projects.first(where: { !$0.folders.isEmpty }) ?? projects.first {
                app.newBlueprintDraft.projectId = first.id
            }
            describing = true
        }
        .onChange(of: app.newBlueprintFocus) { _, _ in describing = true }
    }

    private func field<Control: View>(_ title: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: zoomed(12)) {
            Text(title)
                .font(.system(size: TypeScale.label))
                .foregroundStyle(.secondary)
                .frame(width: zoomed(64), alignment: .leading)
            control()
        }
        .font(.system(size: TypeScale.label))
    }

    /// As a sheet on the window, so nothing under it closes; the folder's
    /// name fills an empty title.
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "The new project's folder"
        let app = app
        let picked: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                app.newBlueprintDraft.newFolder = url.path
                if app.newBlueprintDraft.newTitle.trimmingCharacters(in: .whitespaces).isEmpty {
                    app.newBlueprintDraft.newTitle = url.lastPathComponent
                }
            }
        }
        if let window = MainWindowFrame.window {
            panel.beginSheetModal(for: window, completionHandler: picked)
        } else {
            picked(panel.runModal())
        }
    }

    private func start() {
        let draft = app.newBlueprintDraft
        let isNew = draft.projectId == NewBlueprintDraft.newProject
        let description = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let made = isNew ? (title: draft.newTitle.trimmingCharacters(in: .whitespaces), folder: draft.newFolder) : nil
        app.createBlueprint(projectId: isNew ? nil : draft.projectId, newProject: made, text: description) { _ in }
    }
}
