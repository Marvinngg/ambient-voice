/// Reference-type wrapper for mutable values captured by Sendable closures.
///
/// Used when a `@Sendable` closure (e.g. `AVAudioConverter.convert` input block)
/// needs to mutate a flag across invocations. The closure is documented as
/// synchronous and single-threaded by Apple, so the access pattern is race-free;
/// `Box` simply silences Swift 6's `SendableClosureCaptures` warning by replacing
/// a captured `var` with a captured reference.
final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}
