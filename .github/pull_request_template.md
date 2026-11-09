<!--
  Fill every section: "n/a" is an answer, an empty section is not.
  Never paste a secret value; name the setting instead.
-->

## Summary

<!-- What changed and why, 2-4 lines. Link the issue it closes. -->

## Sensitive paths changed

<!-- List any changed file under: *.entitlements, Info.plist, *.xcdatamodeld/, *.xcconfig,
     project.pbxproj, .github/, .gitleaks.toml (the CODEOWNERS list). "none" is an answer. -->

## Testing

<!-- What ran, where, and what it proved. Commands and results, not "tested locally". -->

- [ ] `xcodebuild build-for-testing -project app/TotalRekall.xcodeproj -scheme TotalRekall -destination 'platform=macOS' CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO` -- 0 errors
- [ ] `xcodebuild test-without-building` (same flags, plus `-only-testing:TotalRekallTests`) -- all tests pass
- [ ] `swiftlint` (run in `app/`) -- no errors
- [ ] UI change: a screenshot of each changed screen

## Risk

<!-- What could break, for whom, and how you would notice. Name the blast radius: a Core Data
     model change (its migration), an entitlement, a Keychain change, a new dependency, a
     signing or build-setting change. "Low" needs a reason. -->

## How to revert

<!-- The exact steps. A squash merge reverts with `git revert <squash-sha>` on a branch, through
     a PR like any other change. Say what a code revert does NOT undo: a Core Data store already
     migrated on a user's machine, a Keychain item already written, a release already shipped. -->
