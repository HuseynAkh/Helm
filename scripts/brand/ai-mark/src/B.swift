// MARK: B, Compass loops
/// Four round loops on the compass points round a small open diamond: a slow turn plus a counter-turn three times
/// as fast. Four crossings, the fewest of the four options, so it holds up best at 16 pt.
let markB = Mark(letter: "B", name: "Compass loops", weightScale: 1.0, smallWeightScale: 0.95, rotate: .pi / 2) { t in
    complex(1, 1, t) + complex(0.70, -3, t)
}
