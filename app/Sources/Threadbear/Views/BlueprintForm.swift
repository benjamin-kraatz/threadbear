import AppKit
import SwiftUI
import ThreadbearCore
import UniformTypeIdentifiers

/// A blueprint thread's detail (docs/blueprints-design.md, "The form"): the
/// header, its banners, then the rounds of questions, or the transcript under
/// them when the header's switch says so. The composer stays below, its
/// text the note that goes with Continue.
struct BlueprintPane: View {
    @Environment(AppModel.self) private var app
    let thread: ThreadSummary
    let session: ThreadSession?

    var body: some View {
        let form = app.blueprintForm(thread.id)
        let blueprint = effective
        VStack(spacing: 0) {
            BlueprintHeader(thread: thread, blueprint: blueprint, form: form)
                .frame(minWidth: 0, maxWidth: .infinity)
            if let blueprint {
                BlueprintBanners(thread: thread, blueprint: blueprint, form: form)
            }
            if form.showsTranscript {
                TranscriptView(session: session, controller: app.transcript)
            } else if let blueprint {
                BlueprintForm(thread: thread, blueprint: blueprint, form: form, session: session)
            } else {
                VStack(spacing: zoomed(8)) {
                    ProgressView().controlSize(.small)
                    Text("The agent is reading the code for its first questions.")
                        .font(.system(size: TypeScale.label))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity)
        .sheet(item: Binding(get: { app.blueprintDiff?.threadId == thread.id ? app.blueprintDiff : nil },
                             set: { if $0 == nil { app.blueprintDiff = nil } })) { diff in
            BlueprintDiffView(diff: diff)
        }
    }

    /// The summary's blueprint, too small by the transcript when the
    /// runner hasn't put that on the summary.
    private var effective: Blueprint? {
        guard var blueprint = thread.blueprint else { return nil }
        if blueprint.tooSmall == nil, blueprint.rounds.isEmpty, let why = session?.model.blueprintTooSmall {
            blueprint.tooSmall = why
        }
        if blueprint.threadId == nil { blueprint.threadId = thread.id }
        return blueprint
    }
}

// MARK: Header

/// "Blueprint: <title>", the state in words, the cost, the Stacked / One at
/// a time switch, the Transcript switch and the ... menu.
private struct BlueprintHeader: View {
    @Environment(AppModel.self) private var app
    let thread: ThreadSummary
    let blueprint: Blueprint?
    @Bindable var form: BlueprintFormState
    @AppStorage(BlueprintLayout.key) private var layout = BlueprintLayout.stacked.rawValue

    var body: some View {
        // One line when it fits, as drawn; in a narrow pane the switches
        // go to a second line rather than squeezing the title out.
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: zoomed(12)) {
                heading(fixed: true)
                Spacer(minLength: zoomed(8))
                controls
            }
            // Narrower: the title (cut short) with its state and cost on
            // one line, the switches on the next.
            VStack(alignment: .leading, spacing: zoomed(8)) {
                HStack(alignment: .firstTextBaseline, spacing: zoomed(10)) { heading(fixed: false) }
                HStack(alignment: .center, spacing: zoomed(12)) {
                    controls
                    Spacer(minLength: 0)
                }
            }
            // Narrowest: the cost goes, and the layout switch shrinks to
            // its own line's width.
            VStack(alignment: .leading, spacing: zoomed(8)) {
                HStack(alignment: .firstTextBaseline, spacing: zoomed(10)) { heading(fixed: false, cost: false) }
                HStack(alignment: .center, spacing: zoomed(10)) {
                    layoutPicker
                    transcriptSwitch
                    moreMenu
                }
            }
            // A sliver of a pane: the layout switch on a line of its own.
            VStack(alignment: .leading, spacing: zoomed(8)) {
                HStack(alignment: .firstTextBaseline, spacing: zoomed(10)) { heading(fixed: false, cost: false) }
                layoutPicker
                HStack(alignment: .center, spacing: zoomed(10)) {
                    transcriptSwitch
                    moreMenu
                }
            }
        }
        .font(.system(size: TypeScale.label))
        .padding(.horizontal, Theme.sideInset)
        .padding(.vertical, zoomed(10))
        // Never wider than the pane, so nothing under it is pushed off.
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .clipped()
        .overlay(alignment: .bottom) { Rectangle().fill(Color(nsColor: Theme.hairline)).frame(height: 0.5) }
    }

    @ViewBuilder
    private func heading(fixed: Bool, cost: Bool = true) -> some View {
        let title = blueprint?.title.isEmpty == false ? blueprint!.title : thread.title
        Text("Blueprint: \(title.isEmpty ? "Untitled" : title)")
            .font(.system(size: TypeScale.header, weight: .semibold))
            .lineLimit(1)
            .truncationMode(.tail)
            .fixedSize(horizontal: fixed, vertical: false)
            // Cut short rather than counted whole when the narrower
            // layouts measure what fits.
            .frame(minWidth: 0, idealWidth: fixed ? nil : 0, alignment: .leading)
            .layoutPriority(-1)
        if let blueprint {
            if BlueprintRules.agentWorking(thread.status) {
                // The same arc as a working row in the sidebar, in the
                // state's colour: the agent is on it, wherever the form is
                // scrolled to.
                SpinnerMark(color: BlueprintLook.stateNSColor(blueprint))
                    .frame(width: zoomed(12), height: zoomed(12))
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + zoomed(4) }
                    .tip("The agent is working on the blueprint")
            }
            Text(BlueprintText.state(blueprint, forYou: true))
                .foregroundStyle(BlueprintLook.stateColor(blueprint))
                .lineLimit(1)
                .fixedSize()
            if cost {
            Text(BlueprintText.cost(blueprint.costUsd))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .fixedSize()
                .tip("What this blueprint has cost so far, its side chats and checks included")
            }
        }
    }

    @ViewBuilder
    private var controls: some View {
        layoutPicker
        transcriptSwitch
        moreMenu
    }

    @ViewBuilder
    private var layoutPicker: some View {
        if let blueprint, !(blueprint.tooSmall != nil && blueprint.rounds.isEmpty), !form.showsTranscript {
            Picker("Layout", selection: $layout) {
                Text("Stacked").tag(BlueprintLayout.stacked.rawValue)
                Text("One at a time").tag(BlueprintLayout.oneAtATime.rawValue)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            .tip("Show every round, or one round at a time")
        }
    }

    private var transcriptSwitch: some View {
        Toggle("Transcript", isOn: $form.showsTranscript)
            .toggleStyle(.switch)
            .controlSize(.mini)
            .fixedSize()
            .tip(form.showsTranscript ? "Back to the form" : "Show the thread's transcript in place of the form")
    }

    private var moreMenu: some View {
        IconMenu {
            Button("Delete blueprint…", systemImage: "trash") { app.deleteBlueprint(threadId: thread.id) }
                .disabled(blueprint == nil)
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .busy(app.isBusy(BusyKey.blueprintDelete(thread.id)))
        .tip("More for this blueprint")
    }
}

/// Edited by hand, and the spec older than the answers: under the header.
private struct BlueprintBanners: View {
    @Environment(AppModel.self) private var app
    let thread: ThreadSummary
    let blueprint: Blueprint
    let form: BlueprintFormState

    var body: some View {
        let rules = form.rules(for: blueprint)
        if rules.showsEditedBanner || rules.showsStaleBanner {
            VStack(spacing: zoomed(8)) {
                if rules.showsEditedBanner {
                    banner(title: "Edited by hand", line: "spec.md differs from what the agent last wrote.") {
                        Button("Show changes") { app.showBlueprintDiff(threadId: thread.id) }
                            .buttonStyle(BlueprintButtonStyle(kind: .bordered))
                            .busy(app.isBusy(BusyKey.blueprintDiff(thread.id)))
                            .tip("See what changed in spec.md since the agent wrote it")
                        // Down once sent, until the runner clears the mark.
                        Button(form.toldAgent ? "Told the agent" : "Tell the agent") { app.tellBlueprintAgent(threadId: thread.id) }
                            .buttonStyle(BlueprintButtonStyle(kind: .primary))
                            .disabled(form.toldAgent)
                            .busy(app.isBusy(BusyKey.blueprintTell(thread.id)) || (form.toldAgent && thread.status.isBusy))
                            .tip(form.toldAgent ? "The agent has the changes; this goes once it has brought answers.md into line"
                                                : "Send the changes to the agent, which brings answers.md into line or asks about them")
                    }
                }
                if rules.showsStaleBanner {
                    banner(title: "The spec is older than your answers", line: rules.staleLine()) {
                        // Spins until the spec is written again.
                        Button("Update the spec") { app.updateBlueprintSpec(threadId: thread.id) }
                            .buttonStyle(BlueprintButtonStyle(kind: .primary))
                            .busy(app.isBusy(BusyKey.blueprintUpdateSpec(thread.id)) || form.updatingSpec)
                            .tip("Send the changed answers to the agent to write the spec again")
                    }
                }
            }
            .padding(.horizontal, Theme.sideInset)
            .padding(.top, zoomed(12))
        }
    }

    private func banner<Buttons: View>(title: String, line: String, @ViewBuilder buttons: () -> Buttons) -> some View {
        HStack(alignment: .center, spacing: zoomed(10)) {
            VStack(alignment: .leading, spacing: zoomed(3)) {
                Text(title).font(.system(size: TypeScale.label, weight: .medium))
                Text(line).font(.system(size: TypeScale.detail)).foregroundStyle(.secondary)
            }
            Spacer(minLength: zoomed(8))
            buttons()
        }
        .padding(zoomed(12))
        .background(BlueprintLook.waiting.opacity(0.07), in: RoundedRectangle(cornerRadius: zoomed(8)))
        .overlay(RoundedRectangle(cornerRadius: zoomed(8)).strokeBorder(BlueprintLook.waiting.opacity(0.45), lineWidth: 0.5))
        .frame(maxWidth: Theme.maxContentWidth)
    }
}

// MARK: The form

private struct BlueprintForm: View {
    @Environment(AppModel.self) private var app
    let thread: ThreadSummary
    let blueprint: Blueprint
    let form: BlueprintFormState
    /// For the working line's "what it's doing now" (`liveAction`).
    let session: ThreadSession?
    @AppStorage(BlueprintLayout.key) private var layout = BlueprintLayout.stacked.rawValue

    var body: some View {
        let rules = form.rules(for: blueprint)
        // The agent is on the next round (or the spec): say so where that
        // round will land, rather than leaving the form still until it does.
        let working = !rules.showsTooSmall && BlueprintRules.agentWorking(thread.status)
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: zoomed(12)) {
                    if rules.showsTooSmall {
                        TooSmallCard(threadId: thread.id, why: blueprint.tooSmall ?? "", running: thread.status.isBusy, form: form)
                    } else if layout == BlueprintLayout.oneAtATime.rawValue {
                        oneAtATime(rules)
                    } else {
                        ForEach(blueprint.rounds) { round in
                            roundView(round, rules: rules, folded: form.isFolded(round, rules: rules))
                        }
                    }
                    if working {
                        WorkingLine(thread: thread, action: session?.liveAction)
                    }
                    if !rules.showsTooSmall, !blueprint.steps.isEmpty || rules.showsStart {
                        StepsCard(thread: thread, blueprint: blueprint, rules: rules)
                    }
                    if rules.showsSendChange {
                        HStack {
                            Button("Send a change to the build thread") { app.sendBlueprintChange(threadId: thread.id) }
                                .buttonStyle(BlueprintButtonStyle(kind: .primary))
                                .busy(app.isBusy(BusyKey.blueprintSendChange(thread.id)))
                                .tip("Answers are locked while it's built: send the changed answers to the newest build thread as a message")
                            Spacer()
                        }
                    }
                    if blueprint.rounds.isEmpty, !rules.showsTooSmall, !working {
                        Text(blueprint.threadId == nil ? "Found in the project's folder, with no rounds to show." : "The agent is reading the code for its first questions.")
                            .font(.system(size: TypeScale.label))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, zoomed(40))
                    }
                }
                .frame(maxWidth: Theme.maxContentWidth)
                .padding(.horizontal, Theme.sideInset)
                .padding(.vertical, zoomed(18))
                .frame(maxWidth: .infinity)
            }
            .onChange(of: form.focus?.tick) { _, _ in
                guard let question = form.focus?.question else { return }
                // The round it's in, unfolded and on the page.
                if let round = blueprint.rounds.first(where: { $0.questions.contains { $0.id == question } }) {
                    if form.isFolded(round, rules: rules) { form.toggled.formSymmetricDifference([round.id]) }
                    form.page = round.id
                }
                withAnimation(.snappy(duration: 0.25)) { proxy.scrollTo("q:" + question, anchor: .center) }
            }
        }
    }

    @ViewBuilder
    private func roundView(_ round: BlueprintRound, rules: BlueprintRules, folded: Bool) -> some View {
        if folded {
            FoldedRound(title: BlueprintText.title(of: round, in: blueprint), tally: BlueprintText.tally(round, answers: rules.answers(of: round))) {
                withAnimation(.snappy(duration: 0.2)) { _ = form.toggled.formSymmetricDifference([round.id]) }
            }
        } else {
            RoundCard(thread: thread, blueprint: blueprint, round: round, rules: rules, form: form)
        }
    }

    /// One round at a time, with "Round 2 of 2" and arrows to the others.
    @ViewBuilder
    private func oneAtATime(_ rules: BlueprintRules) -> some View {
        let rounds = blueprint.rounds
        let index = rounds.firstIndex { $0.id == form.page } ?? rounds.firstIndex { $0.id == rules.openRound?.id } ?? max(0, rounds.count - 1)
        if rounds.indices.contains(index) {
            HStack(spacing: zoomed(10)) {
                if index > 0 {
                    Button("‹ \(BlueprintText.title(of: rounds[index - 1], in: blueprint).components(separatedBy: ":").first ?? "Back")") {
                        form.page = rounds[index - 1].id
                    }
                    .buttonStyle(BlueprintButtonStyle(kind: .bordered))
                    .tip("The round before")
                }
                Text(rounds[index].isCheck ? "Check round" : "Round \(BlueprintText.roundNumber(of: rounds[index], in: blueprint)) of \(rounds.filter { !$0.isCheck }.count)")
                    .font(.system(size: TypeScale.label, weight: .medium))
                if index < rounds.count - 1 {
                    Button("\(BlueprintText.title(of: rounds[index + 1], in: blueprint).components(separatedBy: ":").first ?? "Next") ›") {
                        form.page = rounds[index + 1].id
                    }
                    .buttonStyle(BlueprintButtonStyle(kind: .bordered))
                    .tip("The round after")
                }
                Spacer()
            }
            RoundCard(thread: thread, blueprint: blueprint, round: rounds[index], rules: rules, form: form)
        }
    }
}

/// Under the last round while the agent works on the next: the turning
/// arc, how long the turn has run, and what it's doing right now, from the
/// transcript's live action ("Read snooze.ts", "Thinking"). The round
/// takes this spot when it arrives. The seconds tick in a TimelineView, as
/// the sidebar's working rows do, so nothing else is laid out again.
private struct WorkingLine: View {
    let thread: ThreadSummary
    let action: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: zoomed(8)) {
            SpinnerMark(color: .controlAccentColor)
                .frame(width: zoomed(14), height: zoomed(14))
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + zoomed(5) }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(BlueprintText.working(elapsed: ThreadRowLook.workingLabel(since: thread.lastActivityAt, now: context.date), action: action))
                    .monospacedDigit()
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .font(.system(size: TypeScale.label))
        .foregroundStyle(Color(nsColor: Theme.quietText))
        .padding(.horizontal, zoomed(16))
        .padding(.vertical, zoomed(4))
        .frame(maxWidth: .infinity, alignment: .leading)
        .tip("What the agent is doing now; the Transcript switch shows all of it")
        .accessibilityElement(children: .combine)
    }
}

/// A round folded to one line: its title and how it was answered.
private struct FoldedRound: View {
    let title: String
    let tally: String
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: zoomed(10)) {
                Image(systemName: "chevron.right")
                    .font(.system(size: zoomed(10), weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.system(size: TypeScale.cardTitle, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: zoomed(8))
                Text(tally)
                    .font(.system(size: TypeScale.label))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, zoomed(16))
            .padding(.vertical, zoomed(11))
            .background(hovering ? Color(nsColor: Theme.hoverFill) : Color(nsColor: Theme.cardBackground), in: RoundedRectangle(cornerRadius: zoomed(10)))
            .overlay(RoundedRectangle(cornerRadius: zoomed(10)).strokeBorder(Color(nsColor: Theme.cardBorder), lineWidth: 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .tip("Show this round's questions and answers")
    }
}

/// A round with its questions, its assumptions and, on the open one,
/// Continue and Write it now.
private struct RoundCard: View {
    @Environment(AppModel.self) private var app
    let thread: ThreadSummary
    let blueprint: Blueprint
    let round: BlueprintRound
    let rules: BlueprintRules
    let form: BlueprintFormState

    var body: some View {
        let answers = rules.answers(of: round)
        let isOpen = round.id == rules.openRound?.id
        // Continue sits under the open round, or under the last changed
        // round while none is open.
        let carriesContinue = rules.showsContinue && (isOpen || (rules.openRound == nil && rules.changedRounds.last?.id == round.id))
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(BlueprintText.title(of: round, in: blueprint))
                    .font(.system(size: TypeScale.cardTitle + 1, weight: .semibold))
                Spacer()
                if !isOpen {
                    Button {
                        withAnimation(.snappy(duration: 0.2)) { _ = form.toggled.formSymmetricDifference([round.id]) }
                    } label: {
                        Image(systemName: "chevron.down").font(.system(size: zoomed(10), weight: .semibold)).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .tip("Fold this round")
                }
            }
            if let summary = round.summary {
                Text("What I understood so far: \(summary)")
                    .font(.system(size: TypeScale.label))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, zoomed(6))
            }
            ForEach(Array(round.questions.enumerated()), id: \.element.id) { index, question in
                Rectangle().fill(Color(nsColor: Theme.hairline)).frame(height: 0.5).padding(.vertical, zoomed(14))
                QuestionView(thread: thread, blueprint: blueprint, round: round, question: question, number: index + 1,
                             answer: answers[question.id], rules: rules, form: form)
                    .id("q:" + question.id)
            }
            if !round.assumptions.isEmpty {
                Rectangle().fill(Color(nsColor: Theme.hairline)).frame(height: 0.5).padding(.top, zoomed(14)).padding(.bottom, zoomed(10))
                AssumptionsStrip(thread: thread, round: round, editable: isOpen, form: form)
            }
            if carriesContinue {
                // Side by side, or one under the other in a narrow pane.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: zoomed(14)) { continueButtons }
                    VStack(alignment: .leading, spacing: zoomed(8)) { continueButtons }
                }
                .padding(.top, zoomed(16))
            }
        }
        .padding(zoomed(20))
        .background(Color(nsColor: Theme.cardBackground), in: RoundedRectangle(cornerRadius: zoomed(12)))
        .overlay(RoundedRectangle(cornerRadius: zoomed(12)).strokeBorder(Color(nsColor: Theme.cardBorder), lineWidth: 0.5))
    }

    @ViewBuilder
    private var continueButtons: some View {
        Button(rules.continueTitle) { app.continueBlueprint(threadId: thread.id) }
            .buttonStyle(BlueprintButtonStyle(kind: .primary, large: true))
            .disabled(!rules.canContinue)
            .busy(app.isContinuingBlueprint(thread.id))
            .keyboardShortcut(.return, modifiers: .command)
            .tip(rules.canContinue ? "Send your answers, and the note in the box below, to the agent"
                                   : "Answer the questions marked Needs you first")
        if rules.showsWriteNow {
            Button("Write it now") { app.continueBlueprint(threadId: thread.id, writeNow: true) }
                .buttonStyle(BlueprintButtonStyle(kind: .quiet, large: true))
                .disabled(!rules.canContinue)
                .busy(app.isContinuingBlueprint(thread.id))
                .tip("Send these answers and have the agent write the spec now, deciding the rest itself")
        }
    }
}

/// "Assumptions (4)", folded; open, each with its why and Ask me instead.
private struct AssumptionsStrip: View {
    @Environment(AppModel.self) private var app
    let thread: ThreadSummary
    let round: BlueprintRound
    let editable: Bool
    let form: BlueprintFormState

    var body: some View {
        let open = form.assumptionsOpen.contains(round.id)
        VStack(alignment: .leading, spacing: zoomed(8)) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { _ = form.assumptionsOpen.formSymmetricDifference([round.id]) }
            } label: {
                HStack(spacing: zoomed(8)) {
                    Image(systemName: open ? "chevron.down" : "chevron.right")
                        .font(.system(size: zoomed(10), weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: zoomed(12))
                    Text("Assumptions (\(round.assumptions.count))")
                        .font(.system(size: TypeScale.label, weight: .medium))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .tip(open ? "Hide what the agent assumed" : "What the agent assumed rather than asked")
            if open {
                ForEach(round.assumptions) { assumption in
                    HStack(alignment: .firstTextBaseline, spacing: zoomed(10)) {
                        VStack(alignment: .leading, spacing: zoomed(2)) {
                            Text(assumption.text).font(.system(size: TypeScale.label))
                            if !assumption.why.isEmpty {
                                Text(assumption.why).font(.system(size: TypeScale.detail)).foregroundStyle(.secondary)
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: zoomed(8))
                        if assumption.askInstead {
                            Text("Asked next round")
                                .font(.system(size: TypeScale.detail))
                                .foregroundStyle(.secondary)
                        } else if editable {
                            Button("Ask me instead") { app.askInstead(threadId: thread.id, roundId: round.id, assumptionId: assumption.id) }
                                .buttonStyle(BlueprintButtonStyle(kind: .small))
                                .busy(app.isBusy(BusyKey.blueprintAskInstead(thread.id, assumption.id)))
                                .tip("Have the agent ask you this as a question in its next round")
                        }
                    }
                    .padding(.leading, zoomed(20))
                }
            }
        }
    }
}

// MARK: A question

private struct QuestionView: View {
    @Environment(AppModel.self) private var app
    let thread: ThreadSummary
    let blueprint: Blueprint
    let round: BlueprintRound
    let question: BlueprintQuestion
    let number: Int
    let answer: BlueprintAnswer?
    let rules: BlueprintRules
    let form: BlueprintFormState

    private var editable: Bool { rules.answering != .none && question.moot == nil }
    private var changed: Bool {
        round.isChanged(question.id, shown: answer)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: zoomed(10)) {
            // Read off the main thread: a file on a slow or external disk
            // mustn't hold up the form.
            if let image = question.image {
                AsyncImage(url: URL(fileURLWithPath: image)) { picture in
                    picture.resizable().scaledToFit()
                } placeholder: {
                    Color.clear.frame(height: zoomed(40))
                }
                .frame(maxHeight: zoomed(260), alignment: .leading)
                .clipShape(RoundedRectangle(cornerRadius: zoomed(6)))
                .tip((image as NSString).lastPathComponent)
            }
            HStack(alignment: .firstTextBaseline, spacing: zoomed(8)) {
                Text("\(number)")
                    .font(.system(size: TypeScale.cardTitle))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Text(question.text)
                    .font(.system(size: TypeScale.cardTitle, weight: .semibold))
                    .strikethrough(question.moot != nil)
                    .foregroundStyle(question.moot != nil ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                if question.needsYou {
                    Mark(text: "Needs you", color: BlueprintLook.waiting)
                        .tip("The agent needs your answer to this one")
                }
                if changed {
                    Mark(text: "changed", color: .secondary)
                        .tip("Changed since the round was sent")
                }
                if answer?.fromSideChat == true, question.kind != .text {
                    Mark(text: "from side chat", color: BlueprintLook.moving)
                        .tip("This answer came from the question's side chat")
                }
            }
            if let moot = question.moot {
                Text("No longer applies: \(moot)")
                    .font(.system(size: TypeScale.detail))
                    .foregroundStyle(.secondary)
                    .padding(.leading, zoomed(18))
            } else {
                Group {
                    field
                    if let recommended = question.recommended, !recommended.why.isEmpty || recommended.option != nil || recommended.text != nil {
                        recommendation(recommended)
                    }
                    buttons
                }
                .padding(.leading, zoomed(18))
                .disabled(!editable)
            }
        }
    }

    // MARK: Fields by kind

    @ViewBuilder
    private var field: some View {
        switch question.kind {
        case .single:
            if question.options.count > 6 {
                Picker("Answer", selection: Binding(get: { answer?.value?.text ?? "" }, set: { $0.isEmpty ? clear() : set(.text($0)) })) {
                    Text("Not chosen").tag("")
                    ForEach(question.options) { option in Text(option.label).tag(option.id) }
                }
                .labelsHidden()
                .fixedSize()
                .tip("Pick one")
                otherRow(multiple: false)
            } else {
                VStack(alignment: .leading, spacing: zoomed(8)) {
                    ForEach(question.options) { option in
                        // A pick clears a written Other: a single has one answer.
                        OptionRow(option: option, picked: answer?.value?.text == option.id, multiple: false) { set(.text(option.id)) }
                    }
                    otherRow(multiple: false)
                }
            }
        case .multi:
            let picked = Set(answer?.value?.list ?? [])
            VStack(alignment: .leading, spacing: zoomed(8)) {
                ForEach(question.options) { option in
                    OptionRow(option: option, picked: picked.contains(option.id), multiple: true) {
                        var next = picked
                        if next.contains(option.id) { next.remove(option.id) } else { next.insert(option.id) }
                        // A written Other stays: it's one more choice.
                        app.setBlueprintAnswer(threadId: thread.id, roundId: round.id, questionId: question.id,
                                               BlueprintAnswer(value: .list(question.options.map(\.id).filter { next.contains($0) }), other: answer?.other))
                    }
                }
                // On every choice question, whatever the agent set: the user
                // decides whether an answer is in their own words.
                otherRow(multiple: true)
            }
        case .number:
            NumberField(question: question, value: answer?.value?.number) { set(.number($0)) }
        case .files:
            PathChips(paths: answer?.value?.list ?? []) { path in
                set(.list((answer?.value?.list ?? []).filter { $0 != path }))
            }
        case .upload:
            UploadField(question: question, blueprint: blueprint, paths: answer?.value?.list ?? []) { set(.list($0)) }
        case .text:
            TextAnswer(threadId: thread.id, questionId: question.id, text: answer?.value?.text ?? "",
                       fromSideChat: answer?.fromSideChat == true, form: form) { set(.text($0)) }
        case .other:
            VStack(alignment: .leading, spacing: zoomed(4)) {
                TextAnswer(threadId: thread.id, questionId: question.id, text: answer?.value?.text ?? "",
                           fromSideChat: answer?.fromSideChat == true, form: form) { set(.text($0)) }
                Text("A kind this app doesn't know yet, so it's asked as text.")
                    .font(.system(size: TypeScale.detail))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func recommendation(_ recommended: BlueprintRecommendation) -> some View {
        let what: String = {
            if let option = recommended.option {
                return option.count <= 2 ? option : question.label(of: option)
            }
            return recommended.text ?? ""
        }()
        let using = answer?.usedRecommendation == true
        return HStack(alignment: .firstTextBaseline, spacing: zoomed(8)) {
            (Text(what.isEmpty ? "Recommends: " : "Recommends \(what): ").fontWeight(.semibold) + Text(recommended.why).foregroundColor(.secondary))
                .font(.system(size: TypeScale.label))
                .fixedSize(horizontal: false, vertical: true)
            if question.recommendedValue != nil {
                Button(using ? "Used" : "Use") {
                    guard let value = question.recommendedValue else { return }
                    app.setBlueprintAnswer(threadId: thread.id, roundId: round.id, questionId: question.id,
                                           BlueprintAnswer(value: value, usedRecommendation: true))
                }
                .buttonStyle(.plain)
                .font(.system(size: TypeScale.label))
                .foregroundStyle(using ? Color.secondary : Color.accentColor)
                .disabled(using)
                .tip(using ? "Answered with the recommendation" : "Answer with what the agent recommends")
            }
        }
    }

    /// Small and quiet, always there: Choose files, Ask about this, You decide.
    private var buttons: some View {
        // In a row, or one under another in a narrow pane.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: zoomed(6)) { buttonItems }
            VStack(alignment: .leading, spacing: zoomed(6)) { buttonItems }
        }
        .padding(.top, zoomed(2))
    }

    @ViewBuilder
    private var buttonItems: some View {
        Group {
            if question.kind == .files {
                Button("Choose files") { chooseFiles() }
                    .buttonStyle(BlueprintButtonStyle(kind: .small))
                    .tip("Pick files from the project folder")
            }
            if blueprint.threadId != nil {
                Button("Ask about this") { app.openSideChat(threadId: thread.id, questionId: question.id) }
                    .buttonStyle(BlueprintButtonStyle(kind: .small))
                    .busy(app.isBusy(BusyKey.blueprintSideChat(thread.id, question.id)))
                    .tip("Talk this question over in a side chat that can read the code")
            }
            if question.youDecide {
                let deciding = answer?.youDecide == true
                Button("You decide") {
                    if deciding {
                        app.setBlueprintAnswer(threadId: thread.id, roundId: round.id, questionId: question.id, nil)
                    } else {
                        app.setBlueprintAnswer(threadId: thread.id, roundId: round.id, questionId: question.id,
                                               BlueprintAnswer(youDecide: true, usedRecommendation: question.recommended?.option != nil || question.recommended?.text != nil))
                    }
                }
                .buttonStyle(BlueprintButtonStyle(kind: .small, on: deciding))
                .tip(deciding ? "Take it back and answer it yourself"
                     : question.recommended != nil ? "Leave it to the agent: it uses its recommendation" : "Leave it to the agent")
            }
        }
    }

    /// "Other" with a field, at the end of the options: what's typed is the
    /// answer (a single's pick goes), or one more choice for a multi.
    private func otherRow(multiple: Bool) -> some View {
        OtherRow(text: answer?.other ?? "", picked: answer?.writtenOther != nil, multiple: multiple) { written in
            let value: BlueprintValue? = multiple ? answer?.value : nil
            app.setBlueprintAnswer(threadId: thread.id, roundId: round.id, questionId: question.id, BlueprintAnswer(value: value, other: written))
        }
    }

    /// No answer: "Not chosen" in the menu.
    private func clear() {
        app.setBlueprintAnswer(threadId: thread.id, roundId: round.id, questionId: question.id, nil)
    }

    private func set(_ value: BlueprintValue) {
        app.setBlueprintAnswer(threadId: thread.id, roundId: round.id, questionId: question.id,
                               BlueprintAnswer(value: value, fromSideChat: false))
    }

    /// A picker rooted at the project folder; paths kept relative to it.
    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = question.several
        if !blueprint.folder.isEmpty { panel.directoryURL = URL(fileURLWithPath: blueprint.folder, isDirectory: true) }
        panel.prompt = "Choose"
        guard panel.runModal() == .OK else { return }
        let base = blueprint.folder.hasSuffix("/") ? blueprint.folder : blueprint.folder + "/"
        let picked = panel.urls.map { url in
            url.path.hasPrefix(base) && !blueprint.folder.isEmpty ? String(url.path.dropFirst(base.count)) : url.path
        }
        var paths = question.several ? (answer?.value?.list ?? []) : []
        for path in picked where !paths.contains(path) { paths.append(path) }
        set(.list(paths))
    }
}

/// A radio button or a checkbox, with the option's note under its label.
private struct OptionRow: View {
    let option: BlueprintOption
    let picked: Bool
    let multiple: Bool
    let pick: () -> Void

    var body: some View {
        Button(action: pick) {
            HStack(alignment: .firstTextBaseline, spacing: zoomed(10)) {
                Image(systemName: multiple ? (picked ? "checkmark.square.fill" : "square") : (picked ? "largecircle.fill.circle" : "circle"))
                    .font(.system(size: zoomed(15)))
                    .foregroundStyle(picked ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: zoomed(2)) {
                    Text(option.label).font(.system(size: TypeScale.cardTitle))
                    if let note = option.note {
                        Text(note).font(.system(size: TypeScale.label)).foregroundStyle(.secondary)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .tip(multiple ? (picked ? "Untick \(option.label)" : "Tick \(option.label)") : "Pick \(option.label)")
    }
}

/// The Other row: a radio or checkbox that's on while something's written,
/// and the field to write it in. A click on the mark puts the cursor there.
private struct OtherRow: View {
    let text: String
    let picked: Bool
    let multiple: Bool
    let change: (String) -> Void
    @State private var typed = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: zoomed(10)) {
            Button { focused = true } label: {
                Image(systemName: multiple ? (picked ? "checkmark.square.fill" : "square") : (picked ? "largecircle.fill.circle" : "circle"))
                    .font(.system(size: zoomed(15)))
                    .foregroundStyle(picked ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .tip("Write your own answer")
            TextField("Other", text: $typed, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: TypeScale.cardTitle))
                .lineLimit(1...4)
                .focused($focused)
                .padding(.horizontal, zoomed(8))
                .padding(.vertical, zoomed(4))
                .background(Color(nsColor: Theme.codeBackground), in: RoundedRectangle(cornerRadius: zoomed(6)))
                .overlay(RoundedRectangle(cornerRadius: zoomed(6)).strokeBorder(Color(nsColor: focused ? .controlAccentColor : Theme.cardBorder), lineWidth: focused ? 1 : 0.5))
                .tip(multiple ? "Another choice, in your words" : "An answer in your words, in place of the options")
        }
        .onAppear { typed = text }
        .onChange(of: text) { _, now in if !focused { typed = now } }
        .onChange(of: typed) { _, now in if now.trimmingCharacters(in: .whitespacesAndNewlines) != text.trimmingCharacters(in: .whitespacesAndNewlines) { change(now) } }
    }
}

/// A multi-line answer, typed on screen and saved a moment after.
private struct TextAnswer: View {
    @Environment(AppModel.self) private var app
    let threadId: String
    let questionId: String
    let text: String
    let fromSideChat: Bool
    let form: BlueprintFormState
    let change: (String) -> Void
    @State private var typed = ""
    @FocusState private var focused: Bool

    var body: some View {
        ZStack(alignment: .topTrailing) {
            TextField("Your answer", text: $typed, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: TypeScale.cardTitle))
                .lineLimit(2...10)
                .focused($focused)
                .padding(zoomed(12))
                .padding(.trailing, fromSideChat ? zoomed(110) : 0)
                .background(Color(nsColor: Theme.codeBackground), in: RoundedRectangle(cornerRadius: zoomed(8)))
                .overlay(RoundedRectangle(cornerRadius: zoomed(8)).strokeBorder(Color(nsColor: focused ? .controlAccentColor : Theme.cardBorder), lineWidth: focused ? 1 : 0.5))
                .tip("Type your answer")
            if fromSideChat {
                Mark(text: "from side chat", color: BlueprintLook.moving)
                    .padding(zoomed(12))
                    .tip("This answer came from the question's side chat")
            }
        }
        .onAppear { typed = text }
        .onChange(of: text) { _, now in if !focused || typed.isEmpty { typed = now } }
        .onChange(of: typed) { _, now in if now != text { change(now) } }
        .onChange(of: form.focus?.tick) { _, _ in if form.focus?.question == questionId { focused = true } }
    }
}

/// A number, with a slider when the question has a range.
private struct NumberField: View {
    let question: BlueprintQuestion
    let value: Double?
    let change: (Double) -> Void

    var body: some View {
        HStack(spacing: zoomed(12)) {
            if let low = question.min, let high = question.max, high > low {
                Text(BlueprintText.number(low)).foregroundStyle(.secondary).monospacedDigit()
                Slider(value: Binding(get: { value ?? low }, set: { change(rounded($0)) }), in: low...high)
                    .frame(maxWidth: zoomed(420))
                    .tip("Drag to set it")
                Text(BlueprintText.number(high)).foregroundStyle(.secondary).monospacedDigit()
            }
            // Kept to the range, whatever's typed.
            TextField("", value: Binding(get: { value }, set: { if let new = $0 { change(BlueprintAnswer.clamp(new, to: question)) } }), format: .number)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.center)
                .frame(width: zoomed(64))
                .tip("Type a number")
        }
        .font(.system(size: TypeScale.label))
    }

    private func rounded(_ raw: Double) -> Double {
        let step = question.step ?? 1
        guard step > 0 else { return raw }
        return (raw / step).rounded() * step
    }
}

/// Picked paths as chips, each with a cross to take it out.
private struct PathChips: View {
    let paths: [String]
    let remove: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: zoomed(6)) {
            ForEach(paths, id: \.self) { path in
                HStack {
                    Text(path.hasPrefix("/") ? (path as NSString).abbreviatingWithTildeInPath : path)
                        .font(.system(size: TypeScale.label, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button { remove(path) } label: {
                        Image(systemName: "xmark").font(.system(size: zoomed(9), weight: .semibold)).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .tip("Take \((path as NSString).lastPathComponent) out")
                }
                .padding(.horizontal, zoomed(10))
                .padding(.vertical, zoomed(6))
                .background(Color(nsColor: Theme.codeBackground), in: RoundedRectangle(cornerRadius: zoomed(6)))
                .overlay(RoundedRectangle(cornerRadius: zoomed(6)).strokeBorder(Color(nsColor: Theme.cardBorder), lineWidth: 0.5))
            }
        }
    }
}

/// A file from the Mac: dropped here or chosen, copied into the
/// blueprint's attachments folder, and kept relative to the blueprint.
private struct UploadField: View {
    @Environment(AppModel.self) private var app
    let question: BlueprintQuestion
    let blueprint: Blueprint
    let paths: [String]
    let change: ([String]) -> Void
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: zoomed(8)) {
            PathChips(paths: paths) { path in change(paths.filter { $0 != path }) }
            HStack(spacing: zoomed(10)) {
                Text(question.several ? "Drop files here" : "Drop a file here")
                    .font(.system(size: TypeScale.label))
                    .foregroundStyle(.secondary)
                Button("Choose…") { choose() }
                    .buttonStyle(BlueprintButtonStyle(kind: .small))
                    .tip("Pick a file from this Mac")
                Spacer()
            }
            .padding(zoomed(14))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(targeted ? Color.accentColor.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: zoomed(8)))
            .overlay(RoundedRectangle(cornerRadius: zoomed(8)).strokeBorder(targeted ? Color.accentColor : Color(nsColor: Theme.cardBorder),
                                                                             style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
                for provider in providers {
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        guard let url else { return }
                        Task { @MainActor in add([url]) }
                    }
                }
                return true
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = question.several
        panel.prompt = "Choose"
        if panel.runModal() == .OK { add(panel.urls) }
    }

    /// The Mac paths go as the answer; the runner copies each file into
    /// the blueprint's attachments folder (and caps its size), and the
    /// reply's path relative to the blueprint replaces this one.
    private func add(_ urls: [URL]) {
        var next = question.several ? paths : []
        for url in urls where !next.contains(url.path) {
            next.append(url.path)
            if !question.several { break }
        }
        change(next)
    }
}

/// A small label in a capsule: Needs you, changed, from side chat.
private struct Mark: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: TypeScale.detail, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, zoomed(7))
            .padding(.vertical, zoomed(2))
            .overlay(Capsule().strokeBorder(color.opacity(0.6), lineWidth: 0.75))
            .fixedSize()
    }
}

// MARK: Steps, start and too small

/// The spec's steps as a checklist, with the start buttons and the check
/// at its foot once the spec is written (Benjamin's pick, 8 Nov).
private struct StepsCard: View {
    @Environment(AppModel.self) private var app
    let thread: ThreadSummary
    let blueprint: Blueprint
    let rules: BlueprintRules

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Steps").font(.system(size: TypeScale.cardTitle + 1, weight: .semibold))
            Text("\(blueprint.specPath) · \(blueprint.doneSteps) of \(blueprint.steps.count) done")
                .font(.system(size: TypeScale.detail, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.top, zoomed(3))
            ForEach(blueprint.steps) { step in
                Rectangle().fill(Color(nsColor: Theme.hairline)).frame(height: 0.5).padding(.vertical, zoomed(10))
                HStack(alignment: .firstTextBaseline, spacing: zoomed(10)) {
                    Image(systemName: step.done == nil ? "square" : "checkmark.square.fill")
                        .font(.system(size: zoomed(14)))
                        .foregroundStyle(step.done == nil ? Color.secondary : Color(nsColor: .systemGreen))
                    VStack(alignment: .leading, spacing: zoomed(2)) {
                        Text(step.title)
                            .font(.system(size: TypeScale.label))
                            .foregroundStyle(step.done == nil ? .primary : .secondary)
                        if let done = step.done, !done.note.isEmpty {
                            Text(done.note).font(.system(size: TypeScale.detail)).foregroundStyle(.secondary)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
                .tip(step.done == nil ? "Not done yet; the build thread marks it" : "Done")
            }
            if rules.showsStart {
                Rectangle().fill(Color(nsColor: Theme.hairline)).frame(height: 0.5).padding(.top, zoomed(14)).padding(.bottom, zoomed(14))
                // In one row when it fits, else two.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: zoomed(8)) { startButtons; laterButton; Spacer(minLength: 0) }
                    VStack(alignment: .leading, spacing: zoomed(8)) {
                        HStack(spacing: zoomed(8)) { startButtons }
                        HStack(spacing: zoomed(8)) { laterButton }
                    }
                    VStack(alignment: .leading, spacing: zoomed(8)) {
                        startButtons
                        laterButton
                    }
                }
                if rules.showsCheck {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: zoomed(14)) { checkLine; Spacer(minLength: 0) }
                        VStack(alignment: .leading, spacing: zoomed(6)) { checkLine }
                    }
                    .padding(.top, zoomed(10))
                }
            }
        }
        .padding(zoomed(20))
        .background(Color(nsColor: Theme.cardBackground), in: RoundedRectangle(cornerRadius: zoomed(12)))
        .overlay(RoundedRectangle(cornerRadius: zoomed(12)).strokeBorder(Color(nsColor: Theme.cardBorder), lineWidth: 0.5))
    }

    @ViewBuilder
    private var startButtons: some View {
        Button("Start a thread") { app.startBlueprint(blueprint, mode: "thread") }
            .buttonStyle(BlueprintButtonStyle(kind: .primary))
            .busy(app.isBusy(BusyKey.blueprintStart(thread.id, "thread")))
            .tip("A thread in the project folder that builds the spec, ticking the steps off as it goes")
        Button("Start with subagents") { app.startBlueprint(blueprint, mode: "subagents") }
            .buttonStyle(BlueprintButtonStyle(kind: .bordered))
            .busy(app.isBusy(BusyKey.blueprintStart(thread.id, "subagents")))
            .tip("The same thread, working the steps with a subagent each where they're independent")
    }

    @ViewBuilder
    private var checkLine: some View {
        if rules.checkedClean {
            Text("Checked, nothing found")
                .font(.system(size: TypeScale.detail))
                .foregroundStyle(.secondary)
                .fixedSize()
        }
        Button("Check the spec") { app.checkBlueprint(threadId: thread.id) }
            .buttonStyle(BlueprintButtonStyle(kind: .quiet))
            .busy(app.isBusy(BusyKey.blueprintCheck(thread.id)))
            .tip("Have a cheaper agent read the spec against the code again and ask about anything that doesn't fit")
    }

    @ViewBuilder
    private var laterButton: some View {
        Button("Start as threads") {}
            .buttonStyle(BlueprintButtonStyle(kind: .bordered))
            .disabled(true)
            .tip("One thread per step, each in its own worktree: coming later")
        Text("coming later")
            .font(.system(size: TypeScale.detail))
            .foregroundStyle(.secondary)
            .fixedSize()
    }
}

/// In place of the form when the agent thinks it's a small change.
private struct TooSmallCard: View {
    @Environment(AppModel.self) private var app
    let threadId: String
    let why: String
    /// The blueprint thread's turn is underway.
    let running: Bool
    let form: BlueprintFormState

    var body: some View {
        VStack(alignment: .leading, spacing: zoomed(14)) {
            Text("This looks like a small change. Start it as a normal thread?")
                .font(.system(size: TypeScale.headings.1, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            if !why.isEmpty {
                Text(why)
                    .font(.system(size: TypeScale.label))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, zoomed(12))
                    .overlay(alignment: .leading) { Rectangle().fill(Color(nsColor: Theme.hairline)).frame(width: 2) }
            }
            HStack(spacing: zoomed(14)) {
                Button("Start a thread") { app.tooSmallStart(threadId: threadId) }
                    .buttonStyle(BlueprintButtonStyle(kind: .primary, large: true))
                    .busy(app.isBusy(BusyKey.blueprintTooSmall(threadId)))
                    .tip("Start a normal thread with your description, and delete this blueprint")
                // Down from the click until the agent puts a round (or
                // says it's small for another reason).
                Button("Ask me anyway") { app.askMeAnyway(threadId: threadId) }
                    .buttonStyle(BlueprintButtonStyle(kind: .quiet, large: true))
                    .disabled(form.askedAnyway != nil)
                    .busy(app.isBusy(BusyKey.blueprintAskAnyway(threadId)) || (form.askedAnyway != nil && running))
                    .tip("Have the agent put its questions anyway")
            }
        }
        .padding(zoomed(24))
        .frame(maxWidth: zoomed(620), alignment: .leading)
        .background(Color(nsColor: Theme.cardBackground), in: RoundedRectangle(cornerRadius: zoomed(12)))
        .overlay(RoundedRectangle(cornerRadius: zoomed(12)).strokeBorder(Color(nsColor: Theme.cardBorder), lineWidth: 0.5))
        .frame(maxWidth: .infinity)
        .padding(.top, zoomed(60))
    }
}

/// Show changes: the agent's last spec against spec.md on disk.
private struct BlueprintDiffView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let diff: BlueprintDiffSheet

    var body: some View {
        let lines = DiffBuilder.displayLines(EditDiff(itemId: "", path: diff.path, hunks: diff.hunks))
        VStack(alignment: .leading, spacing: zoomed(12)) {
            Text("Changes to spec.md").font(.headline)
            Text((diff.path as NSString).abbreviatingWithTildeInPath)
                .font(.system(size: TypeScale.detail, design: .monospaced))
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if lines.isEmpty {
                        Text("No changes.").foregroundStyle(.secondary)
                    }
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(mark(line) + line.text)
                            .font(.system(size: TypeScale.diff, design: .monospaced))
                            .foregroundStyle(line.kind == .hunkHeader || line.kind == .elided ? Color.secondary : Color.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, zoomed(8))
                            .background(background(line))
                    }
                }
                .textSelection(.enabled)
            }
            .background(Color(nsColor: Theme.codeBackground), in: RoundedRectangle(cornerRadius: zoomed(6)))
            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .tip("Close the changes")
                Button("Tell the agent") { app.tellBlueprintAgent(threadId: diff.threadId) }
                    .keyboardShortcut(.defaultAction)
                    .busy(app.isBusy(BusyKey.blueprintTell(diff.threadId)))
                    .tip("Send these changes to the agent, which brings answers.md into line or asks about them")
            }
        }
        .padding(zoomed(18))
        .frame(width: zoomed(720), height: zoomed(520))
    }

    private func mark(_ line: DiffDisplayLine) -> String {
        switch line.kind {
        case .added: "+ "
        case .removed: "- "
        case .context: "  "
        default: ""
        }
    }

    private func background(_ line: DiffDisplayLine) -> Color {
        switch line.kind {
        case .added: Color(nsColor: .systemGreen).opacity(0.14)
        case .removed: Color(nsColor: .systemRed).opacity(0.14)
        default: .clear
        }
    }
}

// MARK: Buttons

/// The form's buttons, as the mockups draw them: filled for the one to
/// press, an outline for the rest, plain text for the quiet ones, and small
/// and quiet for each question's own (Benjamin's pick, 8 Nov).
struct BlueprintButtonStyle: ButtonStyle {
    enum Kind { case primary, bordered, quiet, small }
    var kind: Kind
    var large = false
    /// A small one that's switched on (You decide pressed).
    var on = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        let size: CGFloat = kind == .small ? TypeScale.detail : large ? TypeScale.cardTitle + 1 : TypeScale.label
        configuration.label
            .lineLimit(1)
            .fixedSize()
            .font(.system(size: size, weight: kind == .primary ? .semibold : .regular))
            .foregroundStyle(foreground)
            .padding(.horizontal, kind == .small ? zoomed(8) : zoomed(large ? 16 : 12))
            .padding(.vertical, kind == .small ? zoomed(3) : zoomed(large ? 8 : 6))
            .background(background(pressed: configuration.isPressed), in: RoundedRectangle(cornerRadius: zoomed(kind == .small ? 5 : 7)))
            .overlay {
                if kind == .bordered || kind == .small {
                    RoundedRectangle(cornerRadius: zoomed(kind == .small ? 5 : 7))
                        .strokeBorder(Color(nsColor: Theme.cardBorder).opacity(kind == .small && !on ? 0.7 : 1), lineWidth: 0.5)
                }
            }
            .opacity(enabled ? 1 : 0.45)
            .contentShape(Rectangle())
    }

    private var foreground: Color {
        switch kind {
        case .primary: .white
        case .bordered: .primary
        case .quiet: .secondary
        case .small: on ? .primary : .secondary
        }
    }

    private func background(pressed: Bool) -> Color {
        switch kind {
        case .primary: Color.accentColor.opacity(pressed ? 0.8 : 1)
        case .bordered: Color(nsColor: pressed ? Theme.hoverFill : Theme.cardBackground)
        case .quiet: pressed ? Color(nsColor: Theme.hoverFill) : .clear
        case .small: on ? Color.primary.opacity(0.1) : pressed ? Color(nsColor: Theme.hoverFill) : .clear
        }
    }
}

// MARK: A side chat's proposal

/// "Proposed answer", joined to the top of a side chat's composer: the side
/// chat's newest `propose_answer`, and Use, which writes it into the
/// blueprint's form marked "from side chat". Nothing moves without the click.
struct BlueprintProposalCard: View {
    @Environment(AppModel.self) private var app
    let sideChat: ThreadSummary
    let proposal: BlueprintProposal

    var body: some View {
        let parent = sideChat.parentThreadId.flatMap { app.threads[$0] }
        let blueprint = parent?.blueprint
        let round = blueprint?.rounds.first { $0.questions.contains { $0.id == proposal.questionId } }
        let question = round?.questions.first { $0.id == proposal.questionId }
        let shown = Self.shown(app: app, parent: parent, blueprint: blueprint, round: round, questionId: proposal.questionId)
        let used = shown.map { $0.fromSideChat && $0.sameAnswer(as: proposal.answer) } ?? false
        VStack(alignment: .leading, spacing: zoomed(8)) {
            Text("Proposed answer")
                .font(.system(size: TypeScale.label, weight: .semibold))
            Text(proposal.text(for: question))
                .font(.system(size: TypeScale.label))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            HStack(spacing: zoomed(10)) {
                Button(used ? "Used" : "Use") { app.useBlueprintProposal(sideChat: sideChat, proposal: proposal) }
                    .buttonStyle(BlueprintButtonStyle(kind: .primary))
                    .disabled(used || blueprint == nil || round == nil)
                    .busy(app.isBusy(BusyKey.blueprintUseProposal(sideChat.id, proposal.questionId)))
                    .tip(used ? "It's the question's answer in the form now" : "Put this answer in the blueprint's form, marked from side chat")
                if blueprint == nil {
                    Text("The blueprint isn't loaded.")
                        .font(.system(size: TypeScale.detail))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(zoomed(12))
        .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: zoomed(8)))
        .overlay(RoundedRectangle(cornerRadius: zoomed(8)).strokeBorder(Color.accentColor.opacity(0.45), lineWidth: 0.75))
    }

    /// The question's answer as the form shows it.
    private static func shown(app: AppModel, parent: ThreadSummary?, blueprint: Blueprint?, round: BlueprintRound?, questionId: String) -> BlueprintAnswer? {
        guard let parent, let blueprint, let round else { return nil }
        return app.blueprintForm(parent.id).answers(for: blueprint)[round.id]?[questionId]
    }
}
