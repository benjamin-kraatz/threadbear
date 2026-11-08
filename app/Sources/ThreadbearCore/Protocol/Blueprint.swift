import Foundation

// Blueprints (docs/protocol.md, "Blueprints"): a feature planned by answering
// rounds of questions, then written as a spec into the repo. A blueprint is a
// thread (`ThreadSummary.kind == "blueprint"`) carrying one of these on its
// summary. Everything here decodes tolerantly: a field this app doesn't know
// is ignored, one it can't read falls back to a default, and a question of a
// kind it doesn't know yet still draws (as a text field).

public enum BlueprintStatus: String, Sendable, Hashable, Codable, CaseIterable {
    case drafting, waiting, ready, building, done

    /// A status from a newer runner reads as drafting: the form stays usable.
    public init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
        self = BlueprintStatus(rawValue: raw) ?? .drafting
    }
}

/// An answer's value: an option id or a string, option ids or paths, or a
/// number, by the question's kind.
public enum BlueprintValue: Sendable, Hashable, Codable {
    case text(String)
    case list([String])
    case number(Double)

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let number = try? c.decode(Double.self), number.isFinite {
            self = .number(number)
        } else if let text = try? c.decode(String.self) {
            self = .text(text)
        } else if let list = try? c.decode(LossyArray<String>.self) {
            self = .list(list.elements)
        } else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "not an answer value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .text(let text): try c.encode(text)
        case .list(let list): try c.encode(list)
        case .number(let number): try c.encode(number)
        }
    }

    public var jsonValue: JSONValue {
        switch self {
        case .text(let text): .string(text)
        case .list(let list): .array(list.map { .string($0) })
        case .number(let number): .number(number)
        }
    }

    /// Nothing in it: an empty string, list or nothing chosen.
    public var isEmpty: Bool {
        switch self {
        case .text(let text): text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .list(let list): list.isEmpty
        case .number: false
        }
    }

    public var text: String? { if case .text(let text) = self { text } else { nil } }
    public var list: [String] {
        switch self {
        case .list(let list): list
        case .text(let text): text.isEmpty ? [] : [text]
        case .number: []
        }
    }
    public var number: Double? {
        switch self {
        case .number(let number): number
        case .text(let text): Double(text)
        case .list: nil
        }
    }
}

public struct BlueprintAnswer: Sendable, Hashable, Codable {
    public var value: BlueprintValue?
    /// A written "Other", for a single or multi question that has one. A
    /// single answered this way has no `value`.
    public var other: String?
    public var youDecide: Bool
    public var usedRecommendation: Bool
    public var fromSideChat: Bool
    /// Edited after the round was sent.
    public var changedAt: Date?

    public init(value: BlueprintValue? = nil, other: String? = nil, youDecide: Bool = false, usedRecommendation: Bool = false, fromSideChat: Bool = false, changedAt: Date? = nil) {
        self.value = value
        self.other = other
        self.youDecide = youDecide
        self.usedRecommendation = usedRecommendation
        self.fromSideChat = fromSideChat
        self.changedAt = changedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        value = (try? c.decodeIfPresent(BlueprintValue.self, forKey: .value)) ?? nil
        other = ((try? c.decodeIfPresent(String.self, forKey: .other)) ?? nil).flatMap { $0.isEmpty ? nil : $0 }
        youDecide = (try? c.decodeIfPresent(Bool.self, forKey: .youDecide)) == true
        usedRecommendation = (try? c.decodeIfPresent(Bool.self, forKey: .usedRecommendation)) == true
        fromSideChat = (try? c.decodeIfPresent(Bool.self, forKey: .fromSideChat)) == true
        changedAt = ((try? c.decodeIfPresent(String.self, forKey: .changedAt)) ?? nil).flatMap(ISO8601.parse)
    }

    public func encode(to encoder: Encoder) throws {
        try jsonValue.encode(to: encoder)
    }

    /// As the runner takes it in `answers`: only what's set.
    public var jsonValue: JSONValue {
        var out: [String: JSONValue] = [:]
        // An empty value is no value: the runner refuses "" for a single.
        if let value, !value.isEmpty { out["value"] = value.jsonValue }
        if let other = writtenOther { out["other"] = .string(other) }
        if youDecide { out["youDecide"] = .bool(true) }
        if usedRecommendation { out["usedRecommendation"] = .bool(true) }
        if fromSideChat { out["fromSideChat"] = .bool(true) }
        if let changedAt { out["changedAt"] = .string(ISO8601.format(changedAt)) }
        return .object(out)
    }

    /// Something was given: a value, a written Other, "you decide" or the
    /// recommendation.
    public var isGiven: Bool { youDecide || usedRecommendation || (value.map { !$0.isEmpty } ?? false) || writtenOther != nil }

    /// The Other text, if anything but spaces was written.
    public var writtenOther: String? {
        guard let other else { return nil }
        let trimmed = other.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The same answer, ignoring when it was changed and where it came
    /// from. An empty value is the same as none.
    public func sameAnswer(as other: BlueprintAnswer?) -> Bool {
        BlueprintAnswer.same(self, other)
    }

    /// Two answers (either missing) say the same thing.
    public static func same(_ a: BlueprintAnswer?, _ b: BlueprintAnswer?) -> Bool {
        let aGiven = a?.isGiven ?? false
        let bGiven = b?.isGiven ?? false
        if !aGiven || !bGiven { return aGiven == bGiven }
        func value(_ answer: BlueprintAnswer?) -> BlueprintValue? { answer?.value.flatMap { $0.isEmpty ? nil : $0 } }
        return value(a) == value(b) && a?.writtenOther == b?.writtenOther
            && a?.youDecide == b?.youDecide && a?.usedRecommendation == b?.usedRecommendation
    }

    /// The answer as it may go to the runner for this question: an empty
    /// value is none, a number is kept to the question's range and step,
    /// and an answer that says nothing at all is nil (no answer).
    public func normalized(for question: BlueprintQuestion?) -> BlueprintAnswer? {
        var answer = self
        if let value = answer.value, value.isEmpty { answer.value = nil }
        answer.other = answer.writtenOther
        // Only a question that takes one keeps a written Other.
        if let question, !question.other { answer.other = nil }
        if case .number(let number)? = answer.value, let question {
            answer.value = .number(BlueprintAnswer.clamp(number, to: question))
        }
        guard answer.isGiven else { return nil }
        return answer
    }

    /// A number within the question's min and max.
    public static func clamp(_ number: Double, to question: BlueprintQuestion) -> Double {
        var out = number
        if let low = question.min { out = Swift.max(out, low) }
        if let high = question.max { out = Swift.min(out, high) }
        return out
    }

    enum CodingKeys: String, CodingKey { case value, other, youDecide, usedRecommendation, fromSideChat, changedAt }
}

public struct BlueprintOption: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    public var label: String
    public var note: String?

    public init(id: String, label: String, note: String? = nil) {
        self.id = id
        self.label = label
        self.note = note
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = (try? c.decodeIfPresent(String.self, forKey: .label)) ?? id
        note = ((try? c.decodeIfPresent(String.self, forKey: .note)) ?? nil).flatMap { $0.isEmpty ? nil : $0 }
    }

    enum CodingKeys: String, CodingKey { case id, label, note }
}

public struct BlueprintRecommendation: Sendable, Hashable, Codable {
    public var option: String?
    public var text: String?
    public var why: String

    public init(option: String? = nil, text: String? = nil, why: String) {
        self.option = option
        self.text = text
        self.why = why
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        option = (try? c.decodeIfPresent(String.self, forKey: .option)) ?? nil
        text = (try? c.decodeIfPresent(String.self, forKey: .text)) ?? nil
        why = (try? c.decodeIfPresent(String.self, forKey: .why)) ?? ""
    }

    enum CodingKeys: String, CodingKey { case option, text, why }
}

public struct BlueprintQuestion: Sendable, Hashable, Codable, Identifiable {
    /// How the question is drawn. `other` is a kind from a newer runner: it
    /// draws as a text field with a note.
    public enum Kind: Sendable, Hashable, Codable {
        case single, multi, text, number, files, upload
        case other(String)

        public init(raw: String) {
            switch raw {
            case "single": self = .single
            case "multi": self = .multi
            case "text": self = .text
            case "number": self = .number
            case "files": self = .files
            case "upload": self = .upload
            default: self = .other(raw)
            }
        }

        public var raw: String {
            switch self {
            case .single: "single"
            case .multi: "multi"
            case .text: "text"
            case .number: "number"
            case .files: "files"
            case .upload: "upload"
            case .other(let raw): raw
            }
        }

        public init(from decoder: Decoder) throws {
            self.init(raw: (try? decoder.singleValueContainer().decode(String.self)) ?? "text")
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            try c.encode(raw)
        }
    }

    public var id: String
    public var text: String
    public var kind: Kind
    public var options: [BlueprintOption]
    public var recommended: BlueprintRecommendation?
    /// True by default: "You decide" is a button on it. False: needs you.
    public var youDecide: Bool
    public var min: Double?
    public var max: Double?
    public var step: Double?
    /// files and upload: more than one.
    public var several: Bool
    /// single and multi: a written "Other" beside the options.
    public var other: Bool
    /// An absolute path, shown above the question.
    public var image: String?
    /// Set by a later round: why it no longer applies.
    public var moot: String?

    public init(id: String, text: String, kind: Kind, options: [BlueprintOption] = [], recommended: BlueprintRecommendation? = nil,
                youDecide: Bool = true, min: Double? = nil, max: Double? = nil, step: Double? = nil, several: Bool = false,
                image: String? = nil, moot: String? = nil, other: Bool = false) {
        self.other = other
        self.id = id
        self.text = text
        self.kind = kind
        self.options = options
        self.recommended = recommended
        self.youDecide = youDecide
        self.min = min
        self.max = max
        self.step = step
        self.several = several
        self.image = image
        self.moot = moot
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        text = (try? c.decodeIfPresent(String.self, forKey: .text)) ?? ""
        kind = (try? c.decodeIfPresent(Kind.self, forKey: .kind)) ?? .text
        options = c.lossyArray(BlueprintOption.self, forKey: .options)
        recommended = (try? c.decodeIfPresent(BlueprintRecommendation.self, forKey: .recommended)) ?? nil
        youDecide = (try? c.decodeIfPresent(Bool.self, forKey: .youDecide)) ?? true
        min = (try? c.decodeIfPresent(Double.self, forKey: .min)) ?? nil
        max = (try? c.decodeIfPresent(Double.self, forKey: .max)) ?? nil
        step = (try? c.decodeIfPresent(Double.self, forKey: .step)) ?? nil
        several = (try? c.decodeIfPresent(Bool.self, forKey: .several)) == true
        other = (kind == .single || kind == .multi) && (try? c.decodeIfPresent(Bool.self, forKey: .other)) == true
        image = ((try? c.decodeIfPresent(String.self, forKey: .image)) ?? nil).flatMap { $0.isEmpty ? nil : $0 }
        moot = ((try? c.decodeIfPresent(String.self, forKey: .moot)) ?? nil).flatMap { $0.isEmpty ? nil : $0 }
    }

    enum CodingKeys: String, CodingKey { case id, text, kind, options, recommended, youDecide, min, max, step, several, image, moot, other }

    /// Needs an answer from Mike before Continue: no "You decide".
    public var needsYou: Bool { !youDecide && moot == nil }

    /// The option's label, for an id the agent sent.
    public func label(of option: String) -> String { options.first { $0.id == option }?.label ?? option }

    /// What a recommendation says as an answer, when "Use" is pressed.
    public var recommendedValue: BlueprintValue? {
        guard let recommended else { return nil }
        if let option = recommended.option {
            return kind == .multi ? .list([option]) : .text(option)
        }
        if let text = recommended.text {
            if kind == .number, let number = Double(text) { return .number(number) }
            return kind == .multi || kind == .files || kind == .upload ? .list([text]) : .text(text)
        }
        return nil
    }

    /// An answer in words, for a change sent to a build thread or a note.
    public func describe(_ answer: BlueprintAnswer?) -> String {
        guard let answer, answer.isGiven else { return "unanswered" }
        if let other = answer.writtenOther {
            let picked = answer.value.map { describe(BlueprintAnswer(value: $0)) }
            let written = "Other: \(other)"
            return picked.map { $0 == "unanswered" ? written : "\($0), \(written)" } ?? written
        }
        if answer.youDecide && !answer.usedRecommendation && (answer.value?.isEmpty ?? true) { return "you decide" }
        guard let value = answer.value else { return answer.usedRecommendation ? "the recommendation" : "you decide" }
        switch value {
        case .number(let number): return BlueprintText.number(number)
        case .text(let text): return kind == .single ? label(of: text) : text
        case .list(let list): return list.map { kind == .multi ? label(of: $0) : $0 }.joined(separator: ", ")
        }
    }
}

public struct BlueprintAssumption: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    public var text: String
    public var why: String
    /// Marked with "Ask me instead" (`blueprints.askInstead`).
    public var askInstead: Bool

    public init(id: String, text: String, why: String = "", askInstead: Bool = false) {
        self.id = id
        self.text = text
        self.why = why
        self.askInstead = askInstead
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        text = (try? c.decodeIfPresent(String.self, forKey: .text)) ?? ""
        why = (try? c.decodeIfPresent(String.self, forKey: .why)) ?? ""
        askInstead = (try? c.decodeIfPresent(Bool.self, forKey: .askInstead)) == true
    }

    enum CodingKeys: String, CodingKey { case id, text, why, askInstead }
}

public struct BlueprintRound: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    /// "questions" or "check"; anything else reads as questions.
    public var kind: String
    public var title: String
    public var summary: String?
    public var questions: [BlueprintQuestion]
    public var assumptions: [BlueprintAssumption]
    /// By question id: a draft until sent.
    public var answers: [String: BlueprintAnswer]
    public var note: String?
    public var sentAt: Date?
    public var writeNow: Bool
    /// The answers as last sent to the agent: what "was A, now B" compares
    /// with. Nil before the round is sent, and from a runner without it.
    public var sent: [String: BlueprintAnswer]?

    public init(id: String, kind: String = "questions", title: String, summary: String? = nil, questions: [BlueprintQuestion] = [],
                assumptions: [BlueprintAssumption] = [], answers: [String: BlueprintAnswer] = [:], note: String? = nil,
                sentAt: Date? = nil, writeNow: Bool = false, sent: [String: BlueprintAnswer]? = nil) {
        self.sent = sent
        self.id = id
        self.kind = kind
        self.title = title
        self.summary = summary
        self.questions = questions
        self.assumptions = assumptions
        self.answers = answers
        self.note = note
        self.sentAt = sentAt
        self.writeNow = writeNow
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = (try? c.decodeIfPresent(String.self, forKey: .kind)) ?? "questions"
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? ""
        summary = ((try? c.decodeIfPresent(String.self, forKey: .summary)) ?? nil).flatMap { $0.isEmpty ? nil : $0 }
        questions = c.lossyArray(BlueprintQuestion.self, forKey: .questions)
        // `askInstead` lists the assumptions marked Ask me instead.
        let asked = Set(c.lossyArray(String.self, forKey: .askInstead))
        assumptions = c.lossyArray(BlueprintAssumption.self, forKey: .assumptions).map { assumption in
            var marked = assumption
            if asked.contains(assumption.id) { marked.askInstead = true }
            return marked
        }
        answers = BlueprintRound.lossyAnswers(c, key: .answers)
        note = ((try? c.decodeIfPresent(String.self, forKey: .note)) ?? nil).flatMap { $0.isEmpty ? nil : $0 }
        sentAt = ((try? c.decodeIfPresent(String.self, forKey: .sentAt)) ?? nil).flatMap(ISO8601.parse)
        writeNow = (try? c.decodeIfPresent(Bool.self, forKey: .writeNow)) == true
        let sentRaw = (try? c.decodeIfPresent([String: JSONValue].self, forKey: .sent)) ?? nil
        sent = sentRaw.map(BlueprintAnswer.decode)
    }

    /// Answers that don't decode are skipped, not the round.
    static func lossyAnswers(_ c: KeyedDecodingContainer<CodingKeys>, key: CodingKeys) -> [String: BlueprintAnswer] {
        guard let raw = (try? c.decodeIfPresent([String: JSONValue].self, forKey: key)) ?? nil else { return [:] }
        return BlueprintAnswer.decode(raw)
    }

    enum CodingKeys: String, CodingKey { case id, kind, title, summary, questions, assumptions, answers, note, sentAt, writeNow, askInstead, sent }

    public func encode(to encoder: Encoder) throws {
        try jsonValue.encode(to: encoder)
    }

    public var isCheck: Bool { kind == "check" }
    public var isSent: Bool { sentAt != nil }

    /// What the agent last had for a question: `sent`, or for a runner
    /// without it the round's own answers.
    public func sentAnswer(_ questionId: String) -> BlueprintAnswer? {
        sent.map { $0[questionId] } ?? answers[questionId]
    }

    /// The answer on screen differs from what the agent last had. With
    /// `sent` that's a plain comparison; without it, `changedAt` (changed
    /// since last sent) or a difference from the round's answers.
    public func isChanged(_ questionId: String, shown: BlueprintAnswer?) -> Bool {
        guard isSent else { return false }
        if let sent { return !BlueprintAnswer.same(shown, sent[questionId]) }
        return shown?.changedAt != nil || !BlueprintAnswer.same(shown, answers[questionId])
    }
}

extension BlueprintAnswer {
    /// A map of answers by question id, skipping any that don't read.
    static func decode(_ raw: [String: JSONValue]) -> [String: BlueprintAnswer] {
        var out: [String: BlueprintAnswer] = [:]
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for (key, value) in raw {
            guard let data = try? encoder.encode(value), let answer = try? decoder.decode(BlueprintAnswer.self, from: data) else { continue }
            out[key] = answer
        }
        return out
    }

    /// Answers as the runner takes them, by question id. One that says
    /// nothing (an emptied field, "Not chosen") is left out: it's no answer.
    public static func json(_ answers: [String: BlueprintAnswer], questions: [BlueprintQuestion] = []) -> JSONValue {
        var out: [String: JSONValue] = [:]
        for (id, answer) in answers {
            guard let kept = answer.normalized(for: questions.first { $0.id == id }) else { continue }
            out[id] = kept.jsonValue
        }
        return .object(out)
    }
}

public struct BlueprintStep: Sendable, Hashable, Codable, Identifiable {
    public struct Done: Sendable, Hashable, Codable {
        public var at: Date?
        public var note: String
        public var threadId: String?

        public init(at: Date? = nil, note: String, threadId: String? = nil) {
            self.at = at
            self.note = note
            self.threadId = threadId
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            at = ((try? c.decodeIfPresent(String.self, forKey: .at)) ?? nil).flatMap(ISO8601.parse)
            note = (try? c.decodeIfPresent(String.self, forKey: .note)) ?? ""
            threadId = (try? c.decodeIfPresent(String.self, forKey: .threadId)) ?? nil
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encodeIfPresent(at.map(ISO8601.format), forKey: .at)
            try c.encode(note, forKey: .note)
            try c.encodeIfPresent(threadId, forKey: .threadId)
        }

        enum CodingKeys: String, CodingKey { case at, note, threadId }
    }

    public var id: String
    public var title: String
    public var done: Done?

    public init(id: String, title: String, done: Done? = nil) {
        self.id = id
        self.title = title
        self.done = done
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? id
        done = (try? c.decodeIfPresent(Done.self, forKey: .done)) ?? nil
    }

    enum CodingKeys: String, CodingKey { case id, title, done }
}

public struct BlueprintBuild: Sendable, Hashable, Codable {
    public var threadId: String
    /// "thread" or "subagents".
    public var mode: String
    public var at: Date?

    public init(threadId: String, mode: String, at: Date? = nil) {
        self.threadId = threadId
        self.mode = mode
        self.at = at
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        threadId = try c.decode(String.self, forKey: .threadId)
        mode = (try? c.decodeIfPresent(String.self, forKey: .mode)) ?? "thread"
        at = ((try? c.decodeIfPresent(String.self, forKey: .at)) ?? nil).flatMap(ISO8601.parse)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(threadId, forKey: .threadId)
        try c.encode(mode, forKey: .mode)
        try c.encodeIfPresent(at.map(ISO8601.format), forKey: .at)
    }

    enum CodingKeys: String, CodingKey { case threadId, mode, at }
}

public struct Blueprint: Sendable, Hashable, Codable, Identifiable {
    public struct Checked: Sendable, Hashable, Codable {
        public var at: Date?
        public var findings: Int

        public init(at: Date? = nil, findings: Int) {
            self.at = at
            self.findings = findings
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            at = ((try? c.decodeIfPresent(String.self, forKey: .at)) ?? nil).flatMap(ISO8601.parse)
            findings = c.lenientInt(forKey: .findings) ?? 0
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encodeIfPresent(at.map(ISO8601.format), forKey: .at)
            try c.encode(findings, forKey: .findings)
        }

        enum CodingKeys: String, CodingKey { case at, findings }
    }

    public var id: String
    public var projectId: String
    public var folder: String
    public var path: String
    public var slug: String
    public var title: String
    public var status: BlueprintStatus
    /// The blueprint thread; nil for one found in a folder with no state.
    public var threadId: String?
    public var rounds: [BlueprintRound]
    public var steps: [BlueprintStep]
    public var builds: [BlueprintBuild]
    /// Question id to side chat thread id.
    public var sideChats: [String: String]
    public var checkThreadId: String?
    public var checked: Checked?
    public var editedByHand: Bool
    public var specStale: Bool
    /// The agent said the description is too small for a blueprint
    /// (`too_small`), and why. Cleared when it puts a round.
    public var tooSmall: String?
    public var costUsd: Double
    public var createdAt: Date?
    public var updatedAt: Date?

    public init(id: String, projectId: String = "", folder: String = "", path: String = "", slug: String = "", title: String,
                status: BlueprintStatus = .drafting, threadId: String? = nil, rounds: [BlueprintRound] = [], steps: [BlueprintStep] = [],
                builds: [BlueprintBuild] = [], sideChats: [String: String] = [:], checkThreadId: String? = nil, checked: Checked? = nil,
                editedByHand: Bool = false, specStale: Bool = false, tooSmall: String? = nil, costUsd: Double = 0,
                createdAt: Date? = nil, updatedAt: Date? = nil) {
        self.id = id
        self.projectId = projectId
        self.folder = folder
        self.path = path
        self.slug = slug
        self.title = title
        self.status = status
        self.threadId = threadId
        self.rounds = rounds
        self.steps = steps
        self.builds = builds
        self.sideChats = sideChats
        self.checkThreadId = checkThreadId
        self.checked = checked
        self.editedByHand = editedByHand
        self.specStale = specStale
        self.tooSmall = tooSmall
        self.costUsd = costUsd
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        projectId = (try? c.decodeIfPresent(String.self, forKey: .projectId)) ?? ""
        folder = (try? c.decodeIfPresent(String.self, forKey: .folder)) ?? ""
        path = (try? c.decodeIfPresent(String.self, forKey: .path)) ?? ""
        slug = (try? c.decodeIfPresent(String.self, forKey: .slug)) ?? ""
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? ""
        status = (try? c.decodeIfPresent(BlueprintStatus.self, forKey: .status)) ?? .drafting
        threadId = ((try? c.decodeIfPresent(String.self, forKey: .threadId)) ?? nil).flatMap { $0.isEmpty ? nil : $0 }
        rounds = c.lossyArray(BlueprintRound.self, forKey: .rounds)
        steps = c.lossyArray(BlueprintStep.self, forKey: .steps)
        builds = c.lossyArray(BlueprintBuild.self, forKey: .builds)
        let chats = (try? c.decodeIfPresent([String: JSONValue].self, forKey: .sideChats)) ?? nil
        sideChats = (chats ?? [:]).compactMapValues(\.stringValue)
        checkThreadId = (try? c.decodeIfPresent(String.self, forKey: .checkThreadId)) ?? nil
        checked = (try? c.decodeIfPresent(Checked.self, forKey: .checked)) ?? nil
        editedByHand = (try? c.decodeIfPresent(Bool.self, forKey: .editedByHand)) == true
        specStale = (try? c.decodeIfPresent(Bool.self, forKey: .specStale)) == true
        // `{ why, at }`, or a bare string from a runner that kept it short.
        if let small = (try? c.decodeIfPresent(TooSmall.self, forKey: .tooSmall)) ?? nil {
            tooSmall = small.why
        } else {
            tooSmall = (try? c.decodeIfPresent(String.self, forKey: .tooSmall)) ?? nil
        }
        costUsd = (try? c.decodeIfPresent(Double.self, forKey: .costUsd)) ?? 0
        createdAt = ((try? c.decodeIfPresent(String.self, forKey: .createdAt)) ?? nil).flatMap(ISO8601.parse)
        updatedAt = ((try? c.decodeIfPresent(String.self, forKey: .updatedAt)) ?? nil).flatMap(ISO8601.parse)
    }

    private struct TooSmall: Decodable { var why: String }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(projectId, forKey: .projectId)
        try c.encode(folder, forKey: .folder)
        try c.encode(path, forKey: .path)
        try c.encode(slug, forKey: .slug)
        try c.encode(title, forKey: .title)
        try c.encode(status, forKey: .status)
        try c.encodeIfPresent(threadId, forKey: .threadId)
        try c.encode(rounds, forKey: .rounds)
        try c.encode(steps, forKey: .steps)
        try c.encode(builds, forKey: .builds)
        try c.encode(sideChats, forKey: .sideChats)
        try c.encodeIfPresent(checkThreadId, forKey: .checkThreadId)
        try c.encodeIfPresent(checked, forKey: .checked)
        if editedByHand { try c.encode(true, forKey: .editedByHand) }
        if specStale { try c.encode(true, forKey: .specStale) }
        if let tooSmall { try c.encode(["why": tooSmall], forKey: .tooSmall) }
        try c.encode(costUsd, forKey: .costUsd)
        try c.encodeIfPresent(createdAt.map(ISO8601.format), forKey: .createdAt)
        try c.encodeIfPresent(updatedAt.map(ISO8601.format), forKey: .updatedAt)
    }

    enum CodingKeys: String, CodingKey {
        case id, projectId, folder, path, slug, title, status, threadId, rounds, steps, builds, sideChats, checkThreadId, checked
        case editedByHand, specStale, tooSmall, costUsd, createdAt, updatedAt
    }

    /// The round waiting for answers: the newest one not sent yet.
    public var openRound: BlueprintRound? {
        guard let last = rounds.last, !last.isSent else { return nil }
        return last
    }

    public var doneSteps: Int { steps.filter { $0.done != nil }.count }

    /// The newest build thread, for "Send a change to the build thread".
    public var newestBuild: BlueprintBuild? { builds.last }

    /// spec.md, relative to the project folder when it's inside it.
    public var specPath: String {
        let spec = (path as NSString).appendingPathComponent("spec.md")
        let base = folder.hasSuffix("/") ? folder : folder + "/"
        return !folder.isEmpty && spec.hasPrefix(base) ? String(spec.dropFirst(base.count)) : spec
    }
}

extension BlueprintRound {
    /// For encoding a round back (the mock, tests): the same fields.
    var jsonValue: JSONValue {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        var out: [String: JSONValue] = [
            "id": .string(id), "kind": .string(kind), "title": .string(title),
            "answers": BlueprintAnswer.json(answers),
        ]
        if let summary { out["summary"] = .string(summary) }
        if let data = try? encoder.encode(questions), let value = try? decoder.decode(JSONValue.self, from: data) { out["questions"] = value }
        out["assumptions"] = .array(assumptions.map { assumption in
            var fields: [String: JSONValue] = ["id": .string(assumption.id), "text": .string(assumption.text), "why": .string(assumption.why)]
            if assumption.askInstead { fields["askInstead"] = .bool(true) }
            return .object(fields)
        })
        if let note { out["note"] = .string(note) }
        if let sentAt { out["sentAt"] = .string(ISO8601.format(sentAt)) }
        if writeNow { out["writeNow"] = .bool(true) }
        if let sent { out["sent"] = BlueprintAnswer.json(sent) }
        let asked = assumptions.filter(\.askInstead).map { JSONValue.string($0.id) }
        if !asked.isEmpty { out["askInstead"] = .array(asked) }
        return .object(out)
    }
}

extension BlueprintQuestion {
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(text, forKey: .text)
        try c.encode(kind, forKey: .kind)
        if !options.isEmpty { try c.encode(options, forKey: .options) }
        try c.encodeIfPresent(recommended, forKey: .recommended)
        try c.encode(youDecide, forKey: .youDecide)
        try c.encodeIfPresent(min, forKey: .min)
        try c.encodeIfPresent(max, forKey: .max)
        try c.encodeIfPresent(step, forKey: .step)
        if several { try c.encode(true, forKey: .several) }
        if other { try c.encode(true, forKey: .other) }
        try c.encodeIfPresent(image, forKey: .image)
        try c.encodeIfPresent(moot, forKey: .moot)
    }
}

// MARK: Events

/// The `blueprint.*` events (docs/protocol.md, "Blueprints"): what the
/// transcript under the form shows of them. The form itself draws from the
/// summary's `blueprint`.
public enum BlueprintEvent: Sendable, Hashable {
    /// The agent put a round, or the check's findings became one.
    case round(BlueprintRound)
    /// Mike's submission of a round.
    case answered(roundId: String, answers: [String: BlueprintAnswer], note: String?, writeNow: Bool)
    case tooSmall(why: String)
    case written(steps: [BlueprintStep], path: String)
    /// A step marked done, or `all` for the whole blueprint.
    case step(stepId: String?, done: BlueprintStep.Done?, all: Bool)
    /// On a side chat's log: its `propose_answer`, drawn as a card with Use.
    case proposal(BlueprintProposal)

    private enum Keys: String, CodingKey { case round, roundId, answers, note, writeNow, why, steps, path, stepId, done, all, blueprintId, questionId, answer }

    static func decode(type: String, from decoder: Decoder) throws -> BlueprintEvent? {
        let c = try decoder.container(keyedBy: Keys.self)
        switch type {
        case "blueprint.round":
            return .round(try c.decode(BlueprintRound.self, forKey: .round))
        case "blueprint.answered":
            let raw = (try? c.decodeIfPresent([String: JSONValue].self, forKey: .answers)) ?? nil
            return .answered(roundId: (try? c.decodeIfPresent(String.self, forKey: .roundId)) ?? "",
                             answers: BlueprintAnswer.decode(raw ?? [:]),
                             note: ((try? c.decodeIfPresent(String.self, forKey: .note)) ?? nil).flatMap { $0.isEmpty ? nil : $0 },
                             writeNow: (try? c.decodeIfPresent(Bool.self, forKey: .writeNow)) == true)
        case "blueprint.tooSmall":
            return .tooSmall(why: (try? c.decodeIfPresent(String.self, forKey: .why)) ?? "")
        case "blueprint.written":
            return .written(steps: c.lossyArray(BlueprintStep.self, forKey: .steps),
                            path: (try? c.decodeIfPresent(String.self, forKey: .path)) ?? "")
        case "blueprint.step":
            return .step(stepId: (try? c.decodeIfPresent(String.self, forKey: .stepId)) ?? nil,
                         done: (try? c.decodeIfPresent(BlueprintStep.Done.self, forKey: .done)) ?? nil,
                         all: (try? c.decodeIfPresent(Bool.self, forKey: .all)) == true)
        case "blueprint.proposal":
            guard let questionId = (try? c.decodeIfPresent(String.self, forKey: .questionId)) ?? nil,
                  let answer = (try? c.decodeIfPresent(BlueprintAnswer.self, forKey: .answer)) ?? nil else { return nil }
            return .proposal(BlueprintProposal(blueprintId: ((try? c.decodeIfPresent(String.self, forKey: .blueprintId)) ?? nil) ?? "",
                                               questionId: questionId, answer: answer))
        default:
            return nil
        }
    }

    /// The one line the transcript shows for it.
    public var line: String {
        switch self {
        case .round(let round):
            let title = round.title.isEmpty ? "" : ": \(round.title)"
            return round.isCheck ? "Check round put\(title)" : "Round put\(title)"
        case .answered(_, let answers, _, let writeNow):
            let count = answers.values.filter(\.isGiven).count
            return "Round answered (\(count == 1 ? "1 answer" : "\(count) answers"))" + (writeNow ? ", write it now" : "")
        case .tooSmall(let why):
            return why.isEmpty ? "The agent thinks this is a small change." : "The agent thinks this is a small change: \(why)"
        case .written(let steps, _):
            return "Spec written, \(steps.count == 1 ? "1 step" : "\(steps.count) steps")"
        case .step(let stepId, let done, let all):
            if all { return "Blueprint marked done" }
            let note = done?.note ?? ""
            return "Step \(stepId ?? "") done" + (note.isEmpty ? "" : ": \(note)")
        case .proposal:
            return "Proposed an answer"
        }
    }
}

/// A side chat's proposed answer (`blueprint.proposal`), waiting for Use.
public struct BlueprintProposal: Sendable, Hashable {
    public var blueprintId: String
    public var questionId: String
    public var answer: BlueprintAnswer

    public init(blueprintId: String, questionId: String, answer: BlueprintAnswer) {
        self.blueprintId = blueprintId
        self.questionId = questionId
        self.answer = answer
    }

    /// The answer in words, for the card: by the question's kind when it's
    /// known, else as it came.
    public func text(for question: BlueprintQuestion?) -> String {
        if let question { return question.describe(answer) }
        switch answer.value {
        case .text(let text)?: return text
        case .list(let list)?: return list.joined(separator: ", ")
        case .number(let number)?: return BlueprintText.number(number)
        case nil: return answer.youDecide ? "you decide" : ""
        }
    }
}
