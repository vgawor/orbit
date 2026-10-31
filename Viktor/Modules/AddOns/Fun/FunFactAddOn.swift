import AppKit
import SwiftUI

/// The pure part of Fun fact: the facts and which one belongs to a day.
enum FunFactLogic {
    struct Fact: Equatable {
        let topic: Topic
        let text: String
    }

    enum Topic: String, CaseIterable {
        case animals, space, science, nature, food
        var title: String { rawValue.capitalized }
        var symbol: String {
            switch self {
            case .animals: "pawprint.fill"
            case .space: "moon.stars.fill"
            case .science: "atom"
            case .nature: "leaf.fill"
            case .food: "fork.knife"
            }
        }
        var tint: Color {
            switch self {
            case .animals: Color(red: 1, green: 0.62, blue: 0.35)
            case .space: Color(red: 0.63, green: 0.59, blue: 0.99)
            case .science: Color(red: 0.36, green: 0.78, blue: 1)
            case .nature: Color(red: 0.35, green: 0.85, blue: 0.5)
            case .food: Color(red: 1, green: 0.78, blue: 0.3)
            }
        }
    }

    /// The same fact all day; the next one tomorrow. Counts days from 1 January 2001.
    static func index(for date: Date, count: Int, calendar: Calendar = .current) -> Int {
        guard count > 0 else { return 0 }
        var c = DateComponents(); c.year = 2001; c.month = 1; c.day = 1
        let origin = calendar.date(from: c) ?? Date(timeIntervalSinceReferenceDate: 0)
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: origin), to: calendar.startOfDay(for: date)).day ?? 0
        return ((days % count) + count) % count
    }

    static let facts: [Fact] = [
        // Animals
        Fact(topic: .animals, text: "Octopuses have three hearts and blue blood."),
        Fact(topic: .animals, text: "Wombats make cube-shaped poop."),
        Fact(topic: .animals, text: "A group of flamingos is called a flamboyance."),
        Fact(topic: .animals, text: "Sharks were around before trees: they're older by tens of millions of years."),
        Fact(topic: .animals, text: "Butterflies taste with their feet."),
        Fact(topic: .animals, text: "Sea otters often hold hands while they sleep so they don't drift apart."),
        Fact(topic: .animals, text: "A shrimp's heart is in its head."),
        Fact(topic: .animals, text: "Cats can't taste sweetness."),
        Fact(topic: .animals, text: "Some male penguins offer a smooth pebble to the penguin they want to pair with."),
        Fact(topic: .animals, text: "Crows can recognise individual human faces, and remember them for years."),
        Fact(topic: .animals, text: "Honeybees tell each other where flowers are with a waggle dance."),
        Fact(topic: .animals, text: "Rats make happy, ultrasonic chirps when they're tickled."),
        Fact(topic: .animals, text: "Starfish have no brain and no blood."),
        Fact(topic: .animals, text: "Hummingbirds can fly backwards."),
        Fact(topic: .animals, text: "Owls can't move their eyes, so they turn their heads up to about 270 degrees instead."),
        Fact(topic: .animals, text: "Dolphins have signature whistles that work a lot like names."),
        Fact(topic: .animals, text: "Glass frogs have see-through bellies: you can watch their hearts beat."),
        Fact(topic: .animals, text: "Axolotls can regrow lost legs, and even parts of their heart and brain."),
        Fact(topic: .animals, text: "Tardigrades, tiny water bears, have survived trips to the vacuum of space."),
        Fact(topic: .animals, text: "Giraffes have seven neck bones, the same number as you."),
        Fact(topic: .animals, text: "Male seahorses are the ones that carry the babies."),
        Fact(topic: .animals, text: "Polar bears have black skin, and their white-looking fur is actually see-through."),
        Fact(topic: .animals, text: "No two zebras have exactly the same stripes."),
        Fact(topic: .animals, text: "An ostrich's eye is bigger than its brain."),
        Fact(topic: .animals, text: "Goats have rectangular pupils, which help them watch all around for danger."),
        Fact(topic: .animals, text: "Woodpeckers have tongues so long they wrap around the back of the skull."),
        Fact(topic: .animals, text: "Dragonflies catch most of the prey they chase, around 95 percent in one study."),
        Fact(topic: .animals, text: "Ants don't have lungs; air flows in through tiny holes along their bodies."),
        Fact(topic: .animals, text: "Most frogs don't need to drink: they soak up water through their skin."),
        Fact(topic: .animals, text: "Some turtles can take in oxygen through their bottoms while underwater."),
        Fact(topic: .animals, text: "A blue whale's heart can weigh around 180 kilograms."),
        Fact(topic: .animals, text: "Koalas have fingerprints that look remarkably like human ones."),
        Fact(topic: .animals, text: "Elephants are one of very few mammals that can't jump."),
        Fact(topic: .animals, text: "A group of owls is called a parliament."),
        Fact(topic: .animals, text: "Squirrels plant lots of trees by burying nuts and forgetting some of them."),
        Fact(topic: .animals, text: "Fruit flies were the first animals sent to space, in 1947."),
        Fact(topic: .animals, text: "Sloths can hold their breath for up to about 40 minutes."),
        Fact(topic: .animals, text: "Cheetahs can reach about 100 km/h in roughly three seconds."),

        // Space
        Fact(topic: .space, text: "A day on Venus is longer than a year on Venus."),
        Fact(topic: .space, text: "Saturn is less dense than water, so it would float in a big enough bathtub."),
        Fact(topic: .space, text: "A teaspoon of neutron star would weigh about a billion tonnes."),
        Fact(topic: .space, text: "There are more trees on Earth than stars in the Milky Way."),
        Fact(topic: .space, text: "Sunlight takes about 8 minutes and 20 seconds to reach Earth."),
        Fact(topic: .space, text: "Venus spins the opposite way to most planets, so the Sun rises in the west there."),
        Fact(topic: .space, text: "Olympus Mons on Mars is about two and a half times as tall as Mount Everest."),
        Fact(topic: .space, text: "A day on Mars is only about 40 minutes longer than a day on Earth."),
        Fact(topic: .space, text: "Jupiter's Great Red Spot is a storm wider than the whole Earth."),
        Fact(topic: .space, text: "The Moon drifts about 3.8 centimetres further from Earth every year."),
        Fact(topic: .space, text: "More than a million Earths could fit inside the Sun."),
        Fact(topic: .space, text: "Pluto hasn't finished a single trip around the Sun since it was discovered in 1930."),
        Fact(topic: .space, text: "Footprints left on the Moon could last for millions of years: there's no wind to blow them away."),
        Fact(topic: .space, text: "Sunsets on Mars look blue."),
        Fact(topic: .space, text: "The space station circles Earth about every 90 minutes, so its crew sees around 16 sunrises a day."),
        Fact(topic: .space, text: "Astronauts get a few centimetres taller in space because their spines stretch out."),
        Fact(topic: .space, text: "A comet's tail always points away from the Sun."),
        Fact(topic: .space, text: "Venus is the hottest planet, even though Mercury is closer to the Sun."),
        Fact(topic: .space, text: "Scientists think it may rain diamonds deep inside Uranus and Neptune."),
        Fact(topic: .space, text: "Earth is the only planet in our solar system not named after a god."),
        Fact(topic: .space, text: "From sunrise to sunrise, one day on Mercury lasts about 176 Earth days."),

        // Science
        Fact(topic: .science, text: "Lightning is about five times hotter than the surface of the Sun."),
        Fact(topic: .science, text: "The Eiffel Tower can grow about 15 centimetres taller in summer as the iron expands."),
        Fact(topic: .science, text: "At its triple point, water can boil and freeze at the same time."),
        Fact(topic: .science, text: "Sound travels about four times faster in water than in air."),
        Fact(topic: .science, text: "Your body glows very faintly, but about a thousand times too weakly for eyes to see."),
        Fact(topic: .science, text: "The lining of your stomach renews itself every few days."),
        Fact(topic: .science, text: "Snow is actually clear; it looks white because it scatters light."),
        Fact(topic: .science, text: "A fluffy cumulus cloud can weigh around 500 tonnes."),
        Fact(topic: .science, text: "We have leap years because Earth takes about 365 and a quarter days to go round the Sun."),
        Fact(topic: .science, text: "A cat's purr vibrates somewhere between about 25 and 150 times a second."),
        Fact(topic: .science, text: "Earth isn't a perfect ball: it bulges a little around the equator."),

        // Nature
        Fact(topic: .nature, text: "Some bamboo can grow almost a metre in a single day."),
        Fact(topic: .nature, text: "The earthy smell after rain has a name: petrichor."),
        Fact(topic: .nature, text: "A teaspoon of healthy soil holds more living things than there are people on Earth."),
        Fact(topic: .nature, text: "Mount Everest grows a few millimetres taller every year."),
        Fact(topic: .nature, text: "The Atlantic Ocean gets a few centimetres wider every year."),
        Fact(topic: .nature, text: "The coldest temperature measured on Earth's surface was about −89 °C, in Antarctica."),
        Fact(topic: .nature, text: "Hawaii creeps a few centimetres closer to Japan every year."),

        // Food
        Fact(topic: .food, text: "Bananas are berries, but strawberries aren't."),
        Fact(topic: .food, text: "Honey keeps almost forever: pots of it have been found in ancient Egyptian tombs."),
        Fact(topic: .food, text: "Peanuts aren't nuts; they're legumes, like peas and beans."),
        Fact(topic: .food, text: "A pineapple plant can take up to two years to grow one pineapple."),
        Fact(topic: .food, text: "A strawberry wears around 200 seeds on the outside."),
        Fact(topic: .food, text: "Botanically speaking, cucumbers and avocados are fruit."),
    ]
}

/// Fun fact: one small, true, cheerful fact a day.
@MainActor
@Observable
final class FunFactAddOn: AddOnModule {
    let id = "addon.funfact"
    let title = "Fun fact"
    let symbol = "lightbulb.fill"
    let addOn = AddOnInfo(category: .fun, tier: .free,
                          summary: "A small, true and cheerful fact every day, with more when you want them.")

    /// How many facts past today's you've flipped to.
    private(set) var offset = 0
    /// For the card flip: 0 flat, 90 edge-on.
    private(set) var turn: Double = 0
    private(set) var copied = false
    private var flipping: Task<Void, Never>?
    private let openPanel: @MainActor (String) -> Void

    init(openPanel: @escaping @MainActor (String) -> Void) {
        self.openPanel = openPanel
    }

    var todayIndex: Int { FunFactLogic.index(for: .now, count: FunFactLogic.facts.count) }
    var fact: FunFactLogic.Fact { FunFactLogic.facts[(todayIndex + offset) % FunFactLogic.facts.count] }

    func stop() { flipping?.cancel(); turn = 0 }

    func another(reduceMotion: Bool) {
        guard flipping == nil else { return }
        copied = false
        if reduceMotion {
            withAnimation(.easeInOut(duration: 0.2)) { offset += 1 }
            return
        }
        flipping = Task { [weak self] in
            guard let self else { return }
            withAnimation(.easeIn(duration: 0.16)) { self.turn = 90 }
            try? await Task.sleep(for: .seconds(0.16))
            self.offset += 1
            self.turn = -90
            withAnimation(.spring(response: 0.32, dampingFraction: 0.72)) { self.turn = 0 }
            try? await Task.sleep(for: .seconds(0.2))
            self.flipping = nil
        }
    }

    func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(fact.text, forType: .string)
        withAnimation(Tokens.spring) { copied = true }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation(Tokens.spring) { self?.copied = false }
        }
    }

    var homeCard: AnyView? {
        AnyView(Button { self.openPanel(self.id) } label: {
            NotchCard {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 6) {
                        CardLabel("Fun fact")
                        Text(FunFactLogic.facts[todayIndex].text)
                            .font(.system(size: 12)).foregroundStyle(Tokens.secondary)
                            .lineLimit(5).multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    Spacer(minLength: 0)
                    FunPropOrbit(prop: .bulb, size: 36, mood: .happy).padding(.top, 14).padding(.trailing, 6)
                }
            }
        }
        .buttonStyle(.plain))
    }

    var panel: AnyView { AnyView(FunFactPanel(model: self)) }
}

// MARK: - Views

private struct FunFactPanel: View {
    let model: FunFactAddOn
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let fact = model.fact
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                AddOnHeader(symbol: "lightbulb.fill", title: "Fun fact",
                            subtitle: model.offset == 0 ? "Today's fact" : "One more for the road", tint: .funTint)
                GlassPillButton(title: model.copied ? "Copied" : "Copy", symbol: model.copied ? "checkmark" : "doc.on.doc") { model.copy() }
            }
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 6) {
                    Image(systemName: fact.topic.symbol).font(.system(size: 11, weight: .semibold))
                    Text(fact.topic.title).font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(fact.topic.tint)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(fact.topic.tint.opacity(0.15), in: Capsule())
                Spacer(minLength: 0)
                Text(fact.text)
                    .font(.system(size: 24, weight: .semibold))
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 0)
                HStack(alignment: .bottom) {
                    FunPropOrbit(prop: .bulb, size: 42, mood: .happy).padding(.top, 10)
                    Text("Did you know?").font(.system(size: 12)).foregroundStyle(Tokens.faint)
                    Spacer()
                    PillButton(title: "Another") { model.another(reduceMotion: reduceMotion) }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(LinearGradient(colors: [fact.topic.tint.opacity(0.16), .clear], startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .glassCard(22)
            .rotation3DEffect(.degrees(model.turn), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
        }
    }
}
