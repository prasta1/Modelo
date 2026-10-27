# Homebrew Tap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `brew install --cask prasta1/modelo/modelo` installs the notarized release, and every tag push bumps the cask automatically.

**Architecture:** A new public tap repo `prasta1/homebrew-modelo` holds one cask that downloads the existing GitHub release zip. A final `release.yml` step checks out the tap with a scoped token, rewrites `version` + `sha256`, and pushes.

**Tech Stack:** Homebrew cask DSL (Ruby), GitHub Actions, `gh`.

**Spec:** `docs/superpowers/specs/2026-10-27-homebrew-sparkle-design.md` (Part 1)

## Global Constraints

- Tap repo: `prasta1/homebrew-modelo`, **public**, cask at `Casks/modelo.rb`. Install command: `brew install --cask prasta1/modelo/modelo`.
- Download URL: `https://github.com/prasta1/Modelo/releases/download/v#{version}/Modelo-v#{version}.zip`.
- `depends_on macos: ">= :sonoma"` (deployment target 14.0). Universal binary: no `arch` stanza.
- No `auto_updates` line until the first Sparkle release (Sparkle plan, Task 4).
- New secret `TAP_TOKEN`: fine-grained PAT, **only** `prasta1/homebrew-modelo`, Contents: Read and write. Not `GITHUB_TOKEN`, which can't push cross-repo.
- No manual release steps: the tag push does the bump.
- `gh` write operations always pass `--repo` explicitly (user rule).

## Review Focus

1. **Bump step runs after a failed publish:** the cask would point at a zip that doesn't exist. The step must come after `Publish release` in the same job, so a failure stops it. Task 2 checks the step order.
2. **Re-run of the same tag:** the cask already has that version and sha, so `git commit` finds nothing to commit and fails the job. Task 2's bump must exit 0 on no change (test in Task 2, Step 2).
3. **`sha256` mismatch:** the cask must hash the exact uploaded asset, not a re-zip. Task 2 uses the same `$ZIP` file passed to `gh release create`.
4. **Existing `/Applications/Modelo.app`:** `brew install` refuses to overwrite it. Task 1's verification asks the user before `--force`.
5. **`zap` deletes too much:** `zap` paths must be Modelo's own (bundle ID / app name), never shared folders. Task 1 lists them exactly.

---

### Task 1: Create the tap with a v0.3.1 cask

**Files:**
- Create (in new repo `prasta1/homebrew-modelo`): `Casks/modelo.rb`, `README.md`
- Modify (Modelo repo): `README.md` (Install section)

**Interfaces:**
- Produces: `Casks/modelo.rb` with exactly one `version "X.Y.Z"` line and one `sha256 "<64 hex>"` line. Task 2's bump rewrites these two lines by regex.

- [ ] **Step 1: Ask the user before creating the public repo**, then:
  ```bash
  gh repo create prasta1/homebrew-modelo --public \
    --description "Homebrew tap for Modelo — brew install --cask prasta1/modelo/modelo"
  ```
  Clone it to the scratchpad. This repo has no local folder under `~/Projects` by design.

- [ ] **Step 2: Write `Casks/modelo.rb`**
  - `version "0.3.1"`
  - `sha256 "152041bbec2a75e50d637282047842df53f4f880387f701d617bf1f0e559bb92"` (GitHub's recorded digest for `Modelo-v0.3.1.zip`)
  - `url` per Global Constraints, plus `verified: "github.com/prasta1/Modelo/"`
  - `name "Modelo"`
  - `desc "Native macOS client for local and cloud LLM inference"`
  - `homepage "https://github.com/prasta1/Modelo"`
  - `livecheck do url :url; strategy :github_latest end`
  - `depends_on macos: ">= :sonoma"`
  - `app "Modelo.app"`
  - `zap trash:` with exactly these paths:
    - `~/Library/Application Support/Modelo`
    - `~/Library/Application Support/ModeloDos`
    - `~/Library/Caches/com.peregrine.modelo`
    - `~/Library/HTTPStorages/com.peregrine.modelo`
    - `~/Library/Preferences/com.peregrine.modelo.plist`
    - `~/Library/Saved Application State/com.peregrine.modelo.savedState`

- [ ] **Step 3: Lint**
  Run: `brew style --fix Casks/modelo.rb && brew audit --cask --strict --online prasta1/modelo/modelo` (after `brew tap prasta1/modelo <clone path>`)
  Expected: no offenses, no audit errors.

- [ ] **Step 4: Commit and push the tap.** Also add a short `README.md` with the install command.

- [ ] **Step 5: Install from the tap**
  `/Applications/Modelo.app` already exists on the dev Mac. Ask the user before running with `--force`, which replaces their install with the v0.3.1 release build.
  Run: `brew untap prasta1/modelo; brew install --cask prasta1/modelo/modelo` (with `--force` if approved)
  Expected:
  - `spctl -a -vvv -t exec /Applications/Modelo.app` → `accepted`, `source=Notarized Developer ID`.
  - Modelo launches, and saved API keys load with no keychain password prompt.

- [ ] **Step 6: Add brew to the Modelo README.** In the **Install** section, add after the download sentence: "Or with Homebrew: `brew install --cask prasta1/modelo/modelo` (update with `brew upgrade`)."
  Commit in the Modelo repo on `feature/homebrew-tap`.

### Task 2: Bump the cask on every release

**Files:**
- Create: `scripts/bump-cask.sh`
- Modify: `.github/workflows/release.yml` (new final step before `Clean up keychain`)
- Modify: `AGENTS.md` (Releasing: add `TAP_TOKEN` row to the secrets table)

**Interfaces:**
- Consumes: Task 1's two-line cask format.
- Produces: `scripts/bump-cask.sh <cask-path> <version> <sha256>`, which rewrites the two lines in place and exits non-zero if either line isn't found exactly once.

- [ ] **Step 1: Walk the user through creating `TAP_TOKEN`.** Give click-by-click steps:
  - GitHub → Settings → Developer settings → Fine-grained tokens.
  - Repository access: only `prasta1/homebrew-modelo`. Contents: Read and write. Expiry: 1 year.
  - Store it with `gh secret set TAP_TOKEN --repo prasta1/Modelo`.
  - Note the expiry date in their password manager.

- [ ] **Step 2: Write the check first**, `scripts/bump-cask.sh` self-test as a shell snippet run in a temp dir:
  - Copy `Casks/modelo.rb`, then run `bump-cask.sh` with `0.9.9` and `aaaa…` (64 × `a`).
    - Assert `grep -c 'version "0.9.9"'` = 1.
    - Assert `grep -c 'sha256 "aaaa…"'` = 1.
    - Assert the file is otherwise unchanged (`diff` shows exactly 2 changed lines).
  - Run it on a file with no `version` line → assert non-zero exit.
  - Run it twice with the same args → assert the second run leaves the file byte-identical (no-change case from Review Focus 2).

- [ ] **Step 3: Implement `scripts/bump-cask.sh`** with `sed -E -i ''` on macOS. Guard with `grep -c` = 1 for each pattern before editing.

- [ ] **Step 4: Run the Step 2 check** → all assertions pass.

- [ ] **Step 5: Add the workflow step** after `Publish release`:
  - `actions/checkout@v5` with `repository: prasta1/homebrew-modelo`, `token: ${{ secrets.TAP_TOKEN }}`, `path: tap`.
  - Run `scripts/bump-cask.sh tap/Casks/modelo.rb "${GITHUB_REF_NAME#v}" "$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"`, where `ZIP="Modelo-$GITHUB_REF_NAME.zip"` is the same file uploaded.
  - In `tap/`, commit as `github-actions[bot]` (`41898282+github-actions[bot]@users.noreply.github.com`), message `modelo ${GITHUB_REF_NAME#v}`.
  - Skip the commit when `git diff --quiet` (no change). Then push.

- [ ] **Step 6: Verify the YAML parses and the step order** with `ruby -ryaml`: print the step names and confirm the bump step sits after `Publish release` and before `Clean up keychain`.

- [ ] **Step 7: Add `TAP_TOKEN` to the AGENTS.md secrets table.** Commit all of Task 2, push `feature/homebrew-tap`, and open the PR with `--repo prasta1/Modelo`.

- [ ] **Step 8 (after merge, at the next real release):** confirm the tap gets a `modelo X.Y.Z` commit, and that `brew upgrade --cask modelo` moves to the new version.
