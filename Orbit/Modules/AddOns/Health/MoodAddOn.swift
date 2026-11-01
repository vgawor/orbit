import SwiftUI

struct MoodEntry: Codable, Equatable {
    /// 1 (low) … 5 (great).
    var mood: Int
    /// 1 (tired) … 5 (full of energy).
    var energy: Int
    var note: String = ""
}

struct MoodLog: Codable, Equatable {
    var days: [String: MoodEntry] = [:]

    static let faces = ["😞", "🙁", "😐", "🙂", "😄"]
    static let words = ["Low", "Meh", "Okay", "Good", "Great"]

    static func face(_ mood: Int) -> String { faces[min(max(mood, 1), 5) - 1] }
    static func word(_ mood: Int) -> String { words[min(max(mood, 1), 5) - 1] }

    mutating func record(_ entry: MoodEntry, on key: String) {
        var e = entry
        e.mood = min(max(e.mood, 1), 5)
        e.energy = min(max(e.energy, 1), 5)
        e.note = String(e.note.trimmingCharacters(in: .whitespacesAndNewlines).prefix(140))
        days[key] = e
    }

    /// Days in a row with a check-in, counting back from today (or yesterday, if today isn't done yet).
    func streak(now: Date = .now, calendar: Calendar = .current) -> Int {
        var day = calendar.startOfDay(for: now)
        if days[HealthDay.key(day, calendar: calendar)] == nil {
            guard let y = calendar.date(byAdding: .day, value: -1, to: day) else { return 0 }
            day = y
        }
        var n = 0
        while days[HealthDay.key(day, calendar: calendar)] != nil {
            n += 1
            guard let prev = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = prev
        }
        return n
    }
}

/// Orbit mirrors the mood you pick: drained, unimpressed, fine, happy, over the moon.
enum MoodOrbit {
    static func mood(_ mood: Int?) -> OrbitView.Mood {
        guard let mood else { return .wide }
        switch min(max(mood, 1), 5) {
        case 1: return .closed
        case 2: return .squint
        case 3: return .normal
        default: return .happy
        }
    }
    static func motion(_ mood: Int?) -> OrbitView.Motion {
        switch mood {
        case 1: .sleep
        case 5: .celebrate
        default: .idle
        }
    }
    /// Low and meh look a little down.
    static func gaze(_ mood: Int?) -> CGVector? {
        switch mood {
        case 1, 2: CGVector(dx: 0.2, dy: 0.9)
        default: nil
        }
    }
}

enum MoodNudge {
    /// A gentle nudge from 14:00 if you haven't checked in today.
    static func isDue(now: Date, checkedIn: Bool, fromHour: Int = 14, calendar: Calendar = .current) -> Bool {
        !checkedIn && calendar.component(.hour, from: now) >= fromHour
    }
}

/// Mood check-in: once a day, how you feel and how much energy you have.
@MainActor
@Observable
final class MoodAddOn: AddOnModule {
    let id = "addon.mood"
    let title = "Mood"
    let symbol = "face.smiling"
    let addOn = AddOnInfo(category: .health, tier: .free, summary: "A 10-second daily check-in on mood and energy, with your last two weeks.")

    static let tint = Color(red: 1, green: 0.78, blue: 0.3)
    private static let file = "addon-mood"

    private(set) var log: MoodLog
    var draftMood: Int?
    var draftEnergy = 3
    var draftNote = ""
    /// After saving, the form folds away until you choose to edit.
    var editing = true
    private let ctx: AddOnContext

    init(_ ctx: AddOnContext) {
        self.ctx = ctx
        if ModuleRegistry.isPreview {
            var sample = MoodLog()
            let moods = [4, 3, 4, 5, 2, 3, 4, 4, 3, 5, 4, 3, 4]
            let energy = [3, 2, 4, 5, 2, 3, 3, 4, 2, 4, 4, 3, 3]
            for (i, key) in HealthDay.lastKeys(14).dropLast().enumerated() where i != 4 {
                sample.record(MoodEntry(mood: moods[i], energy: energy[i]), on: key)
            }
            log = sample
            draftMood = 4
            draftEnergy = 3
        } else {
            log = Storage.load(MoodLog.self, from: Self.file) ?? MoodLog()
            loadDraft()
        }
    }

    var todayEntry: MoodEntry? { log.days[HealthDay.key(.now)] }

    func loadDraft() {
        if let e = todayEntry {
            draftMood = e.mood; draftEnergy = e.energy; draftNote = e.note; editing = false
        } else {
            draftMood = nil; draftEnergy = 3; draftNote = ""; editing = true
        }
    }

    func save() {
        guard let mood = draftMood else { return }
        log.record(MoodEntry(mood: mood, energy: draftEnergy, note: draftNote), on: HealthDay.key(.now))
        log.days = HealthDay.prune(log.days, keep: 60)
        editing = false
        if !ModuleRegistry.isPreview { Storage.save(log, to: Self.file) }
    }

    func start() { if todayEntry == nil { loadDraft() } }

    private var nudge: Bool { MoodNudge.isDue(now: .now, checkedIn: todayEntry != nil) }

    var attention: Attention? {
        guard nudge else { return nil }
        return Attention(id: "mood-\(HealthDay.key(.now))", symbol: "face.smiling", tint: Self.tint,
                         label: "Mood?", priority: 1, headline: "How are you today?")
    }

    var peekChip: PeekChip? {
        nudge ? PeekChip(symbol: "face.smiling", text: "How are you?", tint: Self.tint, priority: 1) : nil
    }

    var homeCard: AnyView? {
        AnyView(Button { self.ctx.openPanel(self.id) } label: {
            NotchCard {
                VStack(alignment: .leading, spacing: 6) {
                    CardLabel("Mood")
                    HStack(spacing: 12) {
                        let mood = todayEntry?.mood
                        OrbitView(size: 40, mood: MoodOrbit.mood(mood), motion: mood == 5 ? .idle : MoodOrbit.motion(mood),
                                  gaze: MoodOrbit.gaze(mood))
                        VStack(alignment: .leading, spacing: 2) {
                            if let e = todayEntry {
                                Text("\(MoodLog.face(e.mood)) \(MoodLog.word(e.mood))").font(.system(size: 15, weight: .semibold))
                                Text("Energy \(e.energy)/5").font(.system(size: 11)).foregroundStyle(Tokens.secondary)
                            } else {
                                Text("How are you today?").font(.system(size: 15, weight: .semibold))
                                Text("Tap to check in").font(.system(size: 11)).foregroundStyle(Tokens.secondary)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }.buttonStyle(.plain))
    }

    var panel: AnyView { AnyView(MoodPanel(module: self)) }
}

private struct MoodPanel: View {
    @Bindable var module: MoodAddOn
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AddOnHeader(symbol: module.symbol, title: "Mood check-in", subtitle: subtitle, tint: MoodAddOn.tint)
            HStack(alignment: .top, spacing: 12) {
                NotchCard { if module.editing { form } else { saved } }
                    .frame(maxWidth: .infinity)
                NotchCard { history }.frame(width: 262)
            }
        }
    }

    private var subtitle: String {
        module.todayEntry == nil ? "Once a day, just a quick check. No right answers." : "Checked in today. Thanks!"
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardLabel("How are you feeling?")
            HStack(spacing: 8) {
                ForEach(1...5, id: \.self) { m in
                    let selected = module.draftMood == m
                    Button { module.draftMood = m } label: {
                        VStack(spacing: 3) {
                            Text(MoodLog.face(m)).font(.system(size: 28))
                            Text(MoodLog.word(m)).font(.system(size: 10, weight: selected ? .semibold : .regular))
                                .foregroundStyle(selected ? .white : Tokens.secondary)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                        .glassSurface(RoundedRectangle(cornerRadius: 14, style: .continuous), selected: selected)
                        .opacity(module.draftMood == nil || selected ? 1 : 0.55)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            CardLabel("Energy")
            HStack(spacing: 6) {
                ForEach(1...5, id: \.self) { e in
                    Button { module.draftEnergy = e } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "bolt.fill").font(.system(size: 9))
                            Text("\(e)").font(.system(size: 12, weight: .medium))
                        }
                        .foregroundStyle(e <= module.draftEnergy ? Color.black : Tokens.secondary)
                        .frame(maxWidth: .infinity).padding(.vertical, 6)
                        .background { if e <= module.draftEnergy { Capsule().fill(MoodAddOn.tint) } }
                        .glassSurface(Capsule())
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            TextField("A short note (optional)", text: $module.draftNote)
                .textFieldStyle(.plain).font(.system(size: 12))
                .padding(.horizontal, 12).padding(.vertical, 8)
                .glassSurface(Capsule())
            Spacer(minLength: 0)
            HStack(alignment: .bottom) {
                PillButton(title: module.todayEntry == nil ? "Check in" : "Save") { module.save() }
                    .opacity(module.draftMood == nil ? 0.4 : 1)
                    .disabled(module.draftMood == nil)
                if module.todayEntry != nil {
                    GlassPillButton(title: "Cancel") { module.loadDraft() }
                }
                Spacer()
                // Orbit tries the mood on as you pick it.
                OrbitView(size: 64, mood: MoodOrbit.mood(module.draftMood),
                          motion: reduceMotion ? .still : MoodOrbit.motion(module.draftMood), gaze: MoodOrbit.gaze(module.draftMood))
            }
        }
    }

    private var saved: some View {
        VStack(spacing: 10) {
            HStack { CardLabel("Today"); Spacer() }
            if let e = module.todayEntry {
                Spacer(minLength: 0)
                OrbitView(size: 84, mood: MoodOrbit.mood(e.mood), motion: reduceMotion ? .still : MoodOrbit.motion(e.mood),
                          gaze: MoodOrbit.gaze(e.mood))
                Text("\(MoodLog.face(e.mood)) \(MoodLog.word(e.mood))").font(.system(size: 17, weight: .semibold))
                HStack(spacing: 4) {
                    ForEach(1...5, id: \.self) { i in
                        Image(systemName: "bolt.fill").font(.system(size: 11))
                            .foregroundStyle(i <= e.energy ? MoodAddOn.tint : Color.white.opacity(0.15))
                    }
                }
                if !e.note.isEmpty {
                    Text("“\(e.note)”").font(.system(size: 12)).foregroundStyle(Tokens.secondary)
                        .multilineTextAlignment(.center).lineLimit(3)
                }
                Spacer(minLength: 0)
                GlassPillButton(title: "Edit", symbol: "pencil") { module.editing = true }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var history: some View {
        let days = HealthDay.lastDays(14)
        let streak = module.log.streak()
        return VStack(alignment: .leading, spacing: 8) {
            CardLabel("Last 14 days")
            Text("Mood").font(.system(size: 10)).foregroundStyle(Tokens.faint)
            row(days, height: 160) { entry, h in
                Circle().fill(MoodAddOn.tint.opacity(0.4 + 0.12 * Double(entry.mood)))
                    .frame(width: 11, height: 11)
                    .offset(y: -(h - 11) * CGFloat(entry.mood - 1) / 4)
            }
            Text("Energy").font(.system(size: 10)).foregroundStyle(Tokens.faint)
            row(days, height: 54) { entry, h in
                RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.35))
                    .frame(width: 8, height: h * CGFloat(entry.energy) / 5)
            }
            HStack(spacing: 0) {
                ForEach(days, id: \.self) { day in
                    Text(HealthDay.letter(day)).font(.system(size: 9))
                        .foregroundStyle(Calendar.current.isDateInToday(day) ? .white : Tokens.faint)
                        .frame(maxWidth: .infinity)
                }
            }
            Spacer(minLength: 0)
            Text(streak > 0 ? "\(streak) \(streak == 1 ? "day" : "days") in a row" : "Check in today to start a streak")
                .font(.system(size: 11)).foregroundStyle(Tokens.secondary)
        }
    }

    /// One mark per day, bottom-aligned; an empty ring for days without a check-in.
    private func row<Mark: View>(_ days: [Date], height: CGFloat,
                                 @ViewBuilder mark: @escaping (MoodEntry, CGFloat) -> Mark) -> some View {
        HStack(spacing: 0) {
            ForEach(days, id: \.self) { day in
                ZStack(alignment: .bottom) {
                    Color.clear
                    if let entry = module.log.days[HealthDay.key(day)] {
                        mark(entry, height)
                    } else {
                        Circle().stroke(Color.white.opacity(0.16), lineWidth: 1).frame(width: 6, height: 6)
                    }
                }
                .frame(maxWidth: .infinity).frame(height: height)
            }
        }
    }
}
