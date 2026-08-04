# Security Policy

## Supported Versions

Security fixes are provided for the latest published version of Lychee.

## Report A Vulnerability

Do not open a public issue for a suspected vulnerability.

Use GitHub's private vulnerability reporting:

[Report a vulnerability privately](https://github.com/rishabhbs/Lychee-Lyrics-in-MenuBar/security/advisories/new)

Include:

- The affected Lychee version
- Reproduction steps or a proof of concept
- The expected impact
- Any suggested mitigation

Do not include real account credentials, private music history, or unnecessary personal data. You will receive an acknowledgement after the report is reviewed. Please allow time for a fix before publishing details.

## Unsigned Distribution

Lychee is currently distributed without an Apple Developer ID or notarization. Published builds are ad-hoc signed and macOS requires users to approve the first launch manually in Privacy & Security settings.

Hardened Runtime remains enabled. The unsigned build disables library validation because an ad-hoc-signed host has no Apple Team ID and otherwise cannot load Sparkle's embedded framework. Release preparation verifies the complete app bundle and Sparkle components with `codesign`, and every update archive is independently signed with Sparkle EdDSA. The private EdDSA key is stored outside the repository in the maintainer's macOS Keychain.
