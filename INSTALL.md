# Installing Haptic Tiles

You do **not** need Xcode, a developer account, or a jailbreak. All you need is
the `.ipa` from the [Releases](https://github.com/Ednk-1312/haptic-tiles-ios/releases)
page and one of the free tools below.

> The published `.ipa` is unsigned. iOS blocks unsigned apps, so a sideloading
> tool must sign it with **your own** Apple ID before installing. All three
> methods below do this for you in one step.

## Option 1 — AltStore / SideStore (recommended)

1. Install **AltServer** on your Mac or Windows PC from [altstore.io](https://altstore.io).
2. Connect your iPhone over Wi-Fi or cable and install the AltStore app on it.
3. Download `HapticTiles-unsigned.ipa` from the Releases page.
4. In AltStore on your iPhone, tap **+**, pick the `.ipa`, and sign in with your Apple ID.

Notes for free Apple IDs: apps must be re-signed ("refreshed") every **7 days**
(AltStore does this automatically while AltServer runs), and iOS caps free
accounts at 3 sideloaded apps.

## Option 2 — Sideloadly

1. Install [Sideloadly](https://sideloadly.io) (Windows or macOS).
2. Plug your iPhone in and trust the computer.
3. Drag `HapticTiles-unsigned.ipa` into Sideloadly.
4. Enter your Apple ID and click **Start**.

## Option 3 — TrollStore (rare)

TrollStore installs apps permanently **without** re-signing, but only on
specific iOS versions that still have the required exploit. If your iPhone is
on a recent iOS release (including iOS 26), TrollStore is almost certainly
**not available** — use AltStore or Sideloadly instead. Check the
[TrollStore compatibility list](https://github.com/opa334/TrollStore#trollstore)
before trying.

## Requirements

- iPhone running **iOS 26 or later**
- The `.ipa` from the latest release (~5.5 MB)

## Troubleshooting

- **"Unable to install"** → the profile was revoked or expired; re-sign and reinstall.
- **App quits on launch after 7 days** (AltStore free account) → open AltStore and refresh.
- **Music library is empty** → grant Media & Apple Music access in Settings → Haptic Piano.
