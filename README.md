# Watcher

A native iPhone and iPad app for your Stremio account.

- **Sign in with Stremio.** Use your email and password, or a code if your account uses Apple or Facebook.
- **Home.** A featured title, your Continue Watching row, and catalog rows from your addons, each with a See All grid and genre filters.
- **Search.** Searches every addon that supports it.
- **Library.** Your saved titles, filterable by Movies or Series. Tap + on any title to save it.
- **Details.** Season tabs and an episode list, plus a Play or Resume button that remembers your episode.
- **Streams.** Grouped by addon, with quality badges (4K, Dolby Vision, HDR, HEVC, Atmos, size), a ⚡ mark on cached debrid results, and a "Play Best Match" button.
- **Two built-in players.** The app picks one automatically:
  - **Apple's player** for MP4/MOV/HLS. You get AirPlay to the Apple TV, Picture in Picture, and native controls.
  - **mpv** for MKV, AVI, WebM, DTS/TrueHD audio, and anything Apple's player can't open. It has audio and subtitle track menus, addon subtitles, playback speed, and double-tap to skip.

  If Apple's player can't open a file, mpv takes over at the same spot. To force one player, long-press a stream, or change the default in Settings.
- **Progress syncs to Stremio.** Continue Watching stays in step with your other devices, using Stremio's own rules: 70% counts as watched, and finishing an episode moves Continue Watching on to the next one.
- **Play a File.** On the Library tab, opens any video from the Files app.
- **Built for both devices.** A sidebar and two-column layouts on iPad, a tab bar on iPhone.

Torrent-only streams (no debrid) can't play in the app. Debrid streams, like your TorBox setup, play normally.

---

## Install without a Mac: GitHub builds it, AltStore or SideStore installs it

iPhones only install signed apps, so this takes two parts. **GitHub** compiles the app for free on one of its Macs. **AltStore** or **SideStore** then installs it with your Apple ID and keeps it updated from a link.

### 1. Set up the GitHub build (about 5 minutes, works from Safari on your iPhone)

1. Sign in at github.com (create a free account if you need one).
2. Tap **+ → New repository**. Name it `matinee`, choose **Public**, and tap **Create repository**.
3. Tap **uploading an existing file** (or **Add file → Upload files**) and upload **Matinee.zip** from the Files app. Commit it.
   If the upload option doesn't appear, tap **aA → Request Desktop Website** in Safari.
4. Tap **Add file → Create new file**. Name it exactly `.github/workflows/build.yml`, paste in the contents of `build.yml`, and commit it.
5. Open the **Actions** tab. The build takes about 15 minutes.
6. When it's green, its Summary shows your install link:
   `https://github.com/YOUR-USERNAME/matinee/releases/latest/download/source.json`

**If the build fails:** open the failed run. Its Summary lists the error lines. Send those lines to Claude and you'll get fixed files back. To update the app, upload a new Matinee.zip; GitHub rebuilds automatically.

**Why the repo is public:** AltStore has to download the app without a GitHub login, and GitHub's Mac builds are free for public repos. Nothing private is in the project, because you sign in to Stremio inside the app.

### 2. Install on your iPhone and iPad

AltStore or SideStore has to be on each device first. That first setup needs a computer one time, per their guides (altstore.io / sidestore.io).

1. In AltStore, go to **Browse → Sources → +**. In SideStore, go to **Sources → +**. Paste the link from step 1.6.
2. Open **Matinee** and tap **Free** or **Install**.
3. Every new GitHub build shows up as an update.

With a free Apple ID, sideloaded apps need refreshing every 7 days. AltStore and SideStore do this in the background.

---

## Build on a Mac instead

You need Xcode 16 or newer.

```bash
bash build-ipa.sh       # installs XcodeGen via Homebrew if needed, writes Matinee.ipa
```

Install `Matinee.ipa` with AltServer (**menu-bar icon → Sideload .ipa…**), or AirDrop it to your device and add it in AltStore.

To run it straight from Xcode: run `xcodegen generate`, open `Matinee.xcodeproj`, pick your Personal Team under **Signing & Capabilities**, choose your device, and press **Run**. If Xcode says `com.daniel.matinee` is taken, change it.

---

## Project layout

| Folder | What's in it |
|---|---|
| `Matinee/Stremio` | Stremio account API, addon protocol, library entries and progress rules, stream quality parsing |
| `Matinee/Views` | Home, Search, Library, details, stream picker, sign-in, settings |
| `Matinee/Player` | Apple player, the mpv player (via MPVKit), progress tracking |
| `project.yml` | XcodeGen spec (iOS 18+, iPhone + iPad, MPVKit 1.1.0) |
| `ci/` | Build and publish scripts used by the GitHub workflow |

The API calls, addon URLs and progress rules follow Stremio's open-source core (`stremio-core`).
