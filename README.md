# record2gif

Native macOS screen recorder (QuickTime-style) that exports straight to animated GIF with a
selectable output resolution. See [SPEC.md](SPEC.md).

## Requirements

- macOS 14 or later
- Swift 5.10+ / Swift 6 toolchain

## Build & Run

```bash
# Build debug binary
make build

# Run unit tests
make test

# Build ad-hoc signed macOS .app bundle at build/record2gif.app
make app

# Build and launch build/record2gif.app
make run

# Clean build artifacts
make clean
```
