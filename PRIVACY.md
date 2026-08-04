# Privacy

Last updated: August 4, 2026

Lychee is a macOS menu-bar app. It has no user accounts and does not operate its own lyrics, artwork, or analytics server.

## Usage Analytics

Lychee sends minimal usage analytics to [PostHog](https://posthog.com). Analytics are enabled by default and can be disabled at any time in **Settings > About > Usage Analytics**.

The analytics payload is restricted in source code to:

- A SHA-256 hash of a randomly generated installation identifier
- App version and build number
- A one-time installation activation event
- At most one active-use event per UTC day
- A one-time first-lyrics-success event
- Daily aggregate counts of synced, plain, and missing lyrics results
- Daily aggregate counts grouped into four broad time-to-result buckets

Lychee does not include song titles, artist names, album names, lyrics, search queries, playback history, exact lookup durations, account information, hardware details, locale, precise location, or advertising identifiers in analytics events.

The un-hashed random installation identifier is generated locally. It is not derived from a device serial number, Apple ID, email address, or music account. Debug builds made through Xcode do not transmit analytics.

Disabling analytics cancels the current analytics request, deletes queued unsent events and local daily counters, and prevents future events. It does not delete events that have already reached PostHog. The random identifier remains in local preferences so re-enabling analytics does not create a second installation identity.

Like any internet service, PostHog receives network-level request information such as an IP address while processing a request. Lychee does not add an IP address or location field to the analytics payload. Lychee sends events without creating PostHog person profiles. PostHog's handling of request data is governed by its own privacy policy.

## Lyrics Requests

Lychee sends track metadata to [LRCLIB](https://lrclib.net) to find lyrics. Depending on the lookup, this can include:

- Track title
- Artist name
- Album name
- Track duration

LRCLIB receives this information only when Lychee needs to find or refresh lyrics. Its handling of requests is governed by LRCLIB's own policies.

## Album Artwork

For Apple Music tracks, Lychee may send the track title and artist name to Apple's iTunes Search API to find album artwork. Apple handles those requests under its own privacy terms.

## Spotify And Apple Music

Lychee communicates with the Spotify and Apple Music desktop apps locally through macOS automation. Lychee does not receive music-account passwords or authentication tokens.

## Updates And Downloads

Lychee uses Sparkle to check a GitHub-hosted appcast and download updates from GitHub Releases. GitHub receives normal request information when those resources are accessed. GitHub also publishes aggregate download counts for release assets.

## Feedback And Support

The **Send Feedback** and **Support with PayPal** buttons open Tally and PayPal respectively. No information is sent to either service unless the user chooses to open and use those services.

## Data Stored On The Mac

Lychee stores preferences, its random analytics identifier, and temporary analytics counters in macOS user defaults. Cached lyrics are stored under `~/Library/Application Support/Lychee/lyrics` and can be cleared from Settings.

Lychee does not include crash reporting or keystroke tracking.

## Questions

Privacy questions can be opened in the repository's issue tracker. Do not include private account information, song history, or other sensitive data in a public issue.
