# tama-incus-mac

A headless macOS Incus appliance host built in Swift using Apple's Virtualization.framework directly.

Requires Apple Silicon, macOS 15 or newer, and Swift 6.4.

```sh
swift build -Xswiftc -warnings-as-errors
swift test -Xswiftc -warnings-as-errors
swift build -c release -Xswiftc -warnings-as-errors
swift format format --in-place --recursive Package.swift Sources Tests
swift format lint --strict --recursive Package.swift Sources Tests
```

One library target owns the service; one executable constructs it. No external VM runtime is used.
