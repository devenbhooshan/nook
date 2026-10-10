# Contributing to Nook

Thanks for helping. Nook is small on purpose, so a few principles guide what goes in.

## Principles

1. **Your mail stays yours.** No feature may send mail content, metadata or usage data anywhere except the user's own mail provider and the user's own model server. No analytics, no crash reporters that phone home, and no third-party SDKs.
2. **Local first.** Reads come from the local store. Writes apply locally first, then sync. The UI should never wait on the network.
3. **Keyboard first, calm by default.** Every common action has a single-key shortcut. Visual changes should make the interface quieter, not busier.
4. **No dependencies** unless there's no reasonable alternative. Today Nook uses Apple frameworks plus SQLCipher (database encryption, pinned to an exact, checksum-verified release).

## Getting set up

```bash
./scripts/test.sh            # all tests must pass
swift run Nook --demo        # run the app on sample data, no Google account needed
```

## Where code goes

- Logic belongs in **`NookCore`**, with tests. Parsing, querying, syncing, prompt building and shortcut mapping all live there.
- **`Nook`** (the app) should stay a thin layer of SwiftUI views plus `AppStore`, which maps user intent onto `NookCore`.
- Anything that talks to the network goes behind a protocol (`GmailService`, `HTTPTransport`, `TagModel`) so tests can supply a fake. See `Tests/NookCoreTests/Support/TestSupport.swift`.
- The MCP server (`NookCore/MCP`) stays read-only toward Gmail. New tools may read the local store or open something in Nook for a person to confirm, but must never send, delete or change mail on their own.

## Tests

We use [Swift Testing](https://developer.apple.com/documentation/testing). Please:

- Add a test for every bug fix that would have caught the bug.
- Prefer behavior-level tests (for example, "an incremental sync applies a deletion") over tests of private helpers.
- Keep tests hermetic: use `Database(path: ":memory:")`, `FakeGmail` and `StubTransport`, never the network.

## Style

- Follow the existing code: Swift API Design Guidelines, four-space indentation, `// MARK:` sections in larger types.
- Comments explain *why*, not *what*.
- UI: use `Theme` colors and the existing components (`TagPill`, `KeyCap`, `IconButton`) before adding new ones. Check light and dark mode (`--demo --dark`).

## Pull requests

- Keep each PR focused on one change. Include screenshots for UI changes (demo mode makes this easy).
- Describe what changed and how you tested it.
- Changes that touch privacy (network, storage, rendering of untrusted HTML) get extra review. Call them out in the description.

## Reporting security issues

Please don't open a public issue for security problems, such as ways to leak data from a rendered email or bypass remote-content blocking. Contact the maintainers privately and we'll respond quickly.
