# SmartTube

A native Swift/SwiftUI YouTube client for **iPhone**, **iPad**, **macOS**, and **Apple TV**.  
Zero ads. SponsorBlock auto-skip. DeArrow community titles. Google sign-in. Up to 8K.

[![Download on the App Store](https://developer.apple.com/assets/elements/badges/download-on-the-app-store.svg)](https://apps.apple.com/us/app/smart-tube-bdp/id6761388918) [![Support on Ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/milikadelic)

Inspired by the original [SmartTube Android app](https://github.com/yuliskov/SmartTube).

---

## Screenshots

<table>
  <tr>
    <td><img src="docs/screenshots/home.png" width="160"/></td>
    <td><img src="docs/screenshots/subscriptions.png" width="160"/></td>
    <td><img src="docs/screenshots/player.png" width="160"/></td>
    <td><img src="docs/screenshots/player-menu.png" width="160"/></td>
    <td><img src="docs/screenshots/settings.png" width="160"/></td>
  </tr>
</table>

---

## Features

- Home, Subscriptions, History, Search, and Playlists feeds
- Video playback via AVPlayer — adaptive HLS/DASH, up to 8K
- SponsorBlock integration — auto-skip with per-category controls
- DeArrow community titles and thumbnails
- Google OAuth sign-in (YouTube TV device authorization flow)
- Video downloads with live activity progress
- Share Extension — share YouTube links from any app
- Picture-in-Picture
- Shorts support
- Comments
- Settings: quality, playback speed, theme, seek duration, SponsorBlock categories
- No ads, no tracking

---

## Project Structure

```
SmartTubeIOS/          Swift Package — core library (models, InnerTube API, SponsorBlock, views)
SmartTubeApp/          Xcode project — app targets (iOS/iPadOS/macOS + Apple TV)
SmartTube.xcworkspace/ Xcode workspace (references both above)
```

---

## Requirements

| Platform | Minimum |
|---|---|
| iOS / iPadOS | 17.0 |
| macOS | 14.0 (Sonoma) |
| tvOS | 17.0 |
| Xcode | 16.0 |
| Swift | 6.0 |

---

## Getting Started

```bash
git clone https://github.com/milika/SmartTubeIOS
cd SmartTubeIOS
open SmartTube.xcworkspace
```

### Signing

The project requires an Apple Developer Team ID and a Firebase `GoogleService-Info.plist` to build.  
Copy `SmartTubeApp/Config/Secrets.xcconfig.example` to `SmartTubeApp/Config/Secrets.xcconfig` and fill in your Team ID:

```
DEVELOPMENT_TEAM = YOUR_TEAM_ID
SMARTTUBE_TV_TEAM = YOUR_TEAM_ID
```

Add your own `GoogleService-Info.plist` to `SmartTubeApp/SmartTubeApp/` (create a free Firebase project at [console.firebase.google.com](https://console.firebase.google.com) — only Analytics and Crashlytics are used).  
Both files are gitignored and will never be committed.

---

## Contributing

Pull requests are welcome. See [.github/PULL_REQUEST_TEMPLATE.md](.github/PULL_REQUEST_TEMPLATE.md) for the checklist.  
Please ensure `Secrets.xcconfig` and `GoogleService-Info.plist` are **never** included in a PR.

---

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for a full version history.

---

## License

[GPL-3.0](LICENSE)
