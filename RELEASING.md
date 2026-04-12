# Releasing Tabby

This document explains Tabby's direct-download release flow now that Sparkle is wired into the app.

The important architectural idea is that Tabby has two separate distribution channels:

- `Tabby.app` updates travel through GitHub Releases plus a Sparkle appcast.
- GGUF model updates stay in Tabby's runtime/model layer and are not bundled into app releases.

## One-time Sparkle Setup

Sparkle needs an EdDSA keypair:

- The private key stays in the maintainer's login Keychain.
- The public key is copied into the Xcode build setting `SPARKLE_PUBLIC_ED_KEY`.

Generate the keypair once using Sparkle's `generate_keys` tool after Xcode has resolved the Sparkle package.

Common way to find the tool:

```bash
find ~/Library/Developer/Xcode/DerivedData -path '*SourcePackages/artifacts/*/Sparkle/bin/generate_keys' | head
```

Then run:

```bash
/path/to/generate_keys
```

After generation:

1. Copy the printed public key.
2. Replace `REPLACE_WITH_GENERATED_SPARKLE_PUBLIC_ED_KEY` in `tabby.xcodeproj/project.pbxproj`.
3. Export and back up the private key outside the repository.

Do not commit the private key to the repository.

## Versioning Rules

Sparkle compares the app's bundle version metadata, so both version fields matter:

- `MARKETING_VERSION` is the user-facing version, eg. `1.0.0`
- `CURRENT_PROJECT_VERSION` is the machine-readable build number Sparkle compares, eg. `12`

Every shipped release must increment `CURRENT_PROJECT_VERSION`, even if `MARKETING_VERSION` only changes occasionally.

## Release Steps

1. Bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `tabby.xcodeproj/project.pbxproj`.
2. Build the release app and produce a notarized Developer ID signed `Tabby.dmg`.
3. Create a Git tag named `v<MARKETING_VERSION>`.
4. Create a GitHub Release for that tag.
5. Upload the notarized DMG as `Tabby.dmg`.
6. Generate the Sparkle appcast:

```bash
python3 scripts/generate_appcast.py \
  --release-version 1.0.0 \
  --build-number 12 \
  --archive build/Tabby.dmg \
  --output build/appcast.xml
```

The script calls Sparkle's `sign_update` tool, extracts the enclosure signature and archive size,
and renders a complete `appcast.xml` from `scripts/appcast.template.xml`.

7. Publish only `appcast.xml` to GitHub Pages at:

```text
https://fujacob.github.io/tabby/appcast.xml
```

Recommended Pages setup:

- use a dedicated `gh-pages` branch
- store only the generated `appcast.xml` there
- do not publish DMGs, ZIPs, or large artifacts to Pages

## Debug Update Testing

Tabby keeps the updater hidden from product UI for now, but there is one Debug-only launch argument
for integration testing:

```text
-tabby-check-for-updates-on-launch
```

Use it like this:

1. Install an older Debug build of Tabby.
2. Publish a newer release with a newer `CURRENT_PROJECT_VERSION`, uploaded `Tabby.dmg`, and live appcast.
3. Launch the older build with the debug launch argument above.
4. Sparkle should immediately perform a user-initiated update check.

## Failure Cases to Verify

- If `SUPublicEDKey` is still the placeholder value, Tabby intentionally refuses to start Sparkle.
- If the appcast URL is wrong or the GitHub Release asset is missing, Sparkle should fail cleanly.
- Manual DMG installs from GitHub Releases should always keep working even if the appcast is wrong.
