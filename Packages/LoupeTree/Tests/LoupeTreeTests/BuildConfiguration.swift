/// Whether this test binary was built with optimisation.
///
/// The layout time budgets (100 ms for a 200k-node arena) describe the shipped,
/// optimised code. A `-Onone` debug build runs the same layout roughly 500x slower,
/// so the timing assertions only apply under `swift test -c release`. The
/// correctness assertions in those tests still run in every configuration.
#if DEBUG
let isOptimizedBuild = false
#else
let isOptimizedBuild = true
#endif
