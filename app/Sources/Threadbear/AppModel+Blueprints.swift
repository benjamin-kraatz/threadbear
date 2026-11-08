import AppKit
import Observation
import ThreadbearCore

// Blueprints (docs/blueprints-design.md, docs/protocol.md "Blueprints"): the
// list in the sidebar, the form in place of a blueprint thread's transcript,
// and the calls behind its buttons. Every call that changes something runs in
// `whileBusy` and its control wears `.busy(_:)` (EveryClickShowsTests); the
// answers themselves change on screen at once and save a moment later.

extension BusyKey {
    static let newBlueprint = "newBlueprint"
    static func blueprintContinue(_ threadId: String) -> String { "blueprintContinue/\(threadId)" }
    static func blueprintWriteNow(_ threadId: String) -> String { "blueprintWriteNow/\(threadId)" }
    static func blueprintSideChat(_ threadId: String, _ questionId: String) -> String { "blueprintSideChat/\(threadId)/\(questionId)" }
    static func blueprintAskInstead(_ threadId: String, _ assumptionId: String) -> String { "blueprintAskInstead/\(threadId)/\(assumptionId)" }
    static func blueprintCheck(_ threadId: String) -> String { "blueprintCheck/\(threadId)" }
    static func blueprintStart(_ threadId: String, _ mode: String) -> String { "blueprintStart/\(threadId)/\(mode)" }
    static func blueprintDiff(_ threadId: String) -> String { "blueprintDiff/\(threadId)" }
    static func blueprintTell(_ threadId: String) -> String { "blueprintTell/\(threadId)" }
    static func blueprintUpdateSpec(_ threadId: String) -> String { "blueprintUpdateSpec/\(threadId)" }
    static func blueprintTooSmall(_ threadId: String) -> String { "blueprintTooSmall/\(threadId)" }
    static func blueprintAskAnyway(_ threadId: String) -> String { "blueprintAskAnyway/\(threadId)" }
    static func blueprintSendChange(_ threadId: String) -> String { "blueprintSendChange/\(threadId)" }
    static func blueprintDelete(_ threadId: String) -> String { "blueprintDelete/\(threadId)" }
    static func blueprintUseProposal(_ sideChatId: String, _ questionId: String) -> String { "blueprintUseProposal/\(sideChatId)/\(questionId)" }
    /// One of a project's blueprint settings on its way: "folder", "dir" or "check".
    static func projectBlueprints(_ projectId: String, _ field: String) -> String { "projectBlueprints/\(projectId)/\(field)" }
}

/// The diff behind Show changes, while its sheet is up.
struct BlueprintDiffSheet: Identifiable, Equatable {
    var id: String { threadId }
    let threadId: String
    let title: String
    let path: String
    let hunks: [DiffHunk]
}

/// A blueprint form's state on screen: Mike's answers not saved yet, the
/// layout, what's folded. One per blueprint thread, kept while the app runs.
@MainActor @Observable
final class BlueprintFormState {
    let threadId: String
    /// Answers changed on screen, by round then question, over the
    /// summary's. A save that lands with the same answer takes it out.
    var edits: [String: [String: BlueprintAnswer]] = [:]
    /// The transcript in place of the form (the header's switch).
    var showsTranscript = false
    /// Rounds unfolded (or folded, for the open one) by a click, against
    /// what `BlueprintRules.foldedByDefault` says.
    var toggled: Set<String> = []
    /// Rounds whose assumptions strip is open.
    var assumptionsOpen: Set<String> = []
    /// One at a time: the round shown, by id; nil is the open one (or the last).
    var page: String?
    /// A question to bring into view and put the cursor in, with a count so
    /// the same one can be asked for twice.
    var focus: (question: String, tick: Int)?
    @ObservationIgnored var saves: [String: Task<Void, Never>] = [:]
    /// Tell the agent went: down until the runner clears editedByHand.
    var toldAgent = false
    /// Update the spec went: down until the runner clears specStale.
    var updatingSpec = false
    /// Ask me anyway went, for this too-small reason: down until the
    /// agent puts a round or gives another reason.
    var askedAnyway: String?

    init(threadId: String) {
        self.threadId = threadId
    }

    /// The answers on screen, by round id.
    func answers(for blueprint: Blueprint) -> [String: [String: BlueprintAnswer]] {
        var out: [String: [String: BlueprintAnswer]] = [:]
        for round in blueprint.rounds {
            var answers = round.answers
            for (question, answer) in edits[round.id] ?? [:] { answers[question] = answer }
            out[round.id] = answers
        }
        return out
    }

    func rules(for blueprint: Blueprint) -> BlueprintRules {
        BlueprintRules(blueprint: blueprint, answers: answers(for: blueprint))
    }

    func isFolded(_ round: BlueprintRound, rules: BlueprintRules) -> Bool {
        rules.foldedByDefault(round) != toggled.contains(round.id)
    }

    func requestFocus(_ questionId: String) {
        focus = (questionId, (focus?.tick ?? 0) + 1)
    }
}

/// Settings > General's "Show Blueprints": on by default. Off hides the
/// activity bar's button; a blueprint thread still opens as its form.
enum BlueprintsSetting {
    static let key = "showBlueprints"

    static var shown: Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }
}

/// Stacked or one round at a time, remembered for every blueprint.
enum BlueprintLayout: String {
    case stacked, oneAtATime

    static let key = "blueprintLayout"

    static var current: BlueprintLayout {
        get { BlueprintLayout(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .stacked }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
}

extension AppModel {
    // MARK: The list

    /// Every blueprint to list: those with a thread from its summary (live),
    /// then found ones from `blueprints.list`.
    var allBlueprints: [Blueprint] {
        var byId: [String: Blueprint] = [:]
        for blueprint in listedBlueprints { byId[blueprint.id] = blueprint }
        for thread in threads.values where thread.isBlueprint && thread.archivedAt == nil {
            guard var blueprint = thread.blueprint else { continue }
            if blueprint.threadId == nil { blueprint.threadId = thread.id }
            if blueprint.title.isEmpty { blueprint.title = thread.title }
            byId[blueprint.id] = blueprint
        }
        // A listed one whose thread is archived (deleted) isn't listed.
        return byId.values.filter { blueprint in
            guard let threadId = blueprint.threadId else { return true }
            return threads[threadId].map { $0.archivedAt == nil } ?? true
        }
    }

    /// How many blueprints wait on Mike, for the activity bar.
    var blueprintsWaiting: Int {
        allBlueprints.filter { BlueprintGroup($0) == .waiting }.count
    }

    func loadBlueprints() {
        guard let client else { return }
        Task {
            do {
                listedBlueprints = try await client.listBlueprints()
                blueprintsUnsupported = false
            } catch RPCError.server(let code, _) where code == RPCError.methodNotFound {
                // A runner from before blueprints: none of it shows, as
                // loadProjects does for projects.
                blueprintsUnsupported = true
                listedBlueprints = []
                showsBlueprintsHome = false
                if sidebarMode == .blueprints { sidebarMode = .inbox }
            } catch {
                AppLog.write("rpc", "blueprints.list: \(error.localizedDescription)")
            }
        }
    }

    func showBlueprints() {
        // Hidden in Settings: there's no Blueprints view to go to.
        guard BlueprintsSetting.shown else { return }
        sidebarMode = .blueprints
        openProjectId = nil
        // A blueprint already open stays; anything else gives way to
        // "Pick a blueprint".
        showsBlueprintsHome = selectedThread?.isBlueprint != true
        loadBlueprints()
    }

    /// A blueprint thread's summary came in: buttons waiting for a flag to
    /// clear come back once it has.
    func blueprintSummaryChanged(_ thread: ThreadSummary) {
        guard let form = blueprintForms[thread.id], let blueprint = thread.blueprint else { return }
        if !blueprint.editedByHand, form.toldAgent { form.toldAgent = false }
        if !blueprint.specStale, form.updatingSpec { form.updatingSpec = false }
        if let asked = form.askedAnyway, !blueprint.rounds.isEmpty || blueprint.tooSmall != asked { form.askedAnyway = nil }
    }

    func blueprintForm(_ threadId: String) -> BlueprintFormState {
        if let form = blueprintForms[threadId] { return form }
        let made = BlueprintFormState(threadId: threadId)
        blueprintForms[threadId] = made
        return made
    }

    /// A reply's blueprint onto its thread's summary, so the form has it
    /// before the thread.updated that follows.
    func apply(_ blueprint: Blueprint?) {
        guard let blueprint else { return }
        if let index = listedBlueprints.firstIndex(where: { $0.id == blueprint.id }) { listedBlueprints[index] = blueprint }
        guard let threadId = blueprint.threadId, var thread = threads[threadId] else { return }
        if let old = thread.blueprint, let was = old.updatedAt, let now = blueprint.updatedAt, now < was { return }
        thread.blueprint = blueprint
        threads[threadId] = thread
        blueprintSummaryChanged(thread)
        // Answers now saved as they're shown aren't edits any more.
        if let form = blueprintForms[threadId] {
            for round in blueprint.rounds {
                guard var edits = form.edits[round.id] else { continue }
                for (question, answer) in edits where answer.sameAnswer(as: round.answers[question]) { edits[question] = nil }
                form.edits[round.id] = edits.isEmpty ? nil : edits
            }
        }
    }

    // MARK: New blueprint

    /// Makes a blueprint and opens it. `newProject` makes the project first.
    func createBlueprint(projectId: String?, newProject: (title: String, folder: String)?, text: String, done: @escaping @MainActor (Bool) -> Void) {
        guard let client else { return }
        whileBusy(BusyKey.newBlueprint) { [self] in
            do {
                let made = try await client.createBlueprint(NewBlueprintRequest(projectId: projectId, newProject: newProject, text: text))
                if let thread = made.thread { receive(thread) }
                apply(made.blueprint)
                if let threadId = made.thread?.id ?? made.blueprint?.threadId { select(threadId) }
                if newProject != nil { loadProjects() }
                loadBlueprints()
                done(true)
            } catch {
                show(error)
                done(false)
            }
        }
    }

    // MARK: Answers

    /// An answer changed on screen: shown at once, saved a moment later
    /// (or kept on screen only, while answers are locked).
    func setBlueprintAnswer(threadId: String, roundId: String, questionId: String, _ answer: BlueprintAnswer?) {
        let form = blueprintForm(threadId)
        var edits = form.edits[roundId] ?? [:]
        let round = threads[threadId]?.blueprint?.rounds.first(where: { $0.id == roundId })
        // Kept to the question: "Not chosen" is no answer, a number stays
        // in its range.
        var given = answer?.normalized(for: round?.questions.first { $0.id == questionId }) ?? BlueprintAnswer()
        if let round, round.isSent {
            given.changedAt = round.isChanged(questionId, shown: given) ? Date() : nil
        }
        edits[questionId] = given
        form.edits[roundId] = edits
        scheduleBlueprintSave(threadId: threadId, roundId: roundId)
    }

    private func scheduleBlueprintSave(threadId: String, roundId: String) {
        guard let blueprint = threads[threadId]?.blueprint else { return }
        // Building or done: a change goes to the build thread as a message.
        guard BlueprintRules(blueprint: blueprint).answering != .locked else { return }
        let form = blueprintForm(threadId)
        form.saves[roundId]?.cancel()
        form.saves[roundId] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            self?.saveBlueprintDraft(threadId: threadId, roundId: roundId)
        }
    }

    /// The autosave. Not a click: the answer is on screen already, and a
    /// failure says so in the banner.
    func saveBlueprintDraft(threadId: String, roundId: String) {
        guard let client, let blueprint = threads[threadId]?.blueprint,
              let round = blueprint.rounds.first(where: { $0.id == roundId }) else { return }
        let form = blueprintForm(threadId)
        let answers = form.rules(for: blueprint).outgoing(round)
        let sentEdits = form.edits[roundId] ?? [:]
        Task {
            do {
                let saved = try await client.saveBlueprintDraft(id: blueprint.id, roundId: roundId, answers: answers)
                landed(saved, threadId: threadId, roundId: roundId, sentEdits: sentEdits)
            } catch {
                show(error)
            }
        }
    }

    /// A reply to answers sent: edits still as they were sent give way to
    /// what the runner kept (an upload's path rewritten into the
    /// blueprint's attachments, say), so they aren't sent again; anything
    /// typed since stays.
    private func landed(_ blueprint: Blueprint?, threadId: String, roundId: String, sentEdits: [String: BlueprintAnswer]) {
        let form = blueprintForm(threadId)
        if var edits = form.edits[roundId] {
            for (question, sent) in sentEdits where edits[question] == sent { edits[question] = nil }
            form.edits[roundId] = edits.isEmpty ? nil : edits
        }
        apply(blueprint)
    }

    /// Continue: the open round's answers (and any sent round's changes)
    /// to the agent, with the composer's text as the note. When it can't go
    /// yet, the cursor goes to the first question still needing an answer.
    func continueBlueprint(threadId: String, writeNow: Bool = false) {
        guard let client, let blueprint = threads[threadId]?.blueprint else { return }
        let form = blueprintForm(threadId)
        let rules = form.rules(for: blueprint)
        guard rules.showsContinue else { return }
        guard rules.canContinue else {
            if let round = rules.openRound, let first = rules.unanswered(in: round).first { form.requestFocus(first.id) }
            return
        }
        let note = blueprintNote(threadId)
        let typed = drafts[threadId]?.text
        let key = writeNow ? BusyKey.blueprintWriteNow(threadId) : BusyKey.blueprintContinue(threadId)
        guard !isContinuingBlueprint(threadId) else { return }
        let plan = rules.continuePlan
        whileBusy(key) { [self] in
            for (_, save) in form.saves { save.cancel() }
            form.saves = [:]
            do {
                // Earlier rounds' changes are saved; the runner puts them in
                // the open round's message, so one message goes.
                for round in plan.saveFirst {
                    let sentEdits = form.edits[round.id] ?? [:]
                    let saved = try await client.saveBlueprintDraft(id: blueprint.id, roundId: round.id, answers: rules.outgoing(round))
                    landed(saved, threadId: threadId, roundId: round.id, sentEdits: sentEdits)
                }
                for (index, round) in plan.send.enumerated() {
                    let last = index == plan.send.count - 1
                    let sentEdits = form.edits[round.id] ?? [:]
                    let latest = try await client.continueBlueprint(id: blueprint.id, roundId: round.id, answers: rules.outgoing(round),
                                                                   note: last ? note : nil, writeNow: last && writeNow)
                    landed(latest, threadId: threadId, roundId: round.id, sentEdits: sentEdits)
                }
                // The note went with the answers: the box empties, unless
                // something new was typed in it meanwhile.
                // Pictures already in it stay (they can't go with a note).
                if note != nil, let draft = drafts[threadId], draft.text == typed {
                    drafts[threadId] = draft.images.isEmpty ? nil : Draft(text: "", images: draft.images)
                }
            } catch {
                show(error)
            }
        }
    }

    /// Continue or Write it now is on its way: both show it.
    func isContinuingBlueprint(_ threadId: String) -> Bool {
        isBusy(BusyKey.blueprintContinue(threadId)) || isBusy(BusyKey.blueprintWriteNow(threadId))
    }

    /// The composer's text, without its pictures' marks.
    private func blueprintNote(_ threadId: String) -> String? {
        let text = (drafts[threadId]?.text ?? "").unicodeScalars.filter { $0 != InlinePictures.mark }
        let note = String(String.UnicodeScalarView(text)).trimmingCharacters(in: .whitespacesAndNewlines)
        return note.isEmpty ? nil : note
    }

    /// Return in the composer while a round is open: what Continue does
    /// when it can, else the cursor to the first unanswered question. True
    /// when the form took the key.
    func blueprintReturn(threadId: String) -> Bool {
        guard let blueprint = threads[threadId]?.blueprint else { return false }
        let rules = blueprintForm(threadId).rules(for: blueprint)
        guard rules.composerTakesNote else { return false }
        continueBlueprint(threadId: threadId)
        return true
    }

    func askInstead(threadId: String, roundId: String, assumptionId: String) {
        guard let client, let blueprint = threads[threadId]?.blueprint else { return }
        whileBusy(BusyKey.blueprintAskInstead(threadId, assumptionId)) { [self] in
            do {
                apply(try await client.askInstead(blueprintId: blueprint.id, roundId: roundId, assumptionId: assumptionId))
            } catch {
                show(error)
            }
        }
    }

    /// Ask about this: the question's side chat, in a panel beside.
    func openSideChat(threadId: String, questionId: String) {
        guard let client, let blueprint = threads[threadId]?.blueprint else { return }
        if let existing = blueprint.sideChats[questionId], threads[existing] != nil {
            openThreadInPanel(existing)
            return
        }
        whileBusy(BusyKey.blueprintSideChat(threadId, questionId)) { [self] in
            do {
                let chat = try await client.blueprintSideChat(id: blueprint.id, questionId: questionId)
                openThreadInPanel(chat)
            } catch {
                show(error)
            }
        }
    }

    /// Use on a side chat's proposal: the answer goes into the blueprint's
    /// draft, marked from side chat. Anything typed for that question on
    /// screen gives way to it.
    func useBlueprintProposal(sideChat: ThreadSummary, proposal: BlueprintProposal) {
        guard let client, let parentId = sideChat.parentThreadId, let blueprint = threads[parentId]?.blueprint else { return }
        whileBusy(BusyKey.blueprintUseProposal(sideChat.id, proposal.questionId)) { [self] in
            do {
                let used = try await client.useBlueprintProposal(id: blueprint.id, questionId: proposal.questionId, answer: proposal.answer)
                let form = blueprintForm(parentId)
                for round in blueprint.rounds where round.questions.contains(where: { $0.id == proposal.questionId }) {
                    form.edits[round.id]?[proposal.questionId] = nil
                    if form.edits[round.id]?.isEmpty == true { form.edits[round.id] = nil }
                }
                apply(used)
            } catch {
                show(error)
            }
        }
    }

    // MARK: Project settings

    /// A project's blueprint settings, whole (`projects.update`'s
    /// `blueprints`), from its page. `field` says which control spins.
    func setProjectBlueprints(_ projectId: String, _ settings: ProjectBlueprints, field: String) {
        guard let client else { return }
        whileBusy(BusyKey.projectBlueprints(projectId, field)) { [self] in
            do {
                let updated = try await client.updateProject(projectId, ProjectUpdate(blueprints: settings))
                if let index = projects.firstIndex(where: { $0.id == updated.id }) { projects[index] = updated }
            } catch {
                show(error)
            }
        }
    }

    // MARK: The spec

    func checkBlueprint(threadId: String) {
        guard let client, let blueprint = threads[threadId]?.blueprint else { return }
        whileBusy(BusyKey.blueprintCheck(threadId)) { [self] in
            do {
                _ = try await client.checkBlueprint(id: blueprint.id)
                flashDone("Checking the spec")
            } catch {
                show(error)
            }
        }
    }

    /// A build thread from the spec, opened beside the blueprint.
    /// `fromMenu`: a row's menu, which can't spin, so the banner says it.
    func startBlueprint(_ blueprint: Blueprint, mode: String, fromMenu: Bool = false) {
        guard let client else { return }
        let key = BusyKey.blueprintStart(blueprint.threadId ?? blueprint.id, mode)
        whileBusy(key, note: fromMenu ? "Starting the build…" : nil) { [self] in
            do {
                let threadId = try await client.startBlueprint(id: blueprint.id, mode: mode)
                if blueprint.threadId != nil, selection == blueprint.threadId {
                    openThreadInPanel(threadId)
                } else {
                    sidebarMode = .inbox
                    select(threadId)
                }
            } catch {
                show(error)
            }
        }
    }

    func showBlueprintDiff(threadId: String) {
        guard let client, let blueprint = threads[threadId]?.blueprint else { return }
        whileBusy(BusyKey.blueprintDiff(threadId)) { [self] in
            do {
                let hunks = try await client.blueprintDiff(id: blueprint.id)
                blueprintDiff = BlueprintDiffSheet(threadId: threadId, title: blueprint.title,
                                                   path: (blueprint.path as NSString).appendingPathComponent("spec.md"), hunks: hunks)
            } catch {
                show(error)
            }
        }
    }

    func tellBlueprintAgent(threadId: String) {
        guard let client, let blueprint = threads[threadId]?.blueprint else { return }
        whileBusy(BusyKey.blueprintTell(threadId)) { [self] in
            do {
                try await client.tellBlueprintAgent(id: blueprint.id)
                blueprintForm(threadId).toldAgent = true
                if blueprintDiff?.threadId == threadId { blueprintDiff = nil }
            } catch {
                show(error)
            }
        }
    }

    func updateBlueprintSpec(threadId: String) {
        guard let client, let blueprint = threads[threadId]?.blueprint else { return }
        let form = blueprintForm(threadId)
        whileBusy(BusyKey.blueprintUpdateSpec(threadId)) { [self] in
            // What's on screen is saved first, so the runner sends it all.
            for (_, save) in form.saves { save.cancel() }
            let rules = form.rules(for: blueprint)
            for round in blueprint.rounds where form.edits[round.id] != nil {
                let sentEdits = form.edits[round.id] ?? [:]
                do {
                    let saved = try await client.saveBlueprintDraft(id: blueprint.id, roundId: round.id, answers: rules.outgoing(round))
                    landed(saved, threadId: threadId, roundId: round.id, sentEdits: sentEdits)
                } catch {
                    show(error)
                    return
                }
            }
            form.saves = [:]
            do {
                try await client.updateBlueprintSpec(id: blueprint.id)
                // Stays spinning until the runner clears specStale.
                form.updatingSpec = true
            } catch {
                show(error)
            }
        }
    }

    /// Building or done: changed answers go to the newest build thread.
    func sendBlueprintChange(threadId: String) {
        guard let client, let blueprint = threads[threadId]?.blueprint else { return }
        let form = blueprintForm(threadId)
        let rules = form.rules(for: blueprint)
        guard let build = blueprint.newestBuild, rules.showsSendChange else { return }
        let text = rules.changeMessage()
        let sentEdits = form.edits
        whileBusy(BusyKey.blueprintSendChange(threadId)) { [self] in
            do {
                try await client.send(threadId: build.threadId, text: text)
                // Locked answers are never saved: what was sent is done with,
                // anything changed since stays.
                for (roundId, edits) in sentEdits {
                    guard var now = form.edits[roundId] else { continue }
                    for (question, sent) in edits where now[question] == sent { now[question] = nil }
                    form.edits[roundId] = now.isEmpty ? nil : now
                }
                flashDone("Sent to the build thread")
            } catch {
                show(error)
            }
        }
    }

    // MARK: Too small

    func tooSmallStart(threadId: String) {
        guard let client, let blueprint = threads[threadId]?.blueprint else { return }
        whileBusy(BusyKey.blueprintTooSmall(threadId)) { [self] in
            do {
                let started = try await client.tooSmallStart(id: blueprint.id)
                sidebarMode = .inbox
                select(started)
            } catch {
                show(error)
            }
        }
    }

    func askMeAnyway(threadId: String) {
        guard let client else { return }
        let why = threads[threadId]?.blueprint?.tooSmall
        whileBusy(BusyKey.blueprintAskAnyway(threadId)) { [self] in
            do {
                try await client.send(threadId: threadId, text: "Ask me anyway")
                // Stays down until the agent answers with a round, or says
                // it's small again for another reason.
                blueprintForm(threadId).askedAnyway = why ?? ""
            } catch {
                show(error)
            }
        }
    }

    // MARK: Delete

    /// Asks first, in the design's words, then removes the folder and
    /// archives the thread.
    func deleteBlueprint(threadId: String) {
        guard let client, let blueprint = threads[threadId]?.blueprint else { return }
        let alert = NSAlert()
        alert.messageText = BlueprintAppText.deletePrompt(blueprint)
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        whileBusy(BusyKey.blueprintDelete(threadId), note: "Deleting the blueprint…") { [self] in
            do {
                try await client.deleteBlueprint(id: blueprint.id)
                listedBlueprints.removeAll { $0.id == blueprint.id }
                if selection == threadId { select(nil) }
            } catch {
                show(error)
            }
        }
    }
}

/// Words the app writes about a blueprint.
enum BlueprintAppText {
    /// "Delete <title>? This removes `.threadbear/blueprints/<slug>` from
    /// <folder> and archives its thread." (docs/blueprints-design.md, "Delete")
    static func deletePrompt(_ blueprint: Blueprint) -> String {
        let base = blueprint.folder.hasSuffix("/") ? blueprint.folder : blueprint.folder + "/"
        let relative = !blueprint.folder.isEmpty && blueprint.path.hasPrefix(base) ? String(blueprint.path.dropFirst(base.count)) : blueprint.path
        let title = blueprint.title.isEmpty ? "this blueprint" : blueprint.title
        let folder = (blueprint.folder as NSString).abbreviatingWithTildeInPath
        return "Delete \(title)? This removes `\(relative)` from \(folder) and archives its thread."
    }
}
