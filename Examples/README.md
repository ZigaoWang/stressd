# Examples

`MinimalRun.swift` — start load, read telemetry, stop cleanly, in about 30
lines. It is the shortest honest use of the library and doubles as a check on
the API: if this program is awkward to write, the API is wrong.

To run it, add `StressKit` as a dependency and paste the body into an
executable target:

```swift
.package(url: "https://github.com/ZigaoWang/stressd.git", branch: "main")
```

Points worth copying:

- **Sample a baseline before starting load.** A developer machine is rarely
  idle; absolute utilization describes the browser as much as the tool.
- **`stop()` on every path.** Workers are real threads and outlive a dropped
  reference. `emergencyStop()` exists for paths that cannot `await`.
- **Every power field is optional.** Package power needs root and a desktop has
  no battery. Treat `nil` as normal, not as an error.
