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

- **Project:** `Modelo2.xcodeproj` · **Scheme:** `Modelo2` · **Product:** `ModeloDos.app`
  (Swift module is named `Modelo`, so tests `@testable import Modelo`).
- **Tooling:** `xcodegen` (Homebrew) + `xcodebuild` (Xcode 26+). Deps (MarkdownUI,
  Highlightr) resolve via SPM on first build.

```bash
# Regenerate the project from project.yml (run after editing project.yml or adding files)
xcodegen generate
```

**Validate a change compiles** (CI-style; no signing needed, output to gitignored `build/`):

```bash
xcodebuild -project Modelo2.xcodeproj -scheme Modelo2 -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO build
```

A green build ends in `** BUILD SUCCEEDED **`. Treat any `error:` line as a hard
failure — a text/grep "verification" that only checks for the presence of strings
(e.g. `verify_implementation.py`) does **not** prove the code compiles and must not
be trusted as validation.

**Run the test suite** (`ModeloTests`, in-memory SwiftData):

```bash
xcodebuild -project Modelo2.xcodeproj -scheme Modelo2 \
  -destination 'platform=macOS' -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO test
```

**Build a signed Release and install to /Applications.** `project.yml` pins
`DEVELOPMENT_TEAM` to `WXQ53X7LZ7`, which does *not* match the dev certificate on
this machine, so automatic signing fails from the CLI (`No signing certificate
"Mac Development" found`). Sign manually against the local "Apple Development"
identity instead — a non-sandboxed Mac app needs no provisioning profile. The
snippet below finds the identity's SHA-1 and builds + installs with it:

```bash
xcodegen generate   # only needed if files were added/removed
# Resolve the local code-signing identity (see all with: security find-identity -v -p codesigning)
SIGN_ID=$(security find-identity -v -p codesigning | awk '/Apple Development/{print $2; exit}')
xcodebuild -project Modelo2.xcodeproj -scheme Modelo2 -configuration Release \
  -destination 'platform=macOS' -derivedDataPath build-release build \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$SIGN_ID" PROVISIONING_PROFILE_SPECIFIER=""
osascript -e 'tell application "ModeloDos" to quit' 2>/dev/null   # free the running copy
rm -rf /Applications/ModeloDos.app
cp -R build-release/Build/Products/Release/ModeloDos.app /Applications/
open /Applications/ModeloDos.app
```

The installed app is `/Applications/ModeloDos.app`; `codesign --verify --verbose
/Applications/ModeloDos.app` should report it valid. Keep `build/` and
`build-release/` gitignored. The keychain must be unlocked, so run this in an
interactive shell (the `!` prefix in Claude Code works).
