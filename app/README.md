# Total Rekall app

This folder holds the Total Rekall macOS app.

- `project.yml` is the XcodeGen spec; `TotalRekall.xcodeproj` is generated from it (`xcodegen generate`).
- `TotalRekall/` is the app target (menu bar app, SwiftUI and AppKit).
- `TotalRekallTests/` holds the unit tests and `TotalRekallUITests/` the UI tests.
- `Fixtures/` holds the sample data the tests and fixture-launched debug runs use.

Build, install and usage instructions are in the [root README](../README.md).
