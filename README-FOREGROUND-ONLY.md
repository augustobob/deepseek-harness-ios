# Foreground-only fork (branch `augusto/main`)

This branch = upstream `codex/deepseek-parity` + R0GUEEE's English translation
(`i18n/english`, commit 3f2e0d7 incl. the unsigned-IPA GitHub Actions workflow)
+ a small, isolated patch that makes the app run **only while it is in the
foreground**.

## What kept the app running in the background (upstream)

| Mechanism | Where |
|---|---|
| `UIBackgroundModes`: `audio`, `location`, `processing` | `project.yml` / `Resources/Info.plist` |
| Silent-audio keep-alive (opt-in "Enhanced background") | `Core/Background/BackgroundAudioKeepAlive.swift` |
| Coarse "Always" location keep-alive (opt-in) | `Core/Background/BackgroundLocationKeepAlive.swift` |
| `BGContinuedProcessingTask` for every run (opt-in) | `Core/Background/ContinuedProcessingController.swift`, `AppModel.startRun` |
| `beginBackgroundTask` lease taken for every run (~30 s grace) | `Core/Background/LegacyBackgroundTaskLease.swift` |
| `BGProcessingTask` wake-ups for schedules / recovery | `ScheduleBackgroundController.swift`, `AppModel.scheduleNextBackgroundTurn` |
| Live Activity | `HarnessLiveActivityManager.swift`, `HarnessMobileLiveActivity/` |

## What this fork changes

* `ForegroundOnlyPolicy.isEnabled` (in `BackgroundPreferences.swift`) is `true`
  unless compiled with `HARNESS_ALLOW_BACKGROUND`.
* `UIBackgroundModes` removed from `project.yml` and `Info.plist`.
* Audio / location keep-alive and Continued Processing are never requested, whatever the
  saved settings say (the settings screen shows them disabled).
* BGProcessingTask requests are never submitted; leftovers are cancelled.
* Live Activities are never started (and existing ones are ended).
* When the scene enters `.background`, every live run is interrupted (same outcome
  as an iOS expiration) and marked for the existing foreground auto-resume, so it
  continues when you reopen the app. The short `beginBackgroundTask` lease taken at run
  start is only used to let that interruption finish cleanly.
* The Live Activity and Share extensions are no longer embedded
  (`project.yml`, main target dependencies commented out) because extensions
  break with a fixed-bundle-id sideload profile.

All code changes are guarded by `ForegroundOnlyPolicy.isEnabled`, so merging
upstream stays easy: `git fetch upstream && git merge upstream/codex/deepseek-parity`.

## Build

GitHub Actions → "Unsigned IPA" (manual dispatch) builds an unsigned IPA on `macos-26`
and publishes it as a release.
