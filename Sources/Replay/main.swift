import Foundation
import PerifitCore

do {
    let args = Array(CommandLine.arguments.dropFirst())
    guard args.count == 1 || (args.count == 2 && args[0] == "--demo") else {
        throw AppError.invalid("Usage: perifit-replay SESSION.json\n       perifit-replay --demo OUTPUT.json")
    }
    if args.first == "--demo" {
        let settings = EngineSettings(), engine = try Engine(settings: EngineSettings())
        try engine.arm(true, at: 0)
        var session = SessionRecord(profile: "demo", simulated: true, settings: settings,
                                    candidate: nil, seed: 1, baseline: 1000, gain: 1)
        var episode = 0, lastPower = false
        for tick in 0..<3000 {
            let time = Double(tick)/50
            let pressure = UInt16(max(0, sin(time * 2 * .pi / 0.8)) * 900)
            let output = try engine.step(pressure, at: time)
            if output.wantsPower && !lastPower { episode += 1 }; lastPower = output.wantsPower
            session.frames.append(Frame(time: time, base: 1000+pressure, tip: 700, pressure: pressure,
                                        armed: true, episode: episode, active: output, confirmedPower: output.wantsPower))
        }
        session.complete = true
        try JSONEncoder().encode(session).write(to: URL(fileURLWithPath: args[1]), options: .atomic)
        print("Saved a 60-second synthetic trace. It cannot train a real-device profile.")
    } else {
        let record = try JSONDecoder().decode(SessionRecord.self, from: Data(contentsOf: URL(fileURLWithPath: args[0])))
        let replay = try Learner.replay(record, with: record.settings)
        let differences = zip(record.frames, replay.frames).filter {
            $0.active.score != $1.active.score || $0.active.controlPhase != $1.active.controlPhase ||
            $0.active.detectionPhase != $1.active.detectionPhase || $0.active.edge != $1.active.edge ||
            $0.active.detected != $1.active.detected
        }.count
        print("\(replay.frames.count) frames · \(replay.frames.filter { $0.active.edge }.count) cutoffs · \(replay.frames.filter { $0.active.detected }.count) detector events · \(differences) differing frames")
        if differences != 0 { exit(1) }
    }
} catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
