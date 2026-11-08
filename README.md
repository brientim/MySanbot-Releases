# MySanbot Releases

Signed APKs for apps that run on Sanbot robots (OpenSDK Proxy, Vitalia, Human Follow, and others), plus the update manifest the robots read. This repo holds binaries only; the source lives in separate private repos.

## How robots update

The **OpenSDK Proxy** on each robot fetches [`latest.json`](latest.json) from `main`:

```
https://raw.githubusercontent.com/brientim/MySanbot-Releases/main/latest.json
```

It compares each entry's `version_code` with the installed app. When asked to update (`POST /apps/update {"package":"…"}` from My Sanbot, MySanbot.Web or the Proxy's HTML console), it downloads `apk_url` and checks that:

1. the file's SHA-256 equals `sha256`,
2. the APK's package name equals `package`,
3. the APK is signed by the same key as the installed app.

It installs with `pm install -r` through root when the robot has `su`. Otherwise it opens the Android installer, and someone taps **Install** on the robot's screen. That fallback needs **Unknown sources** turned on in the robot's settings.

## Manifest format

```json
{
  "schema": 1,
  "generated_at": "2026-11-09T00:00:00Z",
  "apps": [
    {
      "package": "mysanbot.opensdkproxy",
      "label": "OpenSDK Proxy",
      "slug": "opensdkproxy",
      "version_code": 98,
      "version_name": "1.3.83",
      "apk_url": "https://github.com/brientim/MySanbot-Releases/releases/download/opensdkproxy-1.3.83/opensdkproxy-1.3.83.apk",
      "sha256": "…",
      "size": 123456,
      "min_sdk": 21,
      "notes": "…",
      "published_at": "2026-11-09T00:00:00Z"
    }
  ]
}
```

## Publishing

On the build Mac (needs Android SDK build-tools, `jq` and an authenticated `gh`):

```bash
scripts/publish.sh path/to/app-release.apk opensdkproxy "What changed"
DRY_RUN=1 scripts/publish.sh path/to/app-release.apk opensdkproxy   # preview only
```

The script does the following, in order:

1. Reads the package, version and label with `aapt`.
2. Refuses an APK that isn't signed by the canonical robot key.
3. Refuses a `versionCode` that isn't higher than the published one.
4. Creates the release `<slug>-<versionName>` with the APK attached.
5. Updates `latest.json`, then commits and pushes it.

## Signing

Every APK in this manifest must be signed by the canonical robot key, certificate SHA-256 `4c94fbf5dce682c2ad3bbaf83f101dc65d6a1debcbf32ddee23b64e5b41e4e57`. An APK signed by any other key can't update the installed app in place: the robot needs an uninstall and reinstall over ADB, which clears that app's settings.
