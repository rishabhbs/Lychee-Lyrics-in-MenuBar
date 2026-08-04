# Contributing

Thanks for helping improve Lychee. Bug reports, focused feature suggestions, and pull requests are welcome.

## Before Starting

- Search existing issues and pull requests for related work.
- Open an issue before starting a large behavior or interface change.
- Keep changes focused. Avoid unrelated formatting or refactoring.
- Never commit signing keys, credentials, exported archives, DMGs, ZIPs, or personal Xcode data.

## Development Setup

1. Fork and clone the repository.
2. Open `Lychee.xcodeproj` in a current version of Xcode.
3. Let Xcode resolve the Sparkle package.
4. Select the Lychee scheme and run a Debug build.

The deployment target is macOS 13. Debug builds do not transmit PostHog analytics.

Debug builds include the algorithm inspector, lyrics-fetch diagnostics, algorithm selector, cache controls, and onboarding test toggle. With Lychee's popover focused, type `letmein` and press Return twice to reveal the developer section. This trigger and the diagnostic interface are compiled out of Release builds.

You can also verify a Debug build from Terminal:

```sh
xcodebuild -project Lychee.xcodeproj -scheme Lychee -configuration Debug build CODE_SIGNING_ALLOWED=NO
```

## Release Preparation

The maintainer script separates local preparation from publication. The current public build is ad-hoc signed because Lychee is not enrolled in Apple's paid Developer Program:

```sh
./release.sh prepare 1.2.0 --unsigned
```

Preparation builds a universal Release app, verifies its entitlements and embedded Sparkle components, creates the ZIP and DMGs, signs the update archive with Sparkle EdDSA, and writes an ignored candidate feed such as `releases/appcast-1.2.0.xml`. It does not publish anything or modify the live `appcast.xml`.

After testing the packaged app, publish the download assets first:

```sh
./release.sh publish-assets 1.2.0
```

This makes the release downloadable but does not announce an automatic update. Review the candidate feed, merge it into `main` as `appcast.xml`, and then update the feeds used by older installations:

```sh
./release.sh sync-legacy-feeds 1.2.0
```

The order is intentional: release assets must exist before any appcast advertises them. Merging `appcast.xml` is the explicit approval point that announces the update to installations using the main feed.

The Sparkle private key stays in the maintainer's macOS Keychain. Never export or commit it.

Unsigned builds use `LycheeUnsigned.entitlements`, which disables library validation so the ad-hoc-signed Lychee process can load Sparkle's separately signed framework. Hardened Runtime remains enabled. A future Developer ID build must use `Lychee.entitlements`, which does not contain that exception.

## Pull Requests

- Explain the user-visible problem and the chosen solution.
- Include clear testing steps.
- Add screenshots for interface changes.
- Test both Spotify and Apple Music when changing playback behavior.
- Do not add analytics events or fields without updating the in-app disclosure and `PRIVACY.md`.
- Do not send song, artist, album, lyrics, search, account, locale, location, or device data to analytics.

Pull requests require maintainer review before merging. Passing checks do not guarantee acceptance; changes must also fit Lychee's scope and product direction.

## Reporting Bugs

Use the bug-report issue form and include the Lychee version, macOS version, music source, reproduction steps, and expected behavior. Remove song names, account details, and other private information from logs before attaching them.

Security vulnerabilities must be reported privately according to [SECURITY.md](SECURITY.md).

## License

By contributing, you agree that your contribution will be licensed under the GNU General Public License v3.0.
