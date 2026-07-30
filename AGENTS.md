# Mail Surgeon – Agent Instructions

## Product

Mail Surgeon is a privacy-first macOS application for inspecting, cleaning,
recovering, indexing, and migrating email archives.

## Platform

- macOS 14+
- Swift 6
- SwiftUI
- Swift Package Manager until migration to Xcode project is approved

## Safety

- All analysis is read-only by default.
- Never delete, move, edit, or upload user messages without explicit user action.
- Never commit real mailbox data, credentials, tokens, private paths, or secrets.
- Migration and destructive actions must support dry-run and verification.

## Architecture

Keep these concerns separated:

- UI
- connectors
- parsing
- indexing
- analysis
- migration
- persistence

Preserve original RFC 822 bytes whenever possible.

## Performance

- Do not load large mailboxes entirely into memory.
- Prefer streaming parsers.
- Keep the SwiftUI main actor responsive.
- Support cancellation and progress reporting.

## Quality gate

Before finishing a task:

1. Run `swift build`.
2. Run `swift test`.
3. Describe changed files.
4. Describe limitations.
5. Do not claim success if either command fails.
