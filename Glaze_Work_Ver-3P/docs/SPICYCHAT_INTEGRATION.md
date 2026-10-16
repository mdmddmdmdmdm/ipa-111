# SpicyChat integration

This revision adds SpicyChat as a first-class catalog provider without replacing the existing catalog UI.

## Implemented

- Public SpicyChat catalog through the current Typesense public-character collection.
- Current application configuration is fetched at runtime so the public search key can rotate without rebuilding the app.
- Trending, Popular, Latest, Search and tag filters.
- NSFW discovery is account-gated in the app and uses the SpicyChat `NSFW` tag for public filtering.
- Character avatar URLs are normalized to `cdn.nd-api.com`, with a SpicyChat referer on card image requests.
- Full character details use SpicyChat's public character endpoint.
- SpicyChat account sign-in uses the site's own WebView flow; Glaze does not collect the password or one-time code.
- For You uses the authenticated SpicyChat Recommendations page through the shared WebView session.
- Recent uses the authenticated SpicyChat Chats page through the same session.
- The existing provider/settings UI is retained; only the necessary SpicyChat account and NSFW settings were added.

## Build

The project still requires Apple's Xcode toolchain to create an iOS `.app`/`.ipa`. This environment cannot run Xcode, so the source revision must be built on a Mac/cloud Mac (for example, Codemagic) before installation on an iPhone.

## Cross-provider discovery and favorites

- The provider picker now has an **All Providers** mode when at least two catalog sources are enabled.
- Combined discovery supports Trending, Popular, Newest, and account-aware Recommended/Recent feeds where a provider exposes them.
- Combined cards keep each source's original engagement numbers and show a source badge so rows are never presented as if their provider metrics were directly interchangeable.
- The existing Favorites collection can now show local Glaze favorites together with supported remote account favorites. Chub and SpicyChat are currently wired into the remote favorites view; providers without a stable favorites API are not represented as fake empty data.
- Favorite rows can be filtered by source (All, Glaze, Chub, or SpicyChat) while retaining the existing library favorite behavior.


### Auth sheet behavior

The provider login sheets keep their own Back navigation separate from Close. Signup/onboarding routes are never treated as a completed login, so a provider sheet remains open until the provider reports a fully established session or the user explicitly closes it.
