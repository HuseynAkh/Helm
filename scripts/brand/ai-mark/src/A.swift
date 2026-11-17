// MARK: A, Wheel rosette
/// A ring with eight loops thrown outward round an open hub, the handles of a ship's wheel: one line, a slow turn
/// plus a fast counter-turn (seven times as fast) that throws a loop out every eighth of the way round, and a small
/// ninth harmonic that draws each loop out along its spoke. Loop at the top; eight crossings.
let markA = Mark(letter: "A", name: "Wheel rosette", weightScale: 0.65, smallWeightScale: 0.55, rotate: .pi / 2) { t in
    complex(1, 1, t) + complex(0.40, -7, t) + complex(0.06, 9, t)
}
