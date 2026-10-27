# AGENTS.md

## Feature work

Reviewability is the constraint. A diff over ~1500 lines means decompose, not polish.

1. First pass: attempt the whole feature loosely; expect a rough, oversized cut.
2. Under ~1500 lines → clean up and merge. Over → stop, propose an atomic, incremental, independently-reviewable decomposition before writing more.
3. Define sub-tasks by general capability, not the shape of the throwaway pass. Same ceiling applies to each; recurse.
4. Re-attempt the full feature once foundations exist — it'll come in under threshold.

Pause for human review on UI/API/schema/contract changes and any new architectural invariant.

## Build, test, validate & install

The app is a native macOS SwiftUI target. The Xcode project is **generated** by
XcodeGen from `project.yml` and is never committed (`.gitignore`d), so regenerate
it before building if `project.yml` changed or the project is missing.

- **Project:** `Modelo.xcodeproj` · **Scheme:** `Modelo` · **Product:** `Modelo.app`
  (Swift module is named `Modelo`, so tests `@testable import Modelo`).
- **Tooling:** `xcodegen` (Homebrew) + `xcodebuild` (Xcode 26+). Deps (MarkdownUI,
  Highlightr) resolve via SPM on first build.

```bash
# Regenerate the project from project.yml (run after editing project.yml or adding files)
xcodegen generate
```

**Validate a change compiles** (CI-style; no signing needed, output to gitignored `build/`):

```bash
xcodebuild -project Modelo.xcodeproj -scheme Modelo -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO build
```

A green build ends in `** BUILD SUCCEEDED **`; any `error:` line is a hard
failure. Text/grep checks that only assert strings exist do **not** prove the
code compiles — never accept them as validation.

**Run the test suite** (`ModeloTests`, in-memory SwiftData):

```bash
xcodebuild -project Modelo.xcodeproj -scheme Modelo \
  -destination 'platform=macOS' -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO test
```

Run a single suite with `-only-testing:ModeloTests/<SuiteName>`.

**Build a signed Release and install to /Applications:** `./scripts/install.sh`.
The default team (`QVYZN4MJ67`) is a paid Developer Program team, so its
profiles last years. On a free personal team they expire after 7 days and the
app stops launching with `Launchd job spawn failed` (POSIX 163) — re-run the
script to fix it. It uses
*automatic* signing with the team and bundle ID from `Signing.xcconfig`; on
another Apple team, copy `Developer.xcconfig.example` to `Developer.xcconfig`
and fill in yours.
Never sign with `CODE_SIGN_STYLE=Manual` and no profile: that strips the
`com.apple.application-identifier` entitlement, `KeychainStore` falls back to the
legacy login keychain, and macOS prompts for a password after every install.
Full rationale in `Modelo/Modelo.entitlements`.

Verify the install: `codesign -d --entitlements - /Applications/Modelo.app` must
list `com.apple.application-identifier` and `keychain-access-groups`, and
`Contents/embedded.provisionprofile` must exist — if either is missing, secrets
regress to the prompt-per-install legacy keychain. `codesign --verify --verbose`
should report the app valid. Keep `build/` and `build-release/` gitignored.

The keychain must be unlocked for codesign to use the signing key, so run this
in an interactive shell. If macOS prompts for a password on *codesign*'s behalf,
whitelist Apple's tools for the key once (asks for the login password):

```bash
security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
  ~/Library/Keychains/login.keychain-db
```

## Releasing

`.github/workflows/release.yml` builds a Developer ID-signed, notarized
`Modelo.app` and attaches it to a GitHub release. Bump `MARKETING_VERSION` in
`project.yml`, merge, then push a matching tag (`v0.3.1` ↔ `"0.3.1"`); the job
fails fast if they disagree. Tags pushed before the workflow existed don't run it.

Needs a Developer ID Application certificate on the team (create it in Xcode →
Settings → Accounts → Manage Certificates) and these repo secrets:

| Secret | Value |
|---|---|
| `DEVID_P12` | Developer ID Application cert + key exported as `.p12`, base64 (`base64 -i cert.p12 \| pbcopy`) |
| `DEVID_P12_PASSWORD` | The `.p12` export password |
| `DEVID_PROFILE` | Developer ID provisioning profile named exactly `Modelo Developer ID` (developer portal → Profiles → Developer ID, macOS), base64. Manual export signing uses it — automatic export needs cloud signing, which API keys can't do for Developer ID |
| `ASC_KEY_P8` | App Store Connect Team API key (`.p8`, Admin role), base64 — signs the archive and notarizes |
| `ASC_KEY_ID`, `ASC_ISSUER_ID` | The IDs shown beside that key in App Store Connect → Users & Access → Integrations |
