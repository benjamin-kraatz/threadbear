import XCTest
@testable import ThreadbearCore

/// Blueprints (docs/protocol.md, "Blueprints"): decoding stays tolerant, the
/// events read as lines in the transcript, and the form's rules.
final class BlueprintTests: XCTestCase {
    private static func round(_ id: String = "r1", sent: Bool = false, answers: [String: Any] = [:], questions: [[String: Any]]? = nil) -> [String: Any] {
        var round: [String: Any] = [
            "id": id, "kind": "questions", "title": "How presets behave", "summary": "each project keeps its own list",
            "questions": questions ?? [
                ["id": "q1", "text": "Which presets?", "kind": "single", "youDecide": true,
                 "options": [["id": "A", "label": "Global"], ["id": "B", "label": "A copy", "note": "Edits stay put."]],
                 "recommended": ["option": "B", "why": "it matches Archive"]],
                ["id": "q2", "text": "What's it called once passed?", "kind": "text", "youDecide": false],
                ["id": "q3", "text": "How many?", "kind": "number", "min": 1, "max": 12, "step": 1],
            ],
            "assumptions": [["id": "a1", "text": "Stored with the project.", "why": "Everything else is."]],
            "answers": answers,
        ]
        if sent { round["sentAt"] = "2026-11-08T10:00:00Z" }
        return round
    }

    private static func blueprint(status: String = "waiting", rounds: [[String: Any]] = [round()], extra: [String: Any] = [:]) -> [String: Any] {
        var blueprint: [String: Any] = [
            "id": "bp1", "projectId": "p1", "folder": "/repo", "path": "/repo/.threadbear/blueprints/snooze", "slug": "snooze",
            "title": "Snooze presets", "status": status, "threadId": "th1", "rounds": rounds, "steps": [], "builds": [],
            "sideChats": ["q2": "th_side"], "costUsd": 0.84, "createdAt": "2026-11-08T09:00:00Z", "updatedAt": "2026-11-08T10:00:00Z",
        ]
        for (key, value) in extra { blueprint[key] = value }
        return blueprint
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ object: [String: Any]) throws -> T {
        try JSONDecoder().decode(type, from: Data(E.json(object).utf8))
    }

    // MARK: Decoding

    func testThreadSummaryCarriesKindParentAndBlueprint() throws {
        let thread = try Self.decode(ThreadSummary.self, ["id": "th1", "title": "Snooze", "kind": "blueprint", "blueprint": Self.blueprint()])
        XCTAssertTrue(thread.isBlueprint)
        XCTAssertNil(thread.parentThreadId)
        let blueprint = try XCTUnwrap(thread.blueprint)
        XCTAssertEqual(blueprint.status, .waiting)
        XCTAssertEqual(blueprint.sideChats["q2"], "th_side")
        XCTAssertEqual(blueprint.costUsd, 0.84)
        XCTAssertEqual(blueprint.rounds.first?.questions.map(\.kind), [.single, .text, .number])
        XCTAssertEqual(blueprint.rounds.first?.questions.first?.options.last?.note, "Edits stay put.")
        XCTAssertEqual(blueprint.specPath, ".threadbear/blueprints/snooze/spec.md")

        let side = try Self.decode(ThreadSummary.self, ["id": "th_side", "kind": "sideChat", "parentThreadId": "th1"])
        XCTAssertFalse(side.isBlueprint)
        XCTAssertEqual(side.parentThreadId, "th1")
        XCTAssertNil(side.blueprint)
    }

    func testABadBlueprintDoesNotLoseTheThread() throws {
        let thread = try Self.decode(ThreadSummary.self, ["id": "th1", "kind": "blueprint", "blueprint": ["title": 3]])
        XCTAssertEqual(thread.id, "th1")
        XCTAssertNil(thread.blueprint, "no id: no blueprint, but the thread stays")
    }

    func testUnknownKindsStatusesAndMissingFieldsStillDecode() throws {
        let blueprint = try Self.decode(Blueprint.self, [
            "id": "bp1", "status": "reviewing", "future": ["anything": true],
            "rounds": [[
                "id": "r1",
                "questions": [
                    ["id": "q1", "text": "Pick a colour", "kind": "colour"],
                    ["id": "q2"],
                    ["text": "no id, skipped"],
                ],
                "answers": ["q1": ["value": "#ff0000"], "q2": ["value": ["what": 1]], "q3": ["youDecide": true, "fromSideChat": true]],
            ]],
            "steps": [["id": "s1", "title": "Do it", "done": ["at": "2026-11-08T10:00:00Z", "note": "Done it", "threadId": "th2"]], ["title": "no id"]],
        ])
        XCTAssertEqual(blueprint.status, .drafting, "a status from a newer runner reads as drafting")
        XCTAssertEqual(blueprint.title, "")
        XCTAssertEqual(blueprint.costUsd, 0)
        let round = try XCTUnwrap(blueprint.rounds.first)
        XCTAssertEqual(round.kind, "questions")
        XCTAssertEqual(round.questions.map(\.id), ["q1", "q2"])
        XCTAssertEqual(round.questions[0].kind, .other("colour"))
        XCTAssertEqual(round.questions[1].kind, .text)
        XCTAssertTrue(round.questions[1].youDecide, "open by default")
        XCTAssertEqual(round.answers["q1"]?.value, .text("#ff0000"))
        XCTAssertNil(round.answers["q2"]?.value, "a value it can't read is none")
        XCTAssertEqual(round.answers["q3"]?.fromSideChat, true)
        XCTAssertEqual(blueprint.steps.map(\.id), ["s1"])
        XCTAssertEqual(blueprint.steps.first?.done?.note, "Done it")
    }

    func testAnswerValuesByKindAndBackToJSON() throws {
        let answers = try Self.decode(BlueprintRound.self, Self.round(answers: [
            "q1": ["value": "B", "usedRecommendation": true], "q2": ["value": "Hide it"], "q3": ["value": 5, "changedAt": "2026-11-08T11:00:00Z"],
        ])).answers
        XCTAssertEqual(answers["q1"]?.value, .text("B"))
        XCTAssertEqual(answers["q3"]?.value, .number(5))
        XCTAssertNotNil(answers["q3"]?.changedAt)
        let json = BlueprintAnswer.json(answers)
        XCTAssertEqual(json["q1"]?["usedRecommendation"], .bool(true))
        XCTAssertEqual(json["q3"]?["value"], .number(5))
        XCTAssertNil(json["q2"]?["youDecide"], "only what's set")
    }

    func testTooSmallTakesAnObjectOrAString() throws {
        XCTAssertEqual(try Self.decode(Blueprint.self, ["id": "b", "tooSmall": ["why": "Ten lines", "at": "x"]]).tooSmall, "Ten lines")
        XCTAssertEqual(try Self.decode(Blueprint.self, ["id": "b", "tooSmall": "Ten lines"]).tooSmall, "Ten lines")
    }

    func testSummaryRoundTripsWithItsBlueprint() throws {
        let thread = try Self.decode(ThreadSummary.self, ["id": "th1", "kind": "blueprint", "blueprint": Self.blueprint(rounds: [Self.round(sent: true, answers: ["q1": ["value": "B"]])])])
        let again = try JSONDecoder().decode(ThreadSummary.self, from: JSONEncoder().encode(thread))
        XCTAssertEqual(again.blueprint, thread.blueprint)
        XCTAssertEqual(again.kind, "blueprint")
    }

    // MARK: Events

    func testBlueprintEventsDecodeAndReadAsLines() {
        let events = [
            E.event(1, "blueprint.round", ["round": Self.round()]),
            E.event(2, "blueprint.answered", ["roundId": "r1", "answers": ["q1": ["value": "B"], "q2": ["value": "Hide it"]], "writeNow": true]),
            E.event(3, "blueprint.written", ["steps": [["id": "s1", "title": "One"], ["id": "s2", "title": "Two"]], "path": "/repo/x"]),
            E.event(4, "blueprint.step", ["stepId": "s1", "done": ["at": "2026-11-08T10:00:00Z", "note": "Did it", "threadId": "th2"]]),
            E.event(5, "blueprint.step", ["all": true]),
            E.event(6, "blueprint.tooSmall", ["why": "Ten lines"]),
            E.event(7, "blueprint.somethingNew", ["x": 1]),
            E.event(8, "blueprint.round", ["round": "not a round"]),
        ]
        guard case .blueprint(.round(let round)) = events[0].payload else { return XCTFail("round") }
        XCTAssertEqual(round.questions.count, 3)
        guard case .blueprint(.answered(let roundId, let answers, _, let writeNow)) = events[1].payload else { return XCTFail("answered") }
        XCTAssertEqual(roundId, "r1")
        XCTAssertEqual(answers.count, 2)
        XCTAssertTrue(writeNow)
        guard case .blueprint(.step(let stepId, let done, false)) = events[3].payload else { return XCTFail("step") }
        XCTAssertEqual(stepId, "s1")
        XCTAssertEqual(done?.note, "Did it")
        XCTAssertEqual(events[6].payload, .unknown, "a blueprint event this app doesn't know")
        XCTAssertEqual(events[7].payload, .unknown, "one it can't read keeps its seq")
        XCTAssertEqual(events[7].seq, 8)

        let model = TranscriptModel(events: Array(events.prefix(5)))
        let notes = model.items.compactMap { row -> String? in if case .note(let text) = row.content { text } else { nil } }
        XCTAssertEqual(notes, [
            "Round put: How presets behave", "Round answered (2 answers), write it now", "Spec written, 2 steps",
            "Step s1 done: Did it", "Blueprint marked done",
        ])
    }

    func testTooSmallInTheTranscriptUntilARound() {
        var model = TranscriptModel(events: [E.user(1, "Rename a button"), E.event(2, "blueprint.tooSmall", ["why": "Ten lines"])])
        XCTAssertEqual(model.blueprintTooSmall, "Ten lines")
        _ = model.apply([E.event(3, "blueprint.round", ["round": Self.round()])])
        XCTAssertNil(model.blueprintTooSmall)
    }

    func testTheInboxSkipsSideChatsAndChecks() throws {
        let threads = try [
            Self.decode(ThreadSummary.self, ["id": "bp", "kind": "blueprint", "needsYou": true]),
            Self.decode(ThreadSummary.self, ["id": "side", "kind": "sideChat", "parentThreadId": "bp"]),
            Self.decode(ThreadSummary.self, ["id": "check", "kind": "check", "parentThreadId": "bp"]),
        ]
        let sections = ThreadSections.build(threads, now: Date())
        XCTAssertEqual(sections.all.map(\.id), ["bp"])
    }

    // MARK: Rules

    private func rules(status: String = "waiting", rounds: [[String: Any]] = [round()], extra: [String: Any] = [:],
                       edits: [String: [String: BlueprintAnswer]] = [:]) throws -> BlueprintRules {
        let blueprint = try Self.decode(Blueprint.self, Self.blueprint(status: status, rounds: rounds, extra: extra))
        var answers: [String: [String: BlueprintAnswer]] = [:]
        for round in blueprint.rounds {
            answers[round.id] = round.answers.merging(edits[round.id] ?? [:]) { $1 }
        }
        return BlueprintRules(blueprint: blueprint, answers: answers)
    }

    func testContinueWaitsForEveryNeedsYouQuestion() throws {
        let empty = try rules()
        XCTAssertTrue(empty.showsContinue)
        XCTAssertFalse(empty.canContinue, "q2 needs you")
        XCTAssertEqual(empty.unanswered(in: empty.blueprint.rounds[0]).map(\.id), ["q2"])
        XCTAssertTrue(empty.composerTakesNote)

        let answered = try rules(edits: ["r1": ["q2": BlueprintAnswer(value: .text("Hide it"))]])
        XCTAssertTrue(answered.canContinue, "open questions left empty are you decide")
        XCTAssertEqual(answered.continueTitle, "Continue")

        let blank = try rules(edits: ["r1": ["q2": BlueprintAnswer(value: .text("   "))]])
        XCTAssertFalse(blank.canContinue, "spaces aren't an answer")

        let moot = try rules(rounds: [Self.round(questions: [["id": "q2", "text": "Old", "kind": "text", "youDecide": false, "moot": "Round 3 dropped it"]])])
        XCTAssertTrue(moot.canContinue, "a moot question needs nothing")
    }

    func testWriteItNowFromRoundTwo() throws {
        XCTAssertFalse(try rules().showsWriteNow)
        let two = try rules(rounds: [Self.round("r1", sent: true, answers: ["q2": ["value": "x"]]), Self.round("r2")])
        XCTAssertTrue(two.showsWriteNow)
        XCTAssertEqual(two.openRound?.id, "r2")
    }

    func testAChangedSentAnswerIsContinueWithChanges() throws {
        let base = [Self.round("r1", sent: true, answers: ["q1": ["value": "A"], "q2": ["value": "x"]]), Self.round("r2")]
        let unchanged = try rules(rounds: base)
        XCTAssertEqual(unchanged.continueTitle, "Continue")
        XCTAssertTrue(unchanged.changedRounds.isEmpty)

        let changed = try rules(rounds: base, edits: ["r1": ["q1": BlueprintAnswer(value: .text("B"))]])
        XCTAssertEqual(changed.changedRounds.map(\.id), ["r1"])
        XCTAssertEqual(changed.continueTitle, "Continue with changes")
        XCTAssertEqual(changed.changedQuestions(in: changed.blueprint.rounds[0]).map(\.id), ["q1"])

        // From a runner without `sent`, its "changed since last sent" mark
        // counts once the save has landed.
        let marked = try rules(status: "drafting", rounds: [Self.round("r1", sent: true, answers: ["q1": ["value": "B", "changedAt": "2026-11-08T11:00:00Z"], "q2": ["value": "x"]])])
        XCTAssertTrue(marked.showsContinue, "no round open, but a change to send")
        XCTAssertTrue(marked.canContinue)
        XCTAssertEqual(marked.continueTitle, "Continue with changes")
    }

    func testWhatShowsInEachStatus() throws {
        let sent = [Self.round("r1", sent: true, answers: ["q2": ["value": "x"]])]
        let ready = try rules(status: "ready", rounds: sent, extra: ["checked": ["at": "2026-11-08T10:00:00Z", "findings": 0]])
        XCTAssertEqual(ready.answering, .staleable)
        XCTAssertTrue(ready.showsStart)
        XCTAssertTrue(ready.showsCheck)
        XCTAssertTrue(ready.checkedClean)
        XCTAssertFalse(ready.showsContinue)
        XCTAssertFalse(ready.composerTakesNote)
        XCTAssertTrue(ready.foldedByDefault(ready.blueprint.rounds[0]))

        let stale = try rules(status: "drafting", rounds: sent, extra: ["specStale": true])
        XCTAssertTrue(stale.showsStaleBanner)
        XCTAssertFalse(stale.showsStart, "the start buttons go until the spec is written again")

        let readyEdited = try rules(status: "ready", rounds: sent, edits: ["r1": ["q2": BlueprintAnswer(value: .text("y"))]])
        XCTAssertTrue(readyEdited.showsStaleBanner, "shown at once, before the runner says so")
        XCTAssertTrue(readyEdited.staleLine().contains("question 2 changed from x to y"))

        let building = try rules(status: "building", rounds: sent,
                                 extra: ["builds": [["threadId": "th_build", "mode": "thread", "at": "2026-11-08T10:00:00Z"]],
                                         "steps": [["id": "s1", "title": "One", "done": ["note": "Did it"]], ["id": "s2", "title": "Two"]],
                                         "editedByHand": true])
        XCTAssertEqual(building.answering, .locked)
        XCTAssertTrue(building.showsEditedBanner)
        XCTAssertFalse(building.showsSendChange, "nothing changed yet")
        XCTAssertEqual(BlueprintText.state(building.blueprint), "Step 2 of 2")
        let changedBuild = try rules(status: "building", rounds: sent,
                                     extra: ["builds": [["threadId": "th_build", "mode": "thread"]]],
                                     edits: ["r1": ["q2": BlueprintAnswer(value: .text("y"))]])
        XCTAssertTrue(changedBuild.showsSendChange)
        XCTAssertFalse(changedBuild.showsContinue)
        XCTAssertTrue(changedBuild.changeMessage().contains("Was: x. Now: y."))

        let found = try Self.decode(Blueprint.self, ["id": "bp", "status": "ready", "title": "Found"])
        XCTAssertEqual(BlueprintRules(blueprint: found).answering, .none)
        XCTAssertTrue(BlueprintRules(blueprint: found).showsStart)
        XCTAssertFalse(BlueprintRules(blueprint: found).showsCheck, "no thread to check from")

        let small = try rules(status: "drafting", rounds: [], extra: ["tooSmall": ["why": "Ten lines"]])
        XCTAssertTrue(small.showsTooSmall)
        XCTAssertEqual(BlueprintText.state(small.blueprint), "Too small")
        XCTAssertEqual(BlueprintGroup(small.blueprint), .waiting)
    }

    func testStateWordsAndTally() throws {
        let waiting = try rules(rounds: [Self.round("r1", sent: true), Self.round("r2")])
        XCTAssertEqual(BlueprintText.state(waiting.blueprint), "Round 2 waiting")
        XCTAssertEqual(BlueprintText.state(waiting.blueprint, forYou: true), "Round 2 waiting for you")
        XCTAssertEqual(BlueprintText.title(of: waiting.blueprint.rounds[1], in: waiting.blueprint), "Round 2: How presets behave")

        var check = Self.round("rc")
        check["kind"] = "check"
        check["title"] = "what the check found"
        let checking = try rules(rounds: [Self.round("r1", sent: true), check])
        XCTAssertEqual(BlueprintText.state(checking.blueprint), "Check round waiting")
        XCTAssertEqual(BlueprintText.title(of: checking.blueprint.rounds[1], in: checking.blueprint), "Check round: what the check found")

        let round = try Self.decode(BlueprintRound.self, Self.round(sent: true, answers: ["q1": ["value": "B"], "q2": ["value": "x"], "q3": ["youDecide": true]]))
        XCTAssertEqual(BlueprintText.tally(round, answers: round.answers), "2 answered, 1 you decide")
        var edited = round.answers
        edited["q1"] = BlueprintAnswer(value: .text("A"))
        XCTAssertEqual(BlueprintText.tally(round, answers: edited), "2 answered, 1 you decide, 1 changed")
        XCTAssertEqual(BlueprintText.cost(0.844), "$0.84")
        XCTAssertEqual(BlueprintText.number(5), "5")
    }

    func testDescribeAnswersInWords() throws {
        let round = try Self.decode(BlueprintRound.self, Self.round())
        let single = round.questions[0]
        XCTAssertEqual(single.describe(BlueprintAnswer(value: .text("B"))), "A copy")
        XCTAssertEqual(single.describe(nil), "unanswered")
        XCTAssertEqual(single.describe(BlueprintAnswer(youDecide: true)), "you decide")
        XCTAssertEqual(single.recommendedValue, .text("B"))
        XCTAssertEqual(round.questions[2].describe(BlueprintAnswer(value: .number(5))), "5")
    }

    func testGroupingByProjectThenState() throws {
        let list = try [
            Self.decode(Blueprint.self, ["id": "a", "projectId": "p2", "status": "ready", "title": "A"]),
            Self.decode(Blueprint.self, ["id": "b", "projectId": "p1", "status": "waiting", "title": "B"]),
            Self.decode(Blueprint.self, ["id": "c", "projectId": "p1", "status": "done", "title": "C"]),
            Self.decode(Blueprint.self, ["id": "d", "projectId": "p1", "status": "drafting", "specStale": true, "title": "D"]),
        ]
        let grouped = BlueprintGroup.grouped(list, projectOrder: ["p1", "p2"])
        XCTAssertEqual(grouped.map(\.projectId), ["p1", "p2"])
        XCTAssertEqual(grouped[0].groups.map(\.group), [.waiting, .done])
        XCTAssertEqual(Set(grouped[0].groups[0].blueprints.map(\.id)), ["b", "d"])
    }
}

extension BlueprintTests {
    func testAskInsteadMarksAssumptions() throws {
        var round: [String: Any] = ["id": "r1", "assumptions": [["id": "a1", "text": "One"], ["id": "a2", "text": "Two"]]]
        round["askInstead"] = ["a2", "nope"]
        let decoded = try JSONDecoder().decode(BlueprintRound.self, from: Data(E.json(round).utf8))
        XCTAssertEqual(decoded.assumptions.map(\.askInstead), [false, true])
    }
}

extension BlueprintTests {
    /// The autosave has landed: the round's answers are the new ones (with
    /// changedAt), and `sent` keeps what the agent last had.
    func testWasComesFromSentOnceTheSaveHasLanded() throws {
        var round = Self.round("r1", sent: true, answers: ["q1": ["value": "B", "changedAt": "2026-11-08T11:00:00Z"], "q2": ["value": "x"]])
        round["sent"] = ["q1": ["value": "A"], "q2": ["value": "x"]]
        let landed = try rules(status: "ready", rounds: [round],
                               extra: ["specStale": true, "builds": [["threadId": "th_build", "mode": "thread"]]])
        XCTAssertEqual(landed.changedQuestions(in: landed.blueprint.rounds[0]).map(\.id), ["q1"])
        XCTAssertTrue(landed.staleLine().contains("question 1 changed from Global to A copy"), landed.staleLine())
        XCTAssertEqual(BlueprintText.tally(landed.blueprint.rounds[0], answers: landed.answers(of: landed.blueprint.rounds[0])), "2 answered, 1 changed")

        let building = try rules(status: "building", rounds: [round], extra: ["builds": [["threadId": "th_build", "mode": "thread"]]])
        XCTAssertTrue(building.changeMessage().contains("Was: Global. Now: A copy."), building.changeMessage())

        // Changed back to what was sent: nothing to send, whatever the
        // saved draft still says.
        let back = try rules(status: "drafting", rounds: [round], edits: ["r1": ["q1": BlueprintAnswer(value: .text("A"))]])
        XCTAssertTrue(back.changedRounds.isEmpty)
        XCTAssertFalse(back.showsContinue)
    }

    /// With a round open, Continue sends that round only; earlier changes
    /// are saved first and the runner folds them in.
    func testContinueSendsOneMessage() throws {
        let rounds = [Self.round("r1", sent: true, answers: ["q1": ["value": "A"], "q2": ["value": "x"]]), Self.round("r2")]
        let open = try rules(rounds: rounds, edits: ["r1": ["q1": BlueprintAnswer(value: .text("B"))], "r2": ["q2": BlueprintAnswer(value: .text("y"))]])
        XCTAssertEqual(open.continuePlan.saveFirst.map(\.id), ["r1"])
        XCTAssertEqual(open.continuePlan.send.map(\.id), ["r2"])

        let noneOpen = try rules(status: "drafting", rounds: [rounds[0]], edits: ["r1": ["q1": BlueprintAnswer(value: .text("B"))]])
        XCTAssertEqual(noneOpen.continuePlan.saveFirst.map(\.id), [])
        XCTAssertEqual(noneOpen.continuePlan.send.map(\.id), ["r1"])
    }

    /// "Not chosen" and a number typed out of range never reach the runner.
    func testEmptyAndOutOfRangeNeverReachTheJSON() throws {
        let edits: [String: BlueprintAnswer] = [
            "q1": BlueprintAnswer(value: .text("")),
            "q2": BlueprintAnswer(value: .text("Hide it")),
            "q3": BlueprintAnswer(value: .number(40)),
        ]
        let rules = try rules(edits: ["r1": edits])
        let round = rules.blueprint.rounds[0]
        let outgoing = rules.outgoing(round)
        XCTAssertNil(outgoing["q1"], "not chosen is no answer")
        XCTAssertEqual(outgoing["q3"]?.value, .number(12), "kept to max")
        let json = BlueprintAnswer.json(outgoing).compactText
        XCTAssertFalse(json.contains("\"\""), json)
        XCTAssertFalse(json.contains("40"), json)

        // Even straight to json, an empty answer is left out and a low
        // number is lifted to min.
        let direct = BlueprintAnswer.json(["q1": BlueprintAnswer(value: .text("")), "q3": BlueprintAnswer(value: .number(-3))], questions: round.questions)
        XCTAssertNil(direct["q1"])
        XCTAssertEqual(direct["q3"]?["value"], .number(1))
        XCTAssertNil(BlueprintAnswer(value: .list([])).normalized(for: nil))
        XCTAssertNotNil(BlueprintAnswer(youDecide: true).normalized(for: nil))
    }

    func testProposalEventDecodesAndIsKept() {
        let event = E.event(4, "blueprint.proposal", ["blueprintId": "bp1", "questionId": "q2", "answer": ["value": "Hide it"]])
        guard case .blueprint(.proposal(let proposal)) = event.payload else { return XCTFail("proposal") }
        XCTAssertEqual(proposal.questionId, "q2")
        XCTAssertEqual(proposal.answer.value, .text("Hide it"))
        XCTAssertEqual(E.event(5, "blueprint.proposal", ["blueprintId": "bp1"]).payload, .unknown, "no question: nothing to use")

        let model = TranscriptModel(events: [E.user(1, "Which?"), event])
        XCTAssertEqual(model.blueprintProposal?.questionId, "q2")
        let round = try? Self.decode(BlueprintRound.self, Self.round())
        XCTAssertEqual(proposal.text(for: round?.questions[1]), "Hide it")
        XCTAssertEqual(BlueprintProposal(blueprintId: "", questionId: "q1", answer: BlueprintAnswer(value: .text("B"))).text(for: round?.questions[0]), "A copy")
    }
}

extension BlueprintTests {
    private static func otherRound(sent: Bool = false, answers: [String: Any] = [:]) -> [String: Any] {
        round("r1", sent: sent, answers: answers, questions: [
            ["id": "s", "text": "Who first?", "kind": "single", "youDecide": false, "other": true,
             "options": [["id": "me", "label": "Just me"], ["id": "all", "label": "Everyone"]]],
            ["id": "m", "text": "Where?", "kind": "multi", "other": true, "options": [["id": "menu", "label": "Menu"]]],
            ["id": "t", "text": "Notes", "kind": "text", "other": true],
        ])
    }

    func testOtherDecodesOnlyOnChoiceQuestions() throws {
        let round = try Self.decode(BlueprintRound.self, Self.otherRound(answers: ["s": ["other": "My team"], "m": ["value": ["menu"], "other": "  "]]))
        XCTAssertEqual(round.questions.map(\.other), [true, true, false], "a text question can't have one")
        XCTAssertEqual(round.answers["s"]?.other, "My team")
        XCTAssertNil(round.answers["s"]?.value, "a single answered by Other has no value")
        XCTAssertNil(round.answers["m"]?.writtenOther, "spaces aren't written")
        XCTAssertEqual(round.questions[0].describe(round.answers["s"]), "Other: My team")
        XCTAssertEqual(round.questions[1].describe(BlueprintAnswer(value: .list(["menu"]), other: "Dock")), "Menu, Other: Dock")
    }

    /// A written Other answers a needs-you question; spaces don't.
    func testOtherCountsAsAnAnswer() throws {
        let empty = try rules(rounds: [Self.otherRound()])
        XCTAssertFalse(empty.canContinue)
        let written = try rules(rounds: [Self.otherRound()], edits: ["r1": ["s": BlueprintAnswer(other: "My team")]])
        XCTAssertTrue(written.canContinue)
        let spaces = try rules(rounds: [Self.otherRound()], edits: ["r1": ["s": BlueprintAnswer(other: "   ")]])
        XCTAssertFalse(spaces.canContinue)

        let outgoing = written.outgoing(written.blueprint.rounds[0])
        XCTAssertEqual(BlueprintAnswer.json(outgoing)["s"], .object(["other": .string("My team")]))
        // A question without Other drops one sent by mistake.
        let stray = try rules(rounds: [Self.otherRound()], edits: ["r1": ["t": BlueprintAnswer(value: .text("x"), other: "y")]])
        XCTAssertNil(stray.outgoing(stray.blueprint.rounds[0])["t"]?.other)
    }

    /// Changing what's written is a change; trailing spaces aren't.
    func testOtherChangesAreChanges() throws {
        var sent = Self.otherRound(sent: true, answers: ["s": ["other": "My team"], "m": ["value": ["menu"]]])
        sent["sent"] = ["s": ["other": "My team"], "m": ["value": ["menu"]]]
        let same = try rules(status: "drafting", rounds: [sent], edits: ["r1": ["s": BlueprintAnswer(other: "My team  ")]])
        XCTAssertTrue(same.changedRounds.isEmpty)
        let changed = try rules(status: "drafting", rounds: [sent], edits: ["r1": ["s": BlueprintAnswer(other: "Their team")]])
        XCTAssertEqual(changed.changedQuestions(in: changed.blueprint.rounds[0]).map(\.id), ["s"])
        let picked = try rules(status: "drafting", rounds: [sent], edits: ["r1": ["s": BlueprintAnswer(value: .text("me"))]])
        XCTAssertEqual(picked.changedQuestions(in: picked.blueprint.rounds[0]).map(\.id), ["s"], "a pick in place of Other")
        let added = try rules(status: "drafting", rounds: [sent], edits: ["r1": ["m": BlueprintAnswer(value: .list(["menu"]), other: "Dock")]])
        XCTAssertEqual(added.changedQuestions(in: added.blueprint.rounds[0]).map(\.id), ["m"], "one more choice on a multi")
    }

    func testProjectBlueprintSettings() throws {
        let project = try JSONDecoder().decode(Project.self, from: Data(E.json([
            "id": "p1", "title": "Tb", "folders": ["/a", "/b"], "blueprints": ["folder": "/b", "dir": "", "check": false],
        ]).utf8))
        XCTAssertEqual(ProjectBlueprints.folder(of: project), "/b")
        XCTAssertEqual(ProjectBlueprints.dir(of: project), ".threadbear/blueprints", "empty is the default")
        XCTAssertFalse(ProjectBlueprints.checks(project))

        // Back to the first folder and the check on: every default, so {}.
        var settings = project
        settings.blueprints = ProjectBlueprints.changed(project, folder: .some("/a"))
        XCTAssertEqual(settings.blueprints, ProjectBlueprints(check: false))
        XCTAssertTrue(ProjectBlueprints.changed(settings, check: .some(true)).isDefault)
        XCTAssertEqual(ProjectUpdate(blueprints: ProjectBlueprints()).params["blueprints"], .object([:]))
        XCTAssertEqual(ProjectBlueprints.changed(project, dir: .some(" docs/plans ")).dir, "docs/plans")
        XCTAssertNil(ProjectBlueprints.changed(project, dir: .some(".threadbear/blueprints")).dir)

        // A folder the project no longer has falls back to its first.
        var gone = project
        gone.folders = ["/a"]
        XCTAssertEqual(ProjectBlueprints.folder(of: gone), "/a")
        XCTAssertNil(ProjectUpdate(blueprints: ProjectBlueprints()).applied(to: project).blueprints)
    }
}
