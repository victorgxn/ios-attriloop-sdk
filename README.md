# AttriloopSDK (iOS)

Swift package for Attriloop mobile attribution.

## Install (Swift Package Manager)

In Xcode: **File ▸ Add Package Dependencies…** and enter the repo URL, or add to
your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/victorgxn/ios-attriloop-sdk.git", from: "0.1.0")
]
```

## Usage

```swift
import AttriloopSDK

// AppDelegate / App init:
Attriloop.shared.configure(apiKey: "at_live_xxx", isDebug: false)

// In-app events:
Attriloop.shared.sendEvent(.startTrial)
Attriloop.shared.sendEvent(.purchase, parameters: ["revenue": 29.99, "currency": "USD"])

// CUSTOM events require a name (use the dedicated helper):
Attriloop.shared.sendCustomEvent("share_referral", parameters: ["channel": "imessage"])

// Deferred deep links — forward universal-link / URL callbacks so the click token
// (`at_click`) is captured:
Attriloop.shared.handleDeepLink(url)

// For partner integrations (e.g. RevenueCat):
let id = Attriloop.shared.getAttriloopId()
Attriloop.shared.getAttributionParams { params in
    // params["mediaSource"], params["campaignName"], params["linkId"]
}

// Deferred deep-link destination (deep_link_value) — route the user after install:
Attriloop.shared.onDeepLink { value in
    // value is a RELATIVE in-app route (e.g. "product/42"). Treat as UNTRUSTED input.
    Router.navigate(to: value)
}
```

## Universal Links (open the app if installed)

Attriloop links are shaped `https://<edge-host>/l/<appLinkToken>/<slug>`. To make an
installed app open straight to the destination (instead of the App Store):

1. In the **Attriloop console → SDK setup**, enter your **Apple Team ID** for the app.
2. Add the **Associated Domains** capability to your app target (SwiftPM packages can't
   carry entitlements — this lives in the host app):
   ```
   applinks:<edge-host>
   ```
   The edge serves `/.well-known/apple-app-site-association` claiming `/l/<token>/*`.
3. Forward the universal-link activity + URL-scheme opens to the SDK:
   ```swift
   // SwiftUI
   .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
       if let url = activity.webpageURL { Attriloop.shared.handleDeepLink(url) }
   }
   .onOpenURL { url in Attriloop.shared.handleDeepLink(url) }

   // UIKit SceneDelegate
   func scene(_ s: UIScene, continue activity: NSUserActivity) {
       if let url = activity.webpageURL { Attriloop.shared.handleDeepLink(url) }
   }
   ```

`handleDeepLink` resolves the link via `GET /v1/resolve` (for an installed re-open) or
falls back to the deferred attribution poll (for a fresh install), then fires
`onDeepLink` with the destination — gated so a low-confidence fingerprint guess never
auto-navigates.

## How attribution works

1. On first-open the SDK posts the install with device signals and, when available,
   the **Apple AdServices** token (`AAAttribution`, iOS 14.3+) — verified server-side
   to credit Apple Search Ads.
2. Deferred deep-link clicks captured via `handleDeepLink(_:)` (universal links) are
   matched deterministically to the originating `at_click`.
3. Otherwise the backend falls back to a coarse fingerprint (IP + platform + locale)
   within the attribution window. Apple does not forward install referrers, so a cold
   install with no universal-link reopen resolves probabilistically by fingerprint.
4. `getAttributionParams(_:)` polls `GET /v1/attribution` until the backend resolves
   the install, then caches the result.

## Privacy attribution (SKAdNetwork + AdAttributionKit)

For **paid ad networks** on iOS, `configure(apiKey:)` also drives Apple's
privacy-preserving attribution — **no ATT prompt, no IDFA**:

- Registers for ad-network attribution and fetches a server-defined conversion schema
  (`GET /v1/skan-config`), so what a conversion value means is retunable without a new
  build.
- Each `sendEvent(...)` folds the event into a monotonic conversion value and reports
  it via `SKAdNetwork.updatePostbackConversionValue` (iOS 14+) **and**
  `AdAttributionKit.Postback.updateConversionValue` (iOS 17.4+).
- Apple then sends signed, aggregated postbacks to the Attriloop edge, which verifies
  the signature before crediting.

The **consumer app** must point Apple's developer-copy endpoints at the edge in
`Info.plist` so Apple's signed postbacks reach Attriloop:

```xml
<key>NSAdvertisingAttributionReportEndpoint</key>
<string>https://api.attriloop.com</string>
<key>AttributionCopyEndpoint</key>
<string>https://api.attriloop.com</string>
```

The exact host is shown in the **Attriloop console → SDK setup**. Without these keys,
Apple's SKAdNetwork / AdAttributionKit postbacks never reach the edge and paid installs
go unattributed.

## Events are delivered durably

`sendEvent` persists to an on-disk queue first, then flushes — a transient network
failure, timeout, or the app being killed mid-send never loses the event. Each event
carries an idempotency id so backend retries are deduped.

## Build & test

```bash
swift build
swift test
```

## TODO before 1.0

- ATT / consent gating before collecting IDFA (only needed for device-graph matching).
- Reinstall detection across uninstall (Keychain-backed id).
- React Native / Flutter wrappers.
