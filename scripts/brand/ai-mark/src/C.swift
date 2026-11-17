// MARK: C, Looped spark
/// The four-point spark as one open ribbon: the spark's concave sides, and at each of its four points the line runs
/// past the point and turns back through a small loop. The same turn and counter-turn as B, held just past the point
/// where the tips first loop, with a slight fifth harmonic that rounds the loops open.
let markC = Mark(letter: "C", name: "Looped spark", weightScale: 0.72, smallWeightScale: 0.8, rotate: .pi / 2) { t in
    complex(1, 1, t) + complex(0.55, -3, t) + complex(-0.035, 5, t)
}
