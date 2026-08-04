# Lychee - Lyrics in MenuBar

Lychee is a free, open-source macOS app that shows lyrics for Spotify and Apple Music directly in the menu bar.

[Download the latest release](https://github.com/rishabhbs/Lychee-Lyrics-in-MenuBar/releases/latest)

## Features

- Synced lyrics that follow the current playback position
- Plain lyrics when timestamped lyrics are unavailable
- Spotify and Apple Music playback controls
- Alternative lyrics candidates when the first match is not right
- Configurable theme, text size, menu-bar width, gap style, and inactivity behavior
- Automatic updates through Sparkle

Lyrics are provided by [LRCLIB](https://lrclib.net). Album artwork for Apple Music tracks may be fetched through Apple's iTunes Search API.

## Requirements

- macOS 13 or newer
- Spotify for macOS or Apple Music
- An internet connection for fetching lyrics and updates

Lychee asks macOS for permission to communicate with Spotify and Apple Music. This is required to read the current track and control playback.

## Install

1. Download the DMG from the [latest release](https://github.com/rishabhbs/Lychee-Lyrics-in-MenuBar/releases/latest).
2. Drag Lychee into Applications.
3. Try to open Lychee once. macOS will block the first launch because Lychee is not currently signed or notarized through Apple's paid Developer Program.
4. Open **System Settings > Privacy & Security**, scroll to the Security section, and click **Open Anyway** for Lychee.
5. Confirm **Open**, then follow Lychee's first-run instructions. Future launches work normally.

Only download Lychee from this repository's official Releases page. The source, release archive, and Sparkle update signature are public and auditable, but an unsigned build cannot receive Apple's normal identified-developer approval dialog.

The ZIP attached to each release is used by Sparkle for automatic updates.

## Build From Source

1. Clone this repository.
2. Open `Lychee.xcodeproj` in a current version of Xcode.
3. Select the Lychee scheme and run the app.

Xcode resolves [Sparkle](https://github.com/sparkle-project/Sparkle) through Swift Package Manager. Debug builds do not send analytics.

Debug builds include Lychee's algorithm diagnostics, testing controls, and developer-mode interface. Those tools are excluded from published Release binaries.

## Privacy

Lychee has no account system and does not send song titles, artist names, lyrics, searches, playback history, or device details to its analytics provider. Minimal usage analytics are enabled by default and can be disabled in **Settings > About**.

Functional lyrics and artwork requests necessarily send track information to LRCLIB or Apple's iTunes Search API. Read [PRIVACY.md](PRIVACY.md) for the exact data flows.

## Contributing

Issues, feature suggestions, and pull requests are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) before submitting code. Please report security issues privately as described in [SECURITY.md](SECURITY.md).

## License

Lychee is licensed under the [GNU General Public License v3.0](LICENSE).
