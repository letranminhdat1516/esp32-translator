import Foundation
import Testing
@testable import TranslatorCore

/// Levels at each mic (dBFS), from the usage: the other person holds the board (10-40 cm), the user is 0.5-1.5 m
/// from it and speaks into AirPods (a few cm) or the iPhone mic (held or on the table, about 30 cm).
private enum Levels {
    static let boardFloor: Float = -62
    /// The holder at the board, the user at the board
    static let holderAtBoard: Float = -30
    static let userAtBoard: Float = -46

    static let airPodsFloor: Float = -75
    static let userAtAirPods: Float = -20
    static let holderAtAirPods: Float = -48

    static let iPhoneFloor: Float = -65
    static let userAtIPhone: Float = -30
    static let holderAtIPhone: Float = -40
}

/// Feeds both sides 20 ms frames on one clock, as the engine does, and counts what was suppressed
private struct Sim {
    typealias Side = CrossTalkArbiter.Side

    var arbiter = CrossTalkArbiter()
    var t: TimeInterval = 0
    var suppressed: [Side: Int] = [:]
    var passed: [Side: Int] = [:]
    var ownerChanges = 0
    private var frame = 0

    /// Syllable-like shape: a few voiced frames, then a gap between syllables
    private static let shape: [Float] = [0, -2, -4, -1, -3, -6, -14]

    mutating func clear() {
        suppressed = [:]
        passed = [:]
        ownerChanges = 0
    }

    /// One 20 ms step. A side passes nil while its gate is closed (no audio reaches the engine). `speech` levels
    /// get the syllable shape; `flat` levels are fed as is.
    mutating func step(mine: Float?, theirs: Float?, speech: Bool = true) {
        let wobble = speech ? Self.shape[frame % Self.shape.count] : 0
        frame += 1
        for (side, level) in [(Side.mine, mine), (Side.theirs, theirs)] {
            guard let level else { continue }
            let before = arbiter.owner
            let d = arbiter.observe(side, levelDB: level + wobble, at: t)
            if arbiter.owner != before { ownerChanges += 1 }
            if d.suppress { suppressed[side, default: 0] += 1 } else { passed[side, default: 0] += 1 }
        }
        t += 0.02
    }

    mutating func run(_ seconds: TimeInterval, mine: Float?, theirs: Float?, speech: Bool = true) {
        for _ in 0..<Int((seconds / 0.02).rounded()) { step(mine: mine, theirs: theirs, speech: speech) }
    }

    /// A gate's pre-roll: 300 ms of background before the speech it opened on, handed over at once (one buffer
    /// from VoiceGate, one burst of packets from the board) and not counted
    mutating func preroll(mine: Float?, theirs: Float?) {
        let (s, p, c) = (suppressed, passed, ownerChanges)
        let start = t
        run(0.3, mine: mine, theirs: theirs, speech: false)
        t = start
        (suppressed, passed, ownerChanges) = (s, p, c)
    }

    /// Nobody streams for `seconds`
    mutating func pause(_ seconds: TimeInterval) {
        t += seconds
    }

    func share(_ side: Side) -> Double {
        let s = Double(suppressed[side] ?? 0), p = Double(passed[side] ?? 0)
        return s + p == 0 ? 0 : s / (s + p)
    }
}

struct CrossTalkArbiterTests {
    /// The user speaks into the AirPods; the board hears them faintly from a metre away
    @Test func userSpeakingWithAirPodsSuppressesTheBoardSide() {
        var sim = Sim()
        sim.preroll(mine: Levels.airPodsFloor, theirs: Levels.boardFloor)
        sim.run(2, mine: Levels.userAtAirPods, theirs: Levels.userAtBoard)
        #expect(sim.share(.theirs) > 0.95, "their recognizer hears silence while the user speaks")
        #expect(sim.share(.mine) == 0, "the user's own words are never suppressed")
        #expect(sim.arbiter.owner == .mine)
    }

    /// The holder speaks; the iPhone mic's gate lets them through
    @Test func otherPersonSpeakingSuppressesMySideWithTheIPhoneMic() {
        var sim = Sim()
        sim.preroll(mine: Levels.iPhoneFloor, theirs: Levels.boardFloor)
        sim.run(2, mine: Levels.holderAtIPhone, theirs: Levels.holderAtBoard)
        #expect(sim.share(.mine) > 0.95, "my recognizer hears silence while the other person speaks")
        #expect(sim.share(.theirs) == 0)
        #expect(sim.arbiter.owner == .theirs)
    }

    @Test func otherPersonSpeakingSuppressesMySideWithAirPods() {
        var sim = Sim()
        sim.preroll(mine: Levels.airPodsFloor, theirs: Levels.boardFloor)
        sim.run(2, mine: Levels.holderAtAirPods, theirs: Levels.holderAtBoard)
        #expect(sim.share(.mine) > 0.95)
        #expect(sim.share(.theirs) == 0)
    }

    /// The iPhone mic: the user's own lead over the board is small
    @Test func userSpeakingWithTheIPhoneMicSuppressesTheBoardSide() {
        var sim = Sim()
        sim.preroll(mine: Levels.iPhoneFloor, theirs: Levels.boardFloor)
        sim.run(2, mine: Levels.userAtIPhone, theirs: Levels.userAtBoard)
        #expect(sim.share(.theirs) > 0.95)
        #expect(sim.share(.mine) == 0)
    }

    /// A real conversation: turns alternate with pauses between them, each side keeps its own words
    @Test(arguments: [
        (Levels.airPodsFloor, Levels.userAtAirPods, Levels.holderAtAirPods),
        (Levels.iPhoneFloor, Levels.userAtIPhone, Levels.holderAtIPhone),
    ])
    func turnsAlternate(floor: Float, user: Float, holder: Float) {
        var sim = Sim()
        for _ in 0..<3 {
            sim.clear()
            sim.preroll(mine: floor, theirs: Levels.boardFloor)
            sim.run(2, mine: user, theirs: Levels.userAtBoard)
            sim.run(0.4, mine: floor, theirs: Levels.boardFloor, speech: false)   // hangovers
            #expect(sim.share(.mine) == 0, "my turn is passed")
            #expect(sim.share(.theirs) > 0.9, "the board's copy of my turn is suppressed")
            sim.pause(1)

            sim.clear()
            sim.preroll(mine: floor, theirs: Levels.boardFloor)
            sim.run(2, mine: holder, theirs: Levels.holderAtBoard)
            sim.run(0.4, mine: floor, theirs: Levels.boardFloor, speech: false)
            #expect(sim.share(.theirs) < 0.05, "their turn is passed")
            #expect(sim.share(.mine) > 0.9, "my mic's copy of their turn is suppressed")
            sim.pause(1)
        }
    }

    /// The board's packets come over BLE about 150 ms after the iPhone mic hears the same voice: the iPhone mic's
    /// gate opens on the holder first, and the board still takes over at once
    @Test func boardTakesOverWhenItsAudioArrivesLate() {
        var sim = Sim()
        sim.preroll(mine: Levels.iPhoneFloor, theirs: nil)
        sim.run(0.16, mine: Levels.holderAtIPhone, theirs: nil)
        #expect(sim.arbiter.owner == .mine, "only my side is heard so far")
        sim.clear()
        sim.preroll(mine: nil, theirs: Levels.boardFloor)
        sim.run(2, mine: Levels.holderAtIPhone, theirs: Levels.holderAtBoard)
        #expect(sim.share(.theirs) < 0.05, "the holder's words are not lost to the early owner")
        #expect(sim.share(.mine) > 0.9)
    }

    /// Both people talk over each other at their own levels: the floor stays with whoever had it, no flapping
    @Test func overlappingSpeechKeepsTheOwner() {
        var sim = Sim()
        sim.preroll(mine: Levels.iPhoneFloor, theirs: Levels.boardFloor)
        sim.run(1, mine: Levels.userAtIPhone, theirs: Levels.userAtBoard)
        sim.clear()
        sim.run(2, mine: Levels.userAtIPhone, theirs: Levels.holderAtBoard)
        #expect(sim.ownerChanges == 0)
        #expect(sim.arbiter.owner == .mine)
    }

    /// Background only on both sides (gates' pre-roll and hangover): nobody owns, nothing is suppressed
    @Test func silenceSuppressesNothing() {
        var sim = Sim()
        sim.run(3, mine: Levels.iPhoneFloor, theirs: Levels.boardFloor, speech: false)
        sim.run(3, mine: Levels.iPhoneFloor + 3, theirs: Levels.boardFloor + 3, speech: false)
        #expect(sim.arbiter.owner == nil)
        #expect(sim.share(.mine) == 0)
        #expect(sim.share(.theirs) == 0)
    }

    /// One side alone is never suppressed (the other side is silent, nobody competes)
    @Test func aSideAloneIsNeverSuppressed() {
        var sim = Sim()
        sim.preroll(mine: nil, theirs: Levels.boardFloor)
        sim.run(3, mine: nil, theirs: Levels.holderAtBoard)
        sim.pause(2)
        sim.preroll(mine: Levels.iPhoneFloor, theirs: nil)
        sim.run(3, mine: Levels.userAtIPhone, theirs: nil)
        #expect(sim.share(.mine) == 0)
        #expect(sim.share(.theirs) == 0)
    }

    /// After a turn the owner lets go: the other side's next turn, a moment later, is not suppressed
    @Test func theOwnerLetsGoSoonAfterItsTurn() {
        var sim = Sim()
        sim.preroll(mine: Levels.iPhoneFloor, theirs: Levels.boardFloor)
        sim.run(2, mine: Levels.userAtIPhone, theirs: Levels.userAtBoard)
        sim.pause(0.8)
        #expect(sim.arbiter.ownerAt(sim.t) == nil)
    }

    /// Two voices too close to call (no learned levels yet, no lead): both are let through
    @Test func aTooCloseCallSuppressesNothing() {
        var sim = Sim()
        sim.preroll(mine: Levels.iPhoneFloor, theirs: Levels.boardFloor)
        // the same distance above each floor on both sides, arriving together
        sim.run(1, mine: Levels.iPhoneFloor + 25, theirs: Levels.boardFloor + 25)
        #expect(sim.share(.mine) == 0)
        #expect(sim.share(.theirs) == 0)
    }

    @Test func resetForgetsTheOwnerAndLevels() {
        var sim = Sim()
        sim.preroll(mine: Levels.iPhoneFloor, theirs: Levels.boardFloor)
        sim.run(2, mine: Levels.userAtIPhone, theirs: Levels.userAtBoard)
        sim.arbiter.reset()
        #expect(sim.arbiter.owner == nil)
        let d = sim.arbiter.observe(.theirs, levelDB: Levels.userAtBoard, at: sim.t)
        #expect(!d.suppress)
    }
}
