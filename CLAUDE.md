# CLAUDE.md

This file gives Claude Code the context, constraints, and conventions it must follow when working in this repository. Read it fully before touching any code. Re-read it when starting a new session.

---

## 1. What this project is

**FreeTube iOS** — a native SwiftUI YouTube client that replicates the YouTube mobile app: home feed, search, playback, login, subscriptions, library, history, playlists, comments, likes. Tapping a video plays it immediately by streaming, like the YouTube app. Videos can also be **downloaded on request** as MP4 files, for offline playback and for export to other apps (§10).

**Distribution:** iOS — TestFlight internal, sideload, or personal use. macOS — GitHub releases: a Developer ID signed, notarized DMG built by `scripts/build-mac-release.sh` (§15.13). **Not for public App Store submission** (iOS or Mac). Do not suggest changes that assume App Store distribution.

**Platforms:** iOS 17.0+, and macOS 14+ as a Mac Catalyst build ("Optimize interface for Mac", §15.13). Swift 5.9+, Xcode 15+.

**Bundle identifier:** `app.capyvibe.freetube` (iOS and Mac, team `X5X4TD477G`). It was `com.leshko.freetube` until 2026-11-17, but that ID belongs to another developer account: this team can't register it, and TestFlight and the Developer ID Mac release both need an App ID the team owns (local builds had only been getting by on the team's wildcard profile). Changing the identifier makes a new app — prior installs keep their own Keychain / `UserDefaults` / SwiftData state and the new app starts fresh.

**Internal namespace:** `com.leshko.freetube` stays the reverse-DNS namespace for the `os.Logger` subsystem, the Keychain service and cookie key (`com.leshko.freetube.cookies`), the `UserDefaults` keys (subscriptions / preferences), the download-metadata xattr, and internal `Notification.Name`s. These are plain strings, not tied to signing; keep new ones on the same domain and don't rename the existing ones.

---

## 2. Non-negotiable constraints

These come first. Violating them breaks the project.

1. **No Google Cloud YouTube Data API.** All YouTube interaction goes through `b5i/YouTubeKit` (cookie-based, no API key). Never suggest `GoogleAPIClientForREST`, `YTPlayerView`, IFrame embeds, or `https://www.googleapis.com/youtube/v3/...`.
2. **No `dimitris-c/AudioStreaming`.** It is for raw audio streams (Icecast/Shoutcast). YouTube serves HLS/DASH. Playback uses `AVPlayer` only.
3. **No App Store assumptions.** Do not add capabilities, entitlements, or workarounds aimed at App Store review (e.g. avoiding `WKWebView` cookie reads). Sideload-honest behavior is expected.
4. **No telemetry, analytics, or remote logging by default.** Logs go to `os.Logger` only. Never add SDKs that beacon out. *User-approved exception:* watch-progress sync to the user's own YouTube account (`WatchProgressReporter`, Settings → "Sync watch progress with YouTube", only when signed in) — it talks to YouTube only, like YouTube's own apps do.
5. **Cookies are sensitive.** Always store in Keychain via `KeychainHelper`. Never write them to disk, `UserDefaults`, plist, or logs. Never print cookie values.
6. **Signed stream URLs are sensitive and time-limited.** Never persist them. In memory only (any cache: 30-minute TTL max).
7. **MVVM with service layer is mandatory.** Views do not import `YouTubeKit`. ViewModels do not perform networking directly — they call services in `Core/Networking/`.
8. **SwiftUI only for UI.** No UIKit `UIViewController` subclasses except where bridging is unavoidable (`WKWebView`, `AVPlayerLayer`, `AVRoutePickerView`, `AVPictureInPictureController`). Wrap those in `UIViewControllerRepresentable` / `UIViewRepresentable`.
9. **Swift Concurrency is the default.** Use `async`/`await` and `AsyncSequence`. Use Combine only inside `PlayerStateManager` for `AVPlayer` time observation. Do not introduce RxSwift.
10. **No force unwraps in production code.** Use `guard let`, `if let`, or proper `throw`. Force unwraps allowed only in test fixtures.
11. **`@Observable` is the default for view models, not `ObservableObject`.** Injected through SwiftUI `@Environment(...)`.

---

## 3. Tech stack (locked)

| Layer | Choice |
|---|---|
| UI | SwiftUI (`@Observable`, iOS 17 APIs) |
| Async | Swift Concurrency, `AsyncSequence` |
| Networking (YouTube) | `b5i/YouTubeKit` |
| Stream resolution | `YouTubeKit` `/player` requests with custom client contexts (`VISIONOS`, `TVHTML5_SIMPLY_EMBEDDED_PLAYER`) — see §7 |
| Playback | `AVFoundation` / `AVKit` (`AVQueuePlayer`, `AVPlayerLayer`, `AVPictureInPictureController`, `AVRoutePickerView`) — custom controls, no `AVPlayerViewController` |
| Login web view | `WebKit` (`WKWebView`, `WKHTTPCookieStore` against ephemeral `.nonPersistent()` data store) |
| Images | `Kingfisher` |
| Downloads | `URLSession` (HLS segments) + `kewlbear/FFmpeg-iOS-Lame` and `kewlbear/FFmpeg-iOS-Support` (ffmpeg, used only to repackage a downloaded stream into MP4 — never for playback; iOS only — the Mac build repackages with AVFoundation / AudioToolbox, `AVFoundationMuxer`) |
| Secure storage | `Security` (raw Keychain via `KeychainHelper`) |
| Persistence | `SwiftData` (`@Model`); `UserDefaults` for simple flags via `UserPreferences` |
| Logging | `os.Logger` with subsystem `com.leshko.freetube` |

Adding any other dependency requires an explicit ask in the PR description with justification.

---

## 4. Project structure

```
FreeTube/
├── App/
│   ├── AppEnvironment.swift
│   └── RootView.swift
├── FreeTubeApp.swift
├── Core/
│   ├── Networking/        # YouTubeKit wrappers, one Service per response family
│   ├── Auth/              # CookieStore, KeychainHelper, LoginCoordinator,
│   │                      # SessionManager, SubscriptionRegistry, AuthState
│   ├── Player/            # PlayerStateManager, QueueManager, PictureInPictureModel,
│   │                      # AudioSessionConfigurator, NowPlayingCenter,
│   │                      # RemoteCommandCenter, WatchProgressReporter, YouTubeResumeCache
│   ├── Download/          # DownloadManager, DownloadJob, DownloadProgress, DownloadError,
│   │                      # FFmpegRunner (iOS), AVFoundationMuxer (Mac)
│   ├── Persistence/       # @Model types, PersistenceController, PersistenceWriter,
│   │                      # DownloadsStore, DownloadEntry, DownloadMetadata, FileXattr
│   └── Models/            # Domain types: Video, Channel, Playlist, Comment,
│                          # VideoQuality, ErrorState, UserPreferences, YouTubeServiceError
├── Features/
│   ├── Home/              # HomeScreen + HomeViewModel
│   ├── Search/            # SearchScreen, SearchSuggestionList, SearchViewModel
│   ├── Library/           # LibraryScreen, HistoryScreen, SubscribedChannelsScreen, ViewModels
│   ├── Channel/           # ChannelScreen, ChannelTabScreen, ViewModel
│   ├── Playlist/          # PlaylistScreen + ViewModel
│   ├── VideoDetail/       # CommentsSection + CommentsViewModel (shown in the player)
│   ├── Account/           # AccountViewModel (used by LibraryScreen)
│   ├── Downloads/         # DownloadsScreen (the Downloads tab)
│   ├── Login/             # LoginScreen, LoginWebView
│   └── Settings/          # SettingsScreen + ViewModel
├── UI/
│   ├── Player/            # FullScreenPlayer, VideoSurface, PlayerControlsOverlay,
│   │                      # AirPlayButton, PlaybackStatusOverlay, WindowControlsInsetReader
│   ├── Components/        # VideoCard, VideoRow, VideoTileGrid, ChannelRow, CommentRow,
│   │                      # PlaylistRow, AddToPlaylistSheet, ActivityShareSheet, DownloadButton,
│   │                      # SectionHeader, LoadingView
│   └── Modifiers/         # ErrorToastModifier, ReadableContentWidthModifier
├── Resources/
│   └── Localizable.xcstrings    # en / es / ru / fr / de
└── Assets.xcassets
```

When asked to "add a feature", create or extend a folder under `Features/`. Keep shared UI atoms in `UI/Components/`.

---

## 5. File and naming conventions

- One type per file. File name matches the type name.
- Service classes end in `Service` (`SearchService`, `HistoryService`).
- View models end in `ViewModel`, declared `@Observable` (iOS 17+).
- SwiftUI views are nouns (`VideoCard`, `HomeScreen`). Use `Screen` suffix for top-level screens.
- Async functions return concrete types or throw — no `Result` returns from public service APIs.
- Use `// MARK: -` to separate logical sections in files over 100 lines.
- Annotate iOS-17-only types with `@available(iOS 17.0, *)` even though the deployment target is 17.0 — it documents the dependency and keeps the build clean if the target ever drops.

---

## 6. Mandatory mapping: YouTubeKit response → service method → ViewModel

Every YouTubeKit response type gets exactly one service method. Do not call `YouTubeKit` from anywhere except `Core/Networking/`. Source of truth:

| Response | Service method |
|---|---|
| `HomeScreenResponse` (+Continuation), requested as our `HomeScreenFeedbackResponse` (+Continuation): same request, plus each video's "Not interested" / undo tokens | `HomeService.fetchHome()` / `fetchMore()` |
| `SearchResponse` (+Continuation) | `SearchService.search(query:)` / `fetchMore()` |
| `AutoCompletionResponse` | `SearchService.autocomplete(query:)` |
| `ChannelInfosResponse` (+Videos/Shorts/Directs/Playlists +Continuations) | `ChannelService.fetchChannel(id:)` / `fetchVideos()` / `fetchShorts()` / `fetchDirects()` / `fetchPlaylists()` |
| `PlaylistInfosResponse` (+Continuation) | `PlaylistService.fetchPlaylist(id:)` / `fetchMore()` |
| `VideoInfosResponse` | `VideoService.fetchInfo(id:)` / `fetchInfo(id:anonymous:)` (YouTubeKit's default: watch-page scrape — metadata; HLS only for live) — **also `fetchInfoViaVisionOS(id:)`** (`VISIONOS` `/player`, primary stream source) and **`fetchInfoViaTVHTML5(id:)`** (`TVHTML5_SIMPLY_EMBEDDED_PLAYER` `/player`, PoT-exempt progressive) |
| `MoreVideoInfosResponse` | `VideoService.fetchMoreInfo(id:)` |
| `AccountInfosResponse` | `AccountService.fetchAccountInfo()` |
| `AccountLibraryResponse` | `AccountService.fetchLibrary()` |
| `AccountSubscriptionsResponse` | `SubscriptionService.fetchSubscriptions()` |
| `HistoryResponse` / `RemoveVideoFromHistroryResponse` | `HistoryService.fetch()` / `remove(videoID:)` |
| `FeedbackResponse` (ours: YouTube's `/feedback` request, borrowed from `RemoveVideoFromHistroryResponse`) | `FeedbackService.send(token:)` ("Not interested" and its Undo) |
| `SubscribeChannelResponse` / `UnsubscribeChannelResponse` | `SubscriptionService.subscribe(channelID:)` / `unsubscribe(channelID:)` |
| `AllPossibleHostPlaylistsResponse` | `PlaylistService.fetchHostablePlaylists(videoID:)` |
| `AddVideoToPlaylistResponse` / `RemoveVideoByIdFromPlaylistResponse` / `RemoveVideoFromPlaylistResponse` | `PlaylistService.add/remove*` |
| `CreatePlaylistResponse` / `DeletePlaylistResponse` / `MoveVideoInPlaylistResponse` | `PlaylistService.create/delete/move*` |
| `LikeVideoResponse` / `DislikeVideoResponse` / `RemoveLikeFromVideoResponse` | `VideoActionsService.like/dislike/removeRating*` |
| `CreateCommentResponse` / `EditCommentResponse` / `DeleteCommentResponse` | `CommentService.create/edit/delete*` |
| `ReplyCommentResponse` | `CommentService.reply(commentID:text:)` |
| `LikeCommentResponse` / `DislikeCommentResponse` / `RemoveLikeCommentResponse` / `RemoveDislikeCommentResponse` | `CommentService.like/dislike/removeRating*` |
| `CommentTranslationResponse` | `CommentService.translate(commentID:)` |

If a feature seems to need data without a clear mapping above, stop and ask before improvising.

---

## 7. Playback pipeline (critical)

**Tap → play, like the YouTube app.** `PlayerStateManager.resolveAndPlay` resolves a stream URL and hands it straight to `AVQueuePlayer`. Playing never downloads or writes anything to disk. The one exception to resolving: a video the user already downloaded (§10) plays from its file — instant and offline, without captions — and falls back to streaming if the file fails.

Stream sources, tried in order (`PlayerStateManager.StreamSource`):

1. **`visionOS`** — `VideoService.fetchInfoViaVisionOS(id:)` → `YouTubeKitClient.visionModel`, a `/player` request with the `VISIONOS` client context (client id 101, values mirror yt-dlp's `visionos` client). Returns an `hlsManifestUrl` whose segments play **without a Proof-of-Origin token** for ordinary videos and live streams. Primary source; ~1s.
2. **`tvhtml5`** — `fetchInfoViaTVHTML5(id:)` → `tvHtmlModel` (`TVHTML5_SIMPLY_EMBEDDED_PLAYER`). HLS if present, else the best muxed progressive MP4 within `preferredQuality.heightCap`.
3. **`signedIn`** — `fetchInfo(id:)` on the signed-in `model`, only when `AuthState` is `.loggedIn`. For videos that need an account (age-restricted, members-only).

If a URL resolves but the `AVPlayerItem` then fails (e.g. a 403), the item-status observer calls `retryNextStreamSource(after:)`, which resumes with the next untried source. When every source is exhausted, `loadState = .failed(streamExtractionFailed)` and `PlaybackStatusOverlay` shows the error over the video surface.

**What does NOT work (don't go back there):**
- YouTubeKit's default `VideoInfosResponse` (`model`, `.videoInfos`) is a **web watch-page scrape** with a Safari UA. For VOD it has no `hlsManifestUrl` and only `signatureCipher`/SABR formats → no playable URL. Fine for metadata.
- The real iOS-app client (`VideoInfosWithDownloadFormatsResponse`, `clientName: IOS`) returns no HLS and no muxed formats for VOD — only PoT-locked adaptive streams.
- **Never send the signed-in cookies with stream lookups.** YouTube rejects web-session cookies + SAPISIDHASH on these clients (yt-dlp skips the iOS client when logged in for the same reason). `visionModel`, `tvHtmlModel` and `anonymousModel` never get cookies; only `model` does (`YouTubeKitClient.applyCookies`).
- A "login required" failure from an anonymous lookup means the video needs an account — it must not sign the user out (`fetchInfo(id:anonymous: true)` skips `clearSessionIfLoginRequired`).

**Verifying a client without the app:** POST the same JSON to `https://www.youtube.com/youtubei/v1/player?prettyPrint=false` with `curl`, sending `X-Goog-Visitor-Id` (take `VISITOR_DATA` from any watch page) — without it YouTube answers "Sign in to confirm you're not a bot". Check `streamingData.hlsManifestUrl`, then fetch a segment from the variant playlist.

---

## 8. Player UI rules

- **One `PlayerStateManager`** is the single source of truth for current playback. Injected via SwiftUI `@Environment(PlayerStateManager.self)`.
- **No mini player.** Tapping a video presents `FullScreenPlayer` as a `.fullScreenCover` from `RootView` (`PlayerStateManager.fullScreenPresented`); closing it stops playback. (LNPopupUI and its mini bar were removed.)
- **Custom controls, not `AVPlayerViewController`.** The picture is a plain `AVPlayerLayer` (`VideoSurface`); `PlayerControlsOverlay` draws the controls YouTube-style: top bar with close chevron (leading) and full screen / PiP (`PictureInPictureModel`) / AirPlay (`AirPlayButton`) (trailing); center −10 / play-pause / +10; bottom scrubber + ⋯ menu (quality, speed, subtitles, audio track, loop video, sleep timer). Quality choices come from the HLS variants (`PlayerStateManager.qualityChoices`); a fixed quality is a ceiling via `preferredMaximumResolution` and is the same setting as Settings → Preferred quality. Gestures: tap toggles (auto-hide after 3s while playing), double-tap half seeks ±10s, sideways drag scrubs, pull down closes. `AVPlayerViewController` was dropped because its controls can't be rearranged or trimmed (no API to hide the volume button or move the top bar) and its own tap / double-tap handling fought ours. Don't bring it back.
- **Full-screen mode** is `FullScreenPlayer.isVideoFullScreen`: the video fills the player window, panels hide, status bar hidden. The chevron or pull-down leaves full screen first.
- **Window controls (iPadOS 26 windowed apps):** `WindowControlsInsetReader` measures the traffic lights' footprint; the video column (or, in full screen, the top bar) is padded by it so they never cover controls.
- **`AVQueuePlayer`**, not `AVPlayer`. Required for `advanceToNextItem()` and queue introspection. Important: `replaceCurrentItem(with:)` is a no-op on `AVQueuePlayer` when its internal queue is empty (our usual state). Use `removeAllItems()` + `insert(_:after:)` (see the `loadItem` helper).
- **Background audio:** `AudioSessionConfigurator` runs at app launch with `(.playback, .moviePlayback)`.
- **Now Playing:** `NowPlayingCenter` keeps `MPNowPlayingInfoCenter.default().nowPlayingInfo` in sync — title, channel as artist, thumbnail (downloaded via Kingfisher) as artwork, elapsed/duration.
- **Remote commands:** `RemoteCommandCenter` wires `MPRemoteCommandCenter` for play/pause/next/previous/skip ±15s/seek.
- **Resume position:** the app saves the position to `WatchHistoryEntry.lastPosition` / `positionSavedAt` (every ~5s, on pause / switch / close / end). Signed-in feeds also carry YouTube's resume point (`YTVideo.startTime`), which `Mappers` records in `YouTubeResumeCache`. On open, `PlayerStateManager.resumePoint` uses whichever is newer (local save time vs when the feed was loaded); restarts if < 5s in or within 10s of the end.
- **Watch-progress sync to YouTube:** when signed in (and the setting is on), `WatchProgressReporter` reads `playbackTracking` from the signed-in watch page (`WatchProgressService`) and pings `videostatsPlaybackUrl` once (adds the view to history) and `videostatsWatchtimeUrl` with `st`/`et`/`cmt` every 10s of playback and on pause / seek / switch / close — so YouTube's history and resume point match the app across devices. Undocumented endpoints; failures are logged and ignored.
- **Related videos, not an "Up next" queue:** like the YouTube app, the player lists YouTube's recommendations for the current video (`PlayerStateManager.recommendations`, from `VideoService.fetchMoreInfo` via `loadRecommendations`, fetched on every `load` in parallel with stream resolution). Full-width `VideoCard`s in the stacked phone layout, `VideoRow`s in the side column / wide screens; the stacked layout's "Related" / "Comments" button switches panels. The queue itself has no UI: it holds a playlist's Play all / Shuffle / row-tap order plus what was played this session (`QueueManager.setCurrent` appends; picking a video outside the queue ends a playlist's shuffle).
- **Autoplay:** `playNext()` advances the queue first; at its end (repeat off, not a curated Play all / Shuffle), it plays the current video's first recommendation not already in the queue, so two videos recommending each other don't ping-pong. "Loop video" in the ⋯ menu sets `repeatMode = .one`.
- **Player backdrop must stay translucent.** `FullScreenPlayer` paints a `.thinMaterial` rectangle behind the entire player body (black only in full-screen mode). Anything that introduces an opaque background and turns it black is a regression. Common offenders + neutralizers:
  - **`NavigationStack` inside the player body:** the nav bar paints an opaque system background even with the title hidden. `.toolbarBackground(.hidden, for: .navigationBar)` is NOT sufficient — use `.toolbar(.hidden, for: .navigationBar)` to remove the bar entirely. Supply your own back/close button.
  - **`List` / `ScrollView` default content background:** apply `.scrollContentBackground(.hidden)` on every list/scroll view in the player body.
  - **`UIHostingController`-backed views (`NavigationStack` destinations):** add a defense-in-depth `.background { Rectangle().fill(.thinMaterial).ignoresSafeArea() }` on each destination root.
  - **Where you put `.background` matters.** Modifiers on `NavigationStack` itself (outside the trailing closure) paint *behind* its UIKit hosting container — its own opaque system background covers them. Backdrop must be applied *inside* the root content and again inside every `.navigationDestination { ... }` view.
  - **Don't replace the thinMaterial with `Color.black`** outside full-screen mode — the player is designed as one continuous translucent surface.

---

## 9. Authentication flow

1. `LoginScreen` presents a `WKWebView` against an **ephemeral `.nonPersistent()` `WKWebsiteDataStore`**. The ephemeral store is critical — a persistent store reuses any prior session and we'd capture stale cookies.
2. `LoginCoordinator` watches navigation; when the URL transitions to `youtube.com` after sign-in, it calls `WKWebsiteDataStore.default().httpCookieStore.getAllCookies` and filters for `.youtube.com` / `.google.com` domains.
3. **Cookie de-duplication:** when both `.youtube.com` and `.google.com` versions of the same cookie are present, **prefer `.youtube.com`** (`CookieStore.dedupe`). Length-based tie-breaking failed in practice — both scopes were 12 chars. YouTube-scoped cookies are the ones YouTube actually accepts.
4. Required cookies (all must be present): `SAPISID`, `__Secure-3PAPISID`, `LOGIN_INFO`, `SID`, `HSID`, `SSID`, `APISID`.
5. Cookies are serialized as a single Cookie-header string and stored in Keychain under `com.leshko.freetube.cookies` via `KeychainHelper`.
6. On every app launch, `SessionManager.bootstrap()` reads from Keychain and assigns to `YouTubeModel.shared.cookies` plus `YouTubeKitClient.shared.applyCookies(...)`.
7. **`SubscriptionRegistry`** persists the user's subscribed channel IDs in `UserDefaults` (`com.leshko.freetube.subscriptions`). Subscribe/unsubscribe optimistically flips this **and** calls the YouTube endpoint. Needed because YouTubeKit's `subscribeStatus` parser doesn't follow `pageHeaderRenderer` entity-key indirection — channel screens were always showing "Subscribe" even on subscribed channels until this cache was added.
8. **`AuthState`** (an `@Observable` singleton) drives root navigation: `.loggedIn` / `.loggedOut` / `.unknown`. On `cookieExpired` / 401-equivalent failures, `SessionManager.handleExpiredSession()` wipes Keychain + sets `AuthState.loggedOut` and the root re-routes to Login.

---

## 10. Downloads

Downloads are **explicit**: the user taps Download (the player's action row after Copy URL — `DownloadButton` — or a video's ⋯ menu). Playback never downloads (§7). Don't reintroduce download-before-play or background prefetch.

**Pipeline** (`DownloadManager.run`):

1. Resolve the same HLS stream the player uses (`StreamService`, `VISIONOS` client).
2. `HLSDownloadService` reads the master playlist, picks the best **H.264** variant within Settings → Download quality (360p–1080p, default 720p), and fetches its video and audio segments (6 at a time, each retried) into two temporary files. YouTube's segments are MPEG-TS video and ADTS AAC audio.
3. `FFmpegRunner` joins them with `ffmpeg -c copy -bsf:a aac_adtstoasc -movflags +faststart` — a repackaging, not a re-encode. ffmpeg is required on iOS: iOS's AVFoundation can't read TS / ADTS from local files. **On the Mac** (no ffmpeg build for Catalyst), macOS's AVFoundation can, and `AVFoundationMuxer` does the same join: AudioToolbox rewraps the ADTS audio into M4A (AVFoundation underestimates an ADTS file's length and would cut its end off), then an `AVAssetExportSession` passthrough writes the MP4. Checked frame-for-frame against ffmpeg's output on real YouTube segments.
4. The MP4 lands in the **Documents root** as `<title> [<videoID>].mp4`, and `DownloadsStore` writes its metadata (`DownloadMetadata`: video ID, title, channel, thumbnail JPEG, duration) as an extended attribute on the file.

**Storage is the file system — no SwiftData model.** `DownloadsStore` scans Documents (on launch, after changes, on return to foreground) and publishes `entries` / `filesByVideoID`. Documents is visible in the Files app, so files the user removes or adds there are simply reflected. Never store a stream URL in the metadata (§2.6).

**Export** is the system share sheet on the file (`fileShareSheet` → `ActivityShareSheet`): Save to Files, AirDrop, Save Video (Photos — hence `NSPhotoLibraryAddUsageDescription`), or any app that opens videos. Rows in `DownloadsScreen` can also be dragged out on iPad, and on Mac there's Show in Finder.

**State for UI:** `DownloadManager.jobs` (queued / downloading / saving / failed — unfinished downloads only; two run at once) and `progressByVideoID`, kept separate so only progress views re-render per tick. A finished download is a file, not a job.

**Why not direct files or yt-dlp:** YouTube's direct `videoplayback` formats are Proof-of-Origin gated — without a token the CDN serves about the first minute, then 403s. That is what the old yt-dlp stack (Python, JavaScriptCore `deno` bridge; removed 2026-10-18) fetched, and by 2026-11 it got 360p at best. The HLS segments have no such gate. Don't bring yt-dlp back for this.

**Limits:** live streams can't be downloaded (their playlist never ends); downloads run while the app is in the foreground (or playing audio) — a suspended app resumes the download when it returns; no captions in the file.

---

## 11. SwiftData models

```swift
@Model class WatchHistoryEntry { videoID, title, channelName, thumbnailURL, watchedAt, lastPosition }
@Model class FavoriteVideo     { videoID, title, channelName, thumbnailURL, savedAt }
@Model class FavoritePlaylist  { playlistID, title, thumbnailURL, savedAt }
@Model class SearchHistoryEntry { query, searchedAt }
```

`PlaybackQueueSnapshot` (originally planned) was not implemented — the queue is reconstructed from recommendations on each play.

**Writes go through `PersistenceWriter` (an `@ModelActor`).** Views and view models never block on SwiftData saves; they call `PersistenceWriter.shared.upsertFoo(...)` and fire-and-forget. The actor owns a background `ModelContext`, batches writes, and keeps the SQLite queue off the main thread. Direct `modelContext.insert(...)` on the main actor is fine for trivial inserts (e.g. one-shot user actions) but avoid loops or burst inserts there.

Preferences live in `UserDefaults` via a `@AppStorage`-backed `UserPreferences` type. Don't over-engineer with SwiftData for primitive flags.

---

## 12. Error handling rules

- Public service methods are `async throws`. Define `YouTubeServiceError`: `notAuthenticated`, `rateLimited`, `videoUnavailable`, `streamExtractionFailed`, `cookieExpired`, `network(Error)`, `decoding(Error)`, `unknown(Error)`.
- View models catch errors and translate to `@Published var errorState: ErrorState?` (or `var` on `@Observable`). Never let raw errors bubble to views.
- Show errors via the single `ErrorToastModifier`. Don't pepper alerts across screens.
- On `cookieExpired` / 401-equivalent: `SessionManager.handleExpiredSession()` wipes Keychain cookies + flips `AuthState`. Root view reacts and routes to Login.
- Stream resolution failure must always fall through to the next stream source (see §7) before surfacing to the user.

---

## 13. Logging

Use `os.Logger`:

```swift
private let log = Logger(subsystem: "com.leshko.freetube", category: "PlayerStateManager")
log.info("Resolving \(videoID, privacy: .public) at quality \(quality.rawValue, privacy: .public)")
log.error("Stream extraction failed: \(error.localizedDescription, privacy: .public)")
```

- Cookie values, signed URLs, user emails: `privacy: .private` or omit entirely.
- Public IDs, response status, timing: `privacy: .public` is fine.
- **Do not log from SwiftUI body re-evaluation paths.** `Menu` bodies in the player re-evaluate every player time tick; even a `log.debug` line there floods the device log with hundreds of lines per second.

---

## 14. Localization

- `Localizable.xcstrings` (Apple String Catalog format), fully translated for **en / es / ru / fr / de**. `sourceLanguage: "en"`.
- Add new strings by using `String(localized:)` / `LocalizedStringKey` in code; Xcode's build-time extractor populates the catalog. After a build, open `Localizable.xcstrings` and translate any new `state: "new"` entries.
- **Non-translatable strings must never enter the catalog. Emit them with `Text(verbatim:)`, not a localizable `Text`.** A string whose entire content is format specifiers (`%@`, `%lld`, `%lld%%`), punctuation/symbols (`•`, `·`, `≈`, `,`), or brand names (`yt-dlp`, `freetube.io`) — with no actual words — has nothing to translate. The root cause is code: `Text("\(x) · \(n)%")` makes SwiftUI treat the literal as a `LocalizedStringKey`, so the extractor auto-adds junk keys like `%@ · %lld%%` on every build. Marking them `shouldTranslate: false` only suppresses *translation* — the key still gets re-added and clutters the catalog. **Fix at the source:** wrap these in `Text(verbatim: "...")` (for `.accessibilityLabel`, pass `Text(verbatim:)` explicitly). Then delete the orphaned keys from `Localizable.xcstrings`; once the code uses `verbatim`, the extractor won't recreate them. Example: `%@, %@` (VideoCard accessibility) is emitted with `Text(verbatim:)`. When you write a new pure-format/symbol/brand string, reach for `Text(verbatim:)` up front so it never reaches the catalog.
- Pluralization uses Apple's CLDR plural rules through the catalog's variation editor.
- If you add a string that contains a literal source-file reference (e.g. an internal `ContentView` placeholder), use a clean user-facing value in the translation columns even if the key looks debug-ish.

---

## 15. Critical workarounds (read before refactoring `Core/`)

### 15.1 ffmpeg calls must be serialized

`FFmpegSupport.ffmpeg(_:)` enters a C library with global state (the `+faststart` pass, the package's `setjmp`/`longjmp` hook); two calls at once crash. Every call goes through the `FFmpegRunner` actor, which chains each invocation behind the previous one. Never call `ffmpeg(_:)` directly.

### 15.2 Linker warnings are off for the app target (`OTHER_LDFLAGS = -Wl,-w`)

The prebuilt ffmpeg tool library (`libfftools.a`, from `FFmpeg-iOS-Lame`) has a zero-data section aligned to 32 KB; iOS pages are 16 KB, so every link printed "reducing alignment of section __DATA,__common from 0x8000 to 0x4000". It is harmless (page alignment is the most the OS can give) and can't be fixed without rebuilding ffmpeg; `-sectalign` only swaps it for another warning. `-w` silences **all** linker warnings for the target — if a link problem is suspected, remove the flag temporarily to see them.

### 15.3–15.4 (removed)

Python thread-pinning, the yt-dlp ffmpeg-merger hang, and yt-dlp PoT/n-cipher notes applied to the yt-dlp download stack, which no longer exists (§10).

### 15.5 AVQueuePlayer + `replaceCurrentItem` is a no-op when queue is empty

Don't use it. Use `removeAllItems()` + `insert(_:after:)` (see `loadItem`).

### 15.6 SourceKit "No such module 'Kingfisher'" warnings

Stale Xcode index. Real compiler links these fine; `xcodebuild` shows `BUILD SUCCEEDED`. Ignore. Clean Build Folder clears it.

### 15.7 Login `WKWebsiteDataStore` must be ephemeral

Using `.default()` reuses prior session cookies and captures stale ones. Use `.nonPersistent()`.

### 15.8 Cookie domain de-dup picks `.youtube.com`

When `.youtube.com` and `.google.com` versions of the same cookie are both present (post-login), YouTube only accepts the `.youtube.com` value. `CookieStore.dedupe` enforces this — don't simplify it to a length-based tiebreak.

### 15.9 `SubscriptionRegistry` exists because YouTubeKit can't parse subscribe state reliably

YouTubeKit's `subscribeStatus` doesn't follow `pageHeaderRenderer` entity-key indirection. We persist subscribe state in `UserDefaults` and reconcile on subscribe/unsubscribe.

### 15.10 Don't run heavy work from SwiftUI bodies

Anything inside `Menu` bodies in the player fires hundreds of times per second under the player view's KVO storm. Cheap calls are fine; logging from them is not. Generally: anything called from a re-evaluating body should be allocation-free and log-free.

### 15.11 (removed)

The JavaScriptCore `deno` bridge for yt-dlp went away with the yt-dlp download stack (§10).

### 15.12 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` runs anything unannotated on main

This project sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` in both Debug and Release. Under that setting:

- A top-level `public func foo() async throws { ... }` is implicitly `@MainActor`.
- A top-level enum / struct / class with no isolation marker is implicitly `@MainActor`. Its static members inherit.
- `Task { ... }` (the `init` form) inherits caller isolation, which under default-MainActor is main — **even when created from inside a non-main `actor` body**.

Symptom: blocking or long-running synchronous work lands on Thread 1 (main) and freezes the UI even though it was "wrapped in a Task".

**Fix for new code that does heavy synchronous work:**
- Use `Task.detached(priority: .utility) { ... }` to dispatch, never plain `Task { }`. `.detached` is the explicit "do NOT inherit isolation" form.
- Mark such top-level functions `nonisolated`, and enclosing enums / structs `nonisolated` so their static members aren't pulled to main either (`YouTubeKitClient` is `nonisolated` for this reason).

### 15.13 The Mac build is Mac Catalyst

`SUPPORTS_MACCATALYST = YES` with the Mac idiom (`TARGETED_DEVICE_FAMILY = 1,2,6`), same bundle ID (`DERIVE_MACCATALYST_PRODUCT_BUNDLE_IDENTIFIER = NO`). What differs from iOS, and why:

- **ffmpeg is iOS only.** The `kewlbear` xcframeworks have no Catalyst slice, so both ffmpeg package products carry `platformFilter = ios` and `FFmpegRunner` is `#if !targetEnvironment(macCatalyst)`. Downloads join with `AVFoundationMuxer` instead (§10). Don't add a second ffmpeg for the Mac.
- **App Sandbox on** (`FreeTube/FreeTube.entitlements`, Mac only via `CODE_SIGN_ENTITLEMENTS[sdk=macosx*]`). Not for the App Store: without it `Documents` is the user's real `~/Documents`, which `DownloadsStore` would scan as the downloads folder.
- **Keychain needs a provisioning profile.** A Catalyst app uses the data-protection keychain; without an application identifier, writes fail with -34018 (reads just miss, so sign-in *looks* fine until relaunch). The entitlements declare `keychain-access-groups` = `$(AppIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER)`, so Xcode's signing embeds a profile — a development profile locally (the Mac must be registered in the developer account), a Developer ID profile in the release export. Never re-sign the Mac app by hand with `codesign`: without the profile that entitlement stops the app from launching. `KeychainHelper` logs any status other than success / not-found.
- **Release:** `scripts/publish.sh <version>` cuts a GitHub release on this repo: preflight (clean `main` in sync with origin, unused tag), release notes from `release-notes/FreeTube-<version>.md` or generated from commits and reviewed, then `scripts/build-mac-release.sh` (universal archive, `-exportArchive` with method `developer-id`, notarize + staple the app and the DMG with notary profile `FreeTube` / `FREETUBE_NOTARY_PROFILE`), then the release with the DMG and `SHA256SUMS`, tagged `v<version>`. Build number = `git rev-list --count HEAD`. iOS goes to TestFlight with `scripts/publish_testflight.sh <version> <build>` (archive, App Store Connect export, IPA checks, `asc publish testflight` to the internal group "FreeTube Testers", then attaches the build to the App Store version in Prepare for Submission — App Store Connect's Apps page shows the icon of *that* build, and a version with none attached shows a blank placeholder). Both modeled on 115Lab's scripts.
- **Mac UI:** `MacCommands` (menu bar: ⌘, settings, Navigate ⌘1–3 / ⌘F / ⌘R refresh, Playback). `MacIntegration` gates Mac-only behavior (Show in Finder, minimum window size 760×560, no cellular toggle, Finder wording instead of the Files app). Catalyst windows always report a regular size class.

### 15.14 `YouTubeLocale`: YouTube rejects unknown `gl` / `hl`

YouTubeKit's default locale is `Locale.preferredLanguages[0]` verbatim. YouTube answers `account/account_menu` with HTTP 400 when `gl` is a region it doesn't serve (`en-CN` → `CN`) or malformed (`zh-Hans-CN` → `HANS-CN`), and the Library then reads the 400 as signed out. `YouTubeKitClient` sets `model.selectedLocale = YouTubeLocale.tag()`: the preferred language and the system region, each kept only if YouTube accepts it (else `en` / `US`). The accepted lists came from probing every ISO code with `curl` (2026-11).

---

## 16. Build priority (work top-down)

Current state of the implementation. Items marked ✓ are shipped.

- **P0 — MVP playback** ✓
  - YouTubeKit SPM setup
  - `HomeService`, `SearchService` (+ autocomplete), `VideoService`
  - Home screen, Search screen, Video detail screen
  - Streaming playback (visionOS HLS → TVHTML5 → signed-in, with in-player fallback)
  - `PlayerStateManager`, full-screen player cover with custom controls
  - Background audio + Now Playing + Remote Command Center
- **P1 — Account** ✓
  - Login (`WKWebView` ephemeral data store + Keychain)
  - `AccountService`, `SubscriptionService`, `HistoryService`
  - Subscriptions tab, Library tab (History / Playlists / Your videos / Subscriptions / Liked / Watch later)
  - Like / Dislike, Save-to-playlist sheet
  - Channel screen, Playlist screen
- **P2 — Engagement** ✓ (mostly)
  - `CommentService` (read + write + reply + rate)
  - Queue management UI
  - PiP, AirPlay
  - CarPlay audio mode — not yet
- **P3 — Polish** (in flight)
  - Comment translation ✓
  - Localization en / es / ru / fr / de ✓
  - iPad layout: readable-width columns + tile grid for Home and search ✓
  - Custom video controls (YouTube-style overlay, PiP, AirPlay, full screen, speed / subtitles / audio menu) ✓
  - Downloads to MP4 with offline playback and export to other apps (§10) ✓
  - Mac Catalyst build, released as a notarized DMG on GitHub (§15.13) ✓

---

## 17. When to ask before doing

Stop and ask when:

- A request implies adding a dependency not on the locked stack.
- A request implies App Store distribution accommodations.
- A YouTubeKit response type doesn't map cleanly to the service layer in §6.
- A request asks Claude to handle cookies, tokens, or stream URLs in any persistence layer other than Keychain (cookies) or in-memory (URLs).
- A request asks to integrate with Chromecast, Google Cast, or any non-AirPlay casting (not in scope).
- A request asks to drop the iOS deployment target below 17.0 — that's not a config change, it's a SwiftData → CoreData + `@Observable` → `ObservableObject` refactor across ~30 files.

Do not ask before:

- Adding a new feature folder under `Features/`.
- Adding shared components under `UI/Components/`.
- Refactoring within a single file.
- Writing or extending tests.
- Adding `os.Logger` lines (outside of hot view-body paths — see §15.10).

---

## 18. Code style

- Four-space indentation, matching SwiftFormat default.
- Trailing closures only when there's exactly one closure parameter.
- `self.` only when required by closure capture rules.
- Prefer `let` over `var`. Mark types `final` unless designed for subclassing.
- Group `import` statements: stdlib first, Apple frameworks next, third-party last, each block separated by a blank line.
- Doc comments (`///`) on all public service methods, view models, and non-trivial types — especially anything that encodes a workaround like §15. Future-you will thank you.

---

## 19. Known limitations to communicate

If asked to "make it more robust" or "production-ready", point to these realities first instead of inventing solutions:

- YouTube can change its internal API at any time and silently break extraction. There is no SLA.
- Cookies expire (typically 1-2 weeks of inactivity); the user will need to re-login.
- Streaming depends on YouTube continuing to serve PoT-free HLS to the `VISIONOS` client. If that stops, update the client context (compare with yt-dlp's `INNERTUBE_CLIENTS` in `yt_dlp/extractor/youtube/_base.py`) — see §7 for how to verify with `curl`.
- Downloads depend on the same PoT-free HLS as playback, and on its segments staying MPEG-TS / fMP4 that ffmpeg can repackage (§10).
- IP-level rate limiting from YouTube can hit users on shared networks (CGNAT, VPN). No client-side fix.
- This codebase intentionally does not implement App Store evasion techniques. Sideload distribution is the assumption.
- HLS variant selection is left to AVPlayer's adaptive bitrate logic; `preferredQuality.heightCap` only caps it (`preferredMaximumResolution`), it can't force a minimum.

---

## 20. When in doubt

Re-read sections 2, 6, 7, and 15. Most architectural questions are answered there. If still unclear, ask in the PR or commit message rather than guessing — the cost of asking is one round-trip; the cost of guessing wrong is a refactor.
