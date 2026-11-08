import Foundation

/// The words a blueprint's state reads as, in the Blueprints list and the
/// form's header (docs/blueprints-design.md, "Where it shows").
public enum BlueprintText {
    /// "Round 2 waiting", "Drafting", "Ready", "Step 2 of 5", "Done",
    /// "Too small". `forYou` adds " for you" to a waiting round, as the
    /// header has it.
    public static func state(_ blueprint: Blueprint, forYou: Bool = false) -> String {
        if blueprint.tooSmall != nil, blueprint.rounds.isEmpty { return "Too small" }
        switch blueprint.status {
        case .waiting:
            guard let open = blueprint.openRound else { return forYou ? "Waiting for you" : "Waiting" }
            let name = open.isCheck ? "Check round" : "Round \(roundNumber(of: open, in: blueprint))"
            return name + (forYou ? " waiting for you" : " waiting")
        case .drafting: return "Drafting"
        case .ready: return "Ready"
        case .building:
            let total = blueprint.steps.count
            guard total > 0 else { return "Building" }
            return "Step \(min(blueprint.doneSteps + 1, total)) of \(total)"
        case .done: return "Done"
        }
    }

    /// The round's number among the question rounds; check rounds aren't
    /// counted.
    public static func roundNumber(of round: BlueprintRound, in blueprint: Blueprint) -> Int {
        let questionRounds = blueprint.rounds.filter { !$0.isCheck }
        return (questionRounds.firstIndex { $0.id == round.id } ?? questionRounds.count) + 1
    }

    /// "Round 2: How presets behave", or "Check round: what the check found".
    public static func title(of round: BlueprintRound, in blueprint: Blueprint) -> String {
        let name = round.isCheck ? "Check round" : "Round \(roundNumber(of: round, in: blueprint))"
        return round.title.isEmpty ? name : "\(name): \(round.title)"
    }

    /// A folded round's line: "6 answered, 1 you decide", "4 answered, 1 changed".
    public static func tally(_ round: BlueprintRound, answers: [String: BlueprintAnswer]) -> String {
        let live = round.questions.filter { $0.moot == nil }
        var answered = 0
        var decide = 0
        var changed = 0
        for question in live {
            guard let answer = answers[question.id], answer.isGiven else { continue }
            if answer.youDecide, answer.value?.isEmpty ?? true { decide += 1 } else { answered += 1 }
            if round.isChanged(question.id, shown: answer) { changed += 1 }
        }
        var parts = ["\(answered) answered"]
        if decide > 0 { parts.append("\(decide) you decide") }
        if changed > 0, round.isSent { parts.append("\(changed) changed") }
        let open = live.count - answered - decide
        if open > 0, !round.isSent { parts.append("\(open) open") }
        return parts.joined(separator: ", ")
    }

    /// The line under the last round while the agent works on the next:
    /// "Working for 12s · Reading snooze.ts". The action is the transcript's
    /// live one (`TranscriptModel.liveAction`), nil between steps.
    public static func working(elapsed: String, action: String?) -> String {
        let head = "Working for " + elapsed
        guard let action, !action.isEmpty else { return head }
        return head + " · " + action
    }

    /// Dollars, as the sidebar shows cost: "$0.84".
    public static func cost(_ usd: Double) -> String {
        guard usd.isFinite, usd > 0 else { return "$0.00" }
        return String(format: "$%.2f", usd)
    }

    /// A number without a trailing ".0".
    public static func number(_ value: Double) -> String {
        guard value.isFinite else { return "" }
        if value.rounded() == value, abs(value) < 1e15 { return String(Int(value)) }
        return String(value)
    }
}

/// What the form can do, worked out from the blueprint and the answers on
/// screen, so it's tested without drawing anything.
public struct BlueprintRules: Sendable, Equatable {
    /// How answers behave in each status (docs/blueprints-design.md,
    /// "Changing an answer").
    public enum Answering: Sendable, Equatable {
        /// Drafting or waiting: change anything, Continue sends it.
        case open
        /// Ready: a change makes the spec stale; "Update the spec" sends it.
        case staleable
        /// Building or done: answers are locked; a change goes to the build
        /// thread as a message.
        case locked
        /// Found in a folder with no state, or too small: nothing to answer.
        case none
    }

    public var blueprint: Blueprint
    /// The answers on screen by round id: the summary's, with Mike's edits
    /// not yet saved over them.
    public var answers: [String: [String: BlueprintAnswer]]

    public init(blueprint: Blueprint, answers: [String: [String: BlueprintAnswer]] = [:]) {
        self.blueprint = blueprint
        self.answers = answers
    }

    /// The agent is at work on the blueprint: its thread has a turn running
    /// (or starting). Not `.waiting`, which is a card in the transcript
    /// waiting on Mike, and not idle between rounds, when the form waits.
    /// The header's state, the row in the list and the working line under
    /// the rounds all go by this one answer.
    public static func agentWorking(_ status: ThreadStatus) -> Bool {
        status == .running || status == .starting
    }

    public var answering: Answering {
        if blueprint.threadId == nil { return .none }
        if blueprint.tooSmall != nil, blueprint.rounds.isEmpty { return .none }
        switch blueprint.status {
        case .drafting, .waiting: return .open
        case .ready: return .staleable
        case .building, .done: return .locked
        }
    }

    /// A round's answers as shown.
    public func answers(of round: BlueprintRound) -> [String: BlueprintAnswer] {
        answers[round.id] ?? round.answers
    }

    /// Needs-you questions in the round with nothing given yet, in order.
    public func unanswered(in round: BlueprintRound) -> [BlueprintQuestion] {
        let given = answers(of: round)
        return round.questions.filter { $0.needsYou && !(given[$0.id]?.isGiven ?? false) }
    }

    /// The round waiting for answers.
    public var openRound: BlueprintRound? { answering == .open ? blueprint.openRound : nil }

    /// Earlier, sent rounds with an answer changed since they were sent.
    public var changedRounds: [BlueprintRound] {
        blueprint.rounds.filter { $0.isSent && hasChanges(in: $0) }
    }

    /// Any answer in a sent round differs from what was sent, or the runner
    /// has marked one changed.
    public func hasChanges(in round: BlueprintRound) -> Bool {
        !changedQuestions(in: round).isEmpty
    }

    /// The changes in a sent round, question by question, as shown.
    public func changedQuestions(in round: BlueprintRound) -> [BlueprintQuestion] {
        guard round.isSent else { return [] }
        let shown = answers(of: round)
        return round.questions.filter { round.isChanged($0.id, shown: shown[$0.id]) }
    }

    /// A round's answers as they may go to the runner: each kept to its
    /// question (no empty values, numbers in range), and none for one
    /// that says nothing.
    public func outgoing(_ round: BlueprintRound) -> [String: BlueprintAnswer] {
        var out: [String: BlueprintAnswer] = [:]
        for (id, answer) in answers(of: round) {
            if let kept = answer.normalized(for: round.questions.first { $0.id == id }) { out[id] = kept }
        }
        return out
    }

    /// What Continue sends. With a round open, only that one: the runner
    /// folds earlier rounds' saved changes into its message, so they're
    /// saved first (`saveFirst`) rather than sent on their own. With none
    /// open, each changed round is sent.
    public var continuePlan: (saveFirst: [BlueprintRound], send: [BlueprintRound]) {
        if let open = openRound { return (changedRounds, [open]) }
        return ([], changedRounds)
    }

    /// Continue is there: a round is open, or a sent one changed before the
    /// spec was written.
    public var showsContinue: Bool { answering == .open && (openRound != nil || !changedRounds.isEmpty) }

    /// Continue can be pressed: every needs-you question of the open round
    /// has an answer (an open question left empty is "you decide").
    public var canContinue: Bool {
        guard showsContinue else { return false }
        guard let round = openRound else { return true }
        return unanswered(in: round).isEmpty
    }

    /// "Continue with changes" once a sent answer changed.
    public var continueTitle: String { answering == .open && !changedRounds.isEmpty ? "Continue with changes" : "Continue" }

    /// "Write it now" from round two on, while a round is open.
    public var showsWriteNow: Bool {
        guard let round = openRound else { return false }
        return blueprint.rounds.firstIndex { $0.id == round.id }.map { $0 >= 1 } ?? false
    }

    /// The composer's placeholder and Return go to the form.
    public var composerTakesNote: Bool { openRound != nil }

    /// The start row: Ready, or building or done (to start another).
    public var showsStart: Bool {
        guard blueprint.status == .ready || blueprint.status == .building || blueprint.status == .done else { return false }
        return !blueprint.specStale
    }

    /// "Check the spec" in the start row.
    public var showsCheck: Bool { showsStart && blueprint.threadId != nil }

    /// "Checked, nothing found".
    public var checkedClean: Bool { blueprint.checked.map { $0.findings == 0 } ?? false }

    /// The banner for answers changed after the spec was written.
    public var showsStaleBanner: Bool { blueprint.specStale || (answering == .staleable && !changedRounds.isEmpty) }

    public var showsEditedBanner: Bool { blueprint.editedByHand }

    /// The too-small card in place of the form.
    public var showsTooSmall: Bool { blueprint.tooSmall != nil && blueprint.rounds.isEmpty }

    /// "Send a change to the build thread": answers changed while building
    /// or done, and there's a build thread to tell.
    public var showsSendChange: Bool { answering == .locked && blueprint.newestBuild != nil && !changedRounds.isEmpty }

    /// Rounds folded by default: all but the open one; every one once the
    /// spec is written.
    public func foldedByDefault(_ round: BlueprintRound) -> Bool {
        round.id != openRound?.id
    }

    /// The text sent to the build thread for changed answers: each question
    /// with both answers.
    public func changeMessage() -> String {
        var lines = ["I changed answers in the blueprint \"\(blueprint.title)\" after the spec was written:"]
        for round in changedRounds {
            let shown = answers(of: round)
            for question in changedQuestions(in: round) {
                let was = question.describe(round.sentAnswer(question.id))
                let now = question.describe(shown[question.id])
                lines.append("- \(question.text) Was: \(was). Now: \(now).")
            }
        }
        lines.append("Change the build to match, and say what that changes.")
        return lines.joined(separator: "\n")
    }

    /// "Round 2, question 4 changed from 4 to 5 after the spec was written."
    public func staleLine() -> String {
        var parts: [String] = []
        for round in blueprint.rounds where round.isSent {
            let shown = answers(of: round)
            for question in changedQuestions(in: round) {
                let number = (round.questions.firstIndex { $0.id == question.id } ?? 0) + 1
                let name = round.isCheck ? "Check round" : "Round \(BlueprintText.roundNumber(of: round, in: blueprint))"
                parts.append("\(name), question \(number) changed from \(question.describe(round.sentAnswer(question.id))) to \(question.describe(shown[question.id]))")
            }
        }
        if parts.isEmpty { return "An answer changed after the spec was written." }
        return parts.prefix(2).joined(separator: "; ") + (parts.count > 2 ? " and \(parts.count - 2) more" : "") + " after the spec was written."
    }
}

/// Where a blueprint goes in the Blueprints list, top to bottom.
public enum BlueprintGroup: String, Sendable, CaseIterable {
    case waiting, drafting, ready, building, done

    public var title: String {
        switch self {
        case .waiting: "Waiting for you"
        case .drafting: "Drafting"
        case .ready: "Ready"
        case .building: "Building"
        case .done: "Done"
        }
    }

    public init(_ blueprint: Blueprint) {
        if blueprint.tooSmall != nil, blueprint.rounds.isEmpty { self = .waiting; return }
        switch blueprint.status {
        case .waiting: self = .waiting
        case .drafting: self = blueprint.specStale ? .waiting : .drafting
        case .ready: self = .ready
        case .building: self = .building
        case .done: self = .done
        }
    }

    /// Blueprints by project (in `projectOrder`, then any others by id), then
    /// by group, newest first in each.
    public static func grouped(_ blueprints: [Blueprint], projectOrder: [String]) -> [(projectId: String, groups: [(group: BlueprintGroup, blueprints: [Blueprint])])] {
        let byProject = Dictionary(grouping: blueprints, by: \.projectId)
        let known = projectOrder.filter { byProject[$0] != nil }
        let others = byProject.keys.filter { !projectOrder.contains($0) }.sorted()
        return (known + others).map { projectId in
            let list = byProject[projectId] ?? []
            let groups = BlueprintGroup.allCases.compactMap { group -> (group: BlueprintGroup, blueprints: [Blueprint])? in
                let inGroup = list.filter { BlueprintGroup($0) == group }
                    .sorted { ($0.updatedAt ?? .distantPast, $0.id) > ($1.updatedAt ?? .distantPast, $1.id) }
                return inGroup.isEmpty ? nil : (group, inGroup)
            }
            return (projectId, groups)
        }
    }
}
