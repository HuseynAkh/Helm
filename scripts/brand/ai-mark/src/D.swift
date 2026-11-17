// MARK: D, Trefoil knot
/// Three interlaced loops, one pointing up: a turn at twice the speed against a slower counter-turn, the trefoil
/// knot's own drawing, with a small fourth harmonic that leans the loops into teardrops. Three crossings.
let markD = Mark(letter: "D", name: "Trefoil knot", weightScale: 1.0, smallWeightScale: 1.0, rotate: .pi / 2) { t in
    complex(1, 2, t) + complex(0.60, -1, t) + complex(0.06, -4, t)
}
