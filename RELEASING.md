# Releasing Ghostype

Every push to `main` ships. The **Build and Release** workflow
(`.github/workflows/build-and-release.yml`) builds the production `Ghostype`
scheme in Release, ad-hoc signs it, zips the app, signs the archive with the
project's Sparkle EdDSA key, and publishes `Ghostype.zip` + a fresh
`appcast.xml` to the floating GitHub release tagged `stable`. The app's
`SUFeedURL` points at that release, so "Check for Updates" (menu bar and
Settings → About) picks up each new build, and the daily automatic check does
the same.

Versioning: `MARKETING_VERSION` stays `0.1.0`; `CURRENT_PROJECT_VERSION` is the
GitHub run number, which always increases. Sparkle treats a higher build
number as an update even when the marketing version is unchanged.

No Apple Developer identity is required anywhere in this flow: the build uses
`CODE_SIGN_IDENTITY="-"`, and update integrity comes from the Sparkle EdDSA
signature rather than code signing. The app is therefore ad-hoc signed, not
notarized — on first launch macOS may ask for a right-click → Open
confirmation.

## One-time setup: the Sparkle signing key

Sparkle refuses to install an update whose EdDSA signature does not verify
against the `SUPublicEDKey` baked into the installed app, so the keypair has
to exist before the first publish:

1. On a Mac, get Sparkle's `generate_keys` tool (ships in the
   [Sparkle release tarball](https://github.com/sparkle-project/Sparkle/releases)
   and in the SwiftPM artifact bundle) and run it. It prints a keypair.
2. Paste the **public** key into `GhostypeInfo.plist` as `SUPublicEDKey`,
   replacing the `REPLACE_WITH_GENERATED_SPARKLE_PUBLIC_ED_KEY` placeholder,
   and push. Until the placeholder is gone the app keeps Sparkle disabled and
   the workflow fails fast with instructions instead of burning runner time.
3. Paste the **private** key into the repository secret
   `SPARKLE_ED25519_PRIVATE_KEY` (Settings → Secrets and variables →
   Actions). The workflow writes it to a temporary file, signs the archive,
   and deletes it at the end of the run.

If the keys ever mismatch (e.g. a copy-paste slip), Sparkle safely rejects
the update on the client — nothing unverified is ever installed.

## What the workflow does

1. Fails fast when the signing secret or the plist public key is missing.
2. Runs `scripts/prepare_cotabby_workspace.sh` (pinned, patched
   CotabbyInference), installs XcodeGen, and regenerates `Ghostype.xcodeproj`.
3. Builds `-workspace build/cotabby-dependencies/Ghostype.xcworkspace
   -scheme Ghostype -configuration Release` with ad-hoc signing. The
   workspace (not `-project`) is required so the build uses the pinned local
   CotabbyInference checkout; the `Ghostype` (not `Ghostype Dev`) scheme is
   required because the Dev scheme compiles Sparkle out via `GHOSTYPE_DEV`.
4. Zips `Ghostype.app` → `Ghostype.zip`.
5. Resolves `sign_update` from the just-built DerivedData (guaranteed to match
   the linked Sparkle 2.9.1 framework) and renders `appcast.xml` with
   `scripts/generate_appcast.py --release-tag stable`.
6. Creates or updates the floating `stable` release with both files
   (`--clobber` on re-runs).

To ship a build without pushing to main, run the workflow manually from the
Actions tab (workflow_dispatch).

See [CONTRIBUTING.md](CONTRIBUTING.md) for local builds and evaluations.
Historical CoHamster release notes describe past fork binaries and do not
control Ghostype's release configuration.
