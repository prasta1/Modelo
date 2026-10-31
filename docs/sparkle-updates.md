# Sparkle updates

Modelo uses Sparkle 2.10.1 for update checks and installation. The app menu has
**Check for Updates…**. Background checks require consent; each install requires
a click. The updater does not start under XCTest. Release builds ignore the
Debug feed override. Homebrew distribution is not part of this change.

## Release setup

The public key is in `project.yml`. Its private key is stored in the macOS
Keychain under the account `prasta1.Modelo.Sparkle` and in the repository secret
`SPARKLE_ED_PRIVATE_KEY`. The key was created for this integration, not borrowed
from another app.

These steps are for the release maintainer on the Mac that holds the key. Other
contributors do not need the private key to build the app or run unit tests.

Resolve packages to the same path used by the release workflow:

```bash
xcodegen generate
xcodebuild -resolvePackageDependencies -project Modelo.xcodeproj -scheme Modelo \
  -clonedSourcePackagesDirPath build-release/spm
```

Back up the key in the repository owner's password manager before the first
release. First export it to a private temporary directory:

```bash
umask 077
KEY_DIR=$(mktemp -d)
TOOLS=build-release/spm/artifacts/sparkle/Sparkle/bin
"$TOOLS/generate_keys" --account prasta1.Modelo.Sparkle -x "$KEY_DIR/sparkle.key"
```

Import `$KEY_DIR/sparkle.key` into the password manager and confirm the backup.
Then, in the same shell, set or restore the repository secret if needed and
remove the temporary export:

```bash
gh secret set SPARKLE_ED_PRIVATE_KEY --repo prasta1/Modelo < "$KEY_DIR/sparkle.key"
rm -rf "$KEY_DIR"
```

Do not print the private key or commit it. To read the public key again, run
`generate_keys --account prasta1.Modelo.Sparkle -p`.

Archive verification is required before extraction. With zip updates, loss of
the private key can require a manual reinstall. Do not replace the public key
without a key-rotation plan; see [Sparkle security](https://sparkle-project.org/documentation/#rotating-signing-keys).

For each release:

1. Increase `MARKETING_VERSION` and the integer `CURRENT_PROJECT_VERSION`.
2. Merge the reviewed change and push the matching version tag.
3. Confirm that the release has both the app zip and `appcast.xml`, and that the
   latest-feed URL below returns the new build number.
4. For the first Sparkle release, tell users to download it manually. Test the
   official app's launch and saved-key access; a local development build does
   not prove these work in the notarized release.

The existing Developer ID export and notarization remain in place. The workflow
checks the nested signatures, embedded profile, and keychain entitlements.
Sparkle's pinned `generate_appcast` tool signs the final zip and embeds Markdown
release notes. The workflow verifies the signature before publishing.

The feed URL is
`https://github.com/prasta1/Modelo/releases/latest/download/appcast.xml`.
Each release contains one update, with no deltas. The build-number guard allows
a missing feed (HTTP 404) for the first Sparkle release, but fails on network
errors, malformed feeds, and repeated or decreasing build numbers.

## Local checks

```bash
python3 -m unittest discover -s scripts -p 'test_*.py'
xcodegen generate
xcodebuild -project Modelo.xcodeproj -scheme Modelo \
  -destination 'platform=macOS' -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO test
```

For an install/relaunch test, use two **signed Debug** copies outside
`/Applications`, with build numbers such as 1000 and 1001. Keep the same bundle
ID, public key, and signing identity. Do not use the real installed copy as the
test target. Quit it first and back up `~/Library/Application Support/Modelo`;
test copies still use that data path.

1. Build with `CURRENT_PROJECT_VERSION=1000` and copy the app to a test folder.
2. Build 1001, then zip it with `ditto -c -k --keepParent`.
3. Put only that zip and optional matching `.md` notes in a feed folder.
4. Run `generate_appcast --account prasta1.Modelo.Sparkle --maximum-deltas 0`
   with `--embed-release-notes` and
   `--download-url-prefix http://127.0.0.1:8765/`, followed by the feed folder.
5. Serve that folder with `python3 -m http.server 8765 --bind 127.0.0.1`.
6. Launch the 1000 copy with `open -n <path>/Modelo.app --args`
   `-ModeloDebugFeedURL http://127.0.0.1:8765/appcast.xml`
   `-SUEnableAutomaticChecks NO`. These launch arguments do not persist.
7. Choose **Check for Updates…**, install, and confirm that the test copy
   restarts at build 1001.
8. Repeat from 1000 with one byte changed in the served zip, leaving the feed
   unchanged. Installation must fail and the old app must remain intact.
9. Stop the server, close the test app, and reopen the real installed copy.

Also check saved-key access across an update using the same official identity.
A personal-team build and the official release have different keychain access
groups; a first manual switch can require API keys to be entered again.

The local test does not prove Developer ID export or notarization. Validate the
first official release and an official-build-to-official-build update before
calling the release path fully tested.

## Troubleshooting

- **No Check for Updates… menu item:** the installed version predates Sparkle.
  Download a release that includes it once.
- **Feed not found:** before the first Sparkle release is published, the public
  feed does not exist. Use a local Debug feed for development checks.
- **No newer update offered:** check `CFBundleVersion` in the installed app and
  `sparkle:version` in the feed. The feed's number must be greater. Also check
  the update's minimum macOS version.
- **Signature validation fails:** do not disable verification. Confirm that CI
  uses the private key paired with `SUPublicEDKey`, and that the uploaded zip is
  the exact file signed after notarization and stapling.
- **Keys are unavailable after switching builds:** personal and official signing
  identities have different keychain access groups. Enter the API keys again
  when moving to the official release.
- **A development build stops launching:** its provisioning profile may have
  expired. Rebuild with `scripts/install.sh`, or use an official release. The
  updater cannot renew a development profile.

## References

- [Sparkle setup](https://sparkle-project.org/documentation/)
- [SwiftUI integration](https://sparkle-project.org/documentation/programmatic-setup/)
- [Update policy and signature settings](https://sparkle-project.org/documentation/customization/)
