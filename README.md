# Revive

**Turn an old iPad into your Mac's display, keyboard and trackpad.**

Revive brings an iPad stuck on iOS 12 back into daily use. Extend or mirror your Mac onto it over a Lightning cable or Wi-Fi, then type and point from the iPad itself. With the Mac's lid closed, the iPad can stand in for the whole laptop. Free, open source, and everything stays between your two devices.

Tested on an iPad Air (A1475, iOS 12.5.8) with a Mac on macOS 26. Any iPad or iPhone on iOS 12 or later should work.

## Features

**Display**
- **Extend or Mirror, started from the iPad.** Tap a tile and the Mac sets the display up. No clicking on the Mac.
- **Cable or Wi-Fi.** The cable is preferred (steadier, lower latency); unplug and it falls back to Wi-Fi.
- **Upright iPad, three ways.** Game Boy layout (the picture on top, keyboard and trackpad docked below), a portrait Mac display, or staying in landscape.
- **Pinch to zoom.** Zoom into part of the Mac screen on the iPad, and the zoom follows the pointer.
- **Quality and size.** Best, Balanced or Fast, plus Larger text, Default or More space.

**Input**
- **See-through Mac keyboard.** A full Mac layout over the bottom of the screen. Hold modifiers or tap them once for the next key; Delete, space and the arrow keys repeat.
- **Trackpad.** Relative pointer with acceleration, tap to click, two-finger tap to right-click, tap to drag, two-finger scroll with momentum, and a scroll strip.
- **Mac gestures.** Three-finger swipes switch desktops and open Mission Control; pinch zooms in apps.
- **The picture as a trackpad.** Hide the trackpad panel and the whole picture becomes the trackpad.
- **Macro bar.** One-tap shortcuts such as ⌃C, ⌃← / ⌃→, Mission Control, ⌘Tab and Spotlight, plus your own. It also has left-hand L / R buttons and ▲ ▼ scroll buttons.
- **Edge swipes.** Swipe in from the left edge for the keyboard and trackpad, and down from the top for the controls.

**Everyday**
- **Clipboard sync.** Copy text on one device, paste it on the other.
- **Status bar.** Mac and iPad battery, latency and frames per second, with a red warning when a battery runs low.
- **Lock screen.** When the Mac locks, the iPad says so and can type your password to unlock it.
- **Start automatically.** Starts your last mode when the app opens.
- **Clamshell-proof.** Rotating the iPad or a dropped connection rebuilds the display without leaving the Mac without a screen, and the Mac reconnects by itself.

## How it works

Revive has two halves:

- **Mac: [OpenDisplay](https://github.com/peetzweg/opendisplay)** with six patches (`patches/`). OpenDisplay creates a virtual display, captures it, encodes H.264, and sends it to the device over USB (`usbmuxd`) or Wi-Fi (Bonjour). It turns the device's input into mouse and keyboard events. OpenDisplay's own iPad app needs iPadOS 17; Revive is what makes it work on iOS 12.
- **iPad: the Revive app** (`iOS/`), a clean-room iOS 12 client of OpenDisplay's protocol. It listens on port 9000, decodes the video, draws the Mac's cursor, and sends input and requests back.

The patches add what lets the iPad drive the session:

| Message | What it does |
| --- | --- |
| `hello` with `mode`, `quality` | Start Extend or Mirror at a quality chosen on the iPad. The iPad sends `hello` only after you tap a mode. |
| `standby` | Stop: the Mac removes the display and waits for the next tap. |
| `key`, `text`, `mouse` | Keyboard, typed text and trackpad input. |
| `subscribe` → `clipboard`, `macStatus`, `macLock` | Clipboard sync, Mac battery, and lock state. |
| Bonjour TXT `gate=1` | A Wi-Fi iPad you've connected once can start sessions at any time. |

Details are in [patches/README.md](patches/README.md). Devices you've never connected from the Mac still need one click there first, so a stranger's iPad on your Wi-Fi can't start mirroring your screen.

## Install

### 1. Get the code

```bash
git clone --recurse-submodules https://github.com/mfaseehuddin/iPad-Second-Screen.git
cd iPad-Second-Screen
```

`Mac/` is a submodule of unmodified upstream OpenDisplay. If you cloned without `--recurse-submodules`, run `git submodule update --init --recursive`.

### 2. Mac app

Use the patched build. Upstream's prebuilt OpenDisplay shows the picture, but it ignores everything the iPad asks for.

**Built on GitHub (no Xcode needed).** In your fork's **Actions** tab, run **Build Mac app**. It also runs on every push that changes `patches/`. Download the `Revive-Mac` artifact and unzip it to get `OpenDisplay.app`. It's ad-hoc signed, so clear the quarantine flag when you install it:

```bash
osascript -e 'quit app "OpenDisplay"'
rm -rf /Applications/OpenDisplay.app
cp -R ~/Downloads/OpenDisplay.app /Applications/
xattr -dr com.apple.quarantine /Applications/OpenDisplay.app
```

**From source:**

```bash
for p in patches/*.patch; do git -C Mac apply "../$p"; done
cd Mac && xcodegen generate && open OpenSidecar.xcodeproj   # run scheme OpenSidecarMac
```

**Permissions.** Grant **Screen Recording** (for the picture) and **Accessibility** (for input) in System Settings → Privacy & Security, then quit with ⌘Q and reopen. macOS ties these to the app's signature, so every new build needs them again. Reset the old grants first:

```bash
tccutil reset ScreenCapture com.peetzweg.opensidecar.mac
tccutil reset Accessibility com.peetzweg.opensidecar.mac
```

**Turn off auto-update.** OpenDisplay updates itself with Sparkle. Accepting an update would replace the patched build with upstream's. Turn off the checks:

```bash
defaults write com.peetzweg.opensidecar.mac SUEnableAutomaticChecks -bool NO
```

### 3. iPad app

The **Build iPad app** workflow runs on every push that changes `iOS/`. Its `Revive-ipa` artifact contains two files:

| File | For | Expires |
| --- | --- | --- |
| `Revive-fakesigned.ipa` | Jailbroken iPads with AppSync Unified | Never |
| `Revive.ipa` | Sideloadly with a free Apple ID | After 7 days |

**Jailbroken (AppSync Unified).** Install over the cable:

```bash
brew install libimobiledevice ideviceinstaller
ideviceinstaller install Revive-fakesigned.ipa
```

Or over SSH (needs OpenSSH and `appinst`):

```bash
scp Revive-fakesigned.ipa root@<ipad-ip>:/var/mobile/
ssh root@<ipad-ip> 'appinst /var/mobile/Revive-fakesigned.ipa && uicache -a'
```

**Not jailbroken.** Open [Sideloadly](https://sideloadly.io), drop in `Revive.ipa`, sign in with your Apple ID, then trust the certificate on the iPad under Settings → General → VPN & Device Management. With a free Apple ID, run Sideloadly again every 7 days.

**With Xcode.** Open `iOS/LegacyPadDisplay.xcodeproj`, set your Team, choose the iPad and press Run. Recent Xcode versions need the iOS 12 DeviceSupport files before the iPad shows up as a destination:

```bash
curl -L -o /tmp/12.5.zip https://raw.githubusercontent.com/apptim/iPhoneOSDeviceSupport/master/12.5.zip
unzip -o /tmp/12.5.zip -d /tmp/ds125
cp -R /tmp/ds125/12.5 ~/Library/Developer/Xcode/iOS\ DeviceSupport/
```

The Xcode project and target are still called `LegacyPadDisplay`; only the app's name changed. `iOS/project.yml` is the XcodeGen source, so run `xcodegen generate` after editing it.

## Use it

1. Open OpenDisplay on the Mac and Revive on the iPad.
2. Plug in the cable, or join the same Wi-Fi. Over Wi-Fi, connect the iPad once from OpenDisplay's device list, and allow Local Network on the iPad if asked.
3. When the status says **Mac connected**, tap **Extend** or **Mirror**.

| Do this | To |
| --- | --- |
| Arrow, bottom-right corner (or swipe in from the left edge) | Open the keyboard, trackpad and macro bar |
| ⌄ in the macro bar | Close them |
| **Keyboard** / **Trackpad** in the macro bar | Show or hide each panel |
| Tap or drag the picture | Click there, or move the pointer like a trackpad (Settings → Touch → Picture) |
| Two fingers on the picture | Scroll, with momentum |
| Pinch the picture / two-finger double-tap | Zoom in on the iPad / zoom back out |
| Three-finger tap (or swipe down from the top edge) | Switch mode, open Settings, or Stop |

**Keyboard.** Hold ⌘ and tap C, or tap ⌘ once and it applies to the next key; tap a lit modifier again to cancel it. Keys go out as Mac key codes, so the Mac's keyboard layout decides which character you get, like a real keyboard.

**Trackpad.** One finger moves the pointer, tap to click, two-finger tap to right-click. Tap, then touch again and move to drag. Two fingers scroll, and a flick keeps going. The strip on the right edge scrolls with one finger. Three-finger swipes: left and right switch desktops, up opens Mission Control, down shows the app's windows. Pinch zooms in apps.

**Macro bar.** Choose which shortcuts appear in Settings → Macro bar, and add your own: a name, a key (a character such as `p`, or a name such as `esc`, `f5`, `pageup`) and modifiers.

**Settings.** These are the settings not covered above:
- **Display:** quality, size, start automatically, status bar, clipboard sync.
- **Zoom:** pinch to zoom, and whether the zoom follows the pointer.
- **Overlay:** opacity and height.
- **Trackpad:** speed, natural scrolling, tap to drag, momentum.
- **Touch:** picture mode, edge swipes, low-battery warning.

## Clamshell: the Mac closed, the iPad as the screen

1. Start **Extend**. Mirror shows the Mac's own screen, which turns off when the lid closes.
2. If you'll turn the iPad upright, **Picture on top, keyboard below** keeps the Mac display in landscape, so rotating never rebuilds it. **Turn the Mac display upright** also works with the lid closed, but takes a few seconds.
3. Keep the Mac awake with the lid closed. macOS only stays awake in clamshell when it sees a real external display, so turn sleep off (`0` turns it back on):

   ```bash
   sudo pmset -a disablesleep 1
   ```

   Keep the Mac somewhere it can cool down.
4. When the Mac locks, the picture pauses and Revive offers to type your password. macOS may block typed input at the lock screen. If it does, set a longer delay before the password is required (System Settings → Lock Screen), but only where that's safe.
5. For ⌃← / ⌃→ and Mission Control, turn the shortcuts on in System Settings → Keyboard → Keyboard Shortcuts → Mission Control.

## Video, DRM and audio

**Protected video.** Streaming sites protect their video with DRM, and macOS keeps protected video out of screen capture, so it can show up black on the iPad.
- **Safari and the Apple TV app** stay black, by design.
- **Chrome-based browsers (Chrome, Arc) and Firefox** usually work once you turn off their graphics acceleration (for example `arc://settings/system` → "Use graphics acceleration when available", then relaunch).

Revive only displays the video. It doesn't record it or work around the DRM.

**Audio.** Audio stays on the Mac. Connect AirPods or speakers to the Mac as usual.

## Privacy and security

- **Over the cable,** the stream never leaves the cable between your two devices.
- **Over Wi-Fi it is not encrypted.** The picture, your keystrokes, clipboard text and the lock-screen password travel as plain network traffic, which another device on the same network could capture.
  - Use the cable when you can, especially to unlock.
  - On Wi-Fi, stick to your own network.
- **Wi-Fi connections need your approval.** Connect each device once from the Mac; after that, only devices you've connected before can start a session on their own.

## Troubleshooting

- **"Waiting for your Mac".** No connection has reached the iPad.
  - Check that OpenDisplay is running and is the patched build: `codesign -dv /Applications/OpenDisplay.app` should show `Signature=adhoc`.
  - Check that the cable is plugged in, or that both devices are on the same Wi-Fi.
- **Connected, but no picture.** Screen Recording is missing for this build. Reset it, grant it again, and relaunch. `tail -30 /tmp/opensidecar-mac.log` says "Screen Recording permission missing" when this is the cause.
- **Picture, but no input.** Accessibility is missing. Fix it the same way.
- **Clicks act as right clicks.** This was a stuck ⌃ after shortcuts, fixed by `06-no-stuck-modifiers.patch`. Make sure the Mac app is a current build.
- **⌃← / ⌃→ do nothing.** Turn on the Mission Control shortcuts on the Mac.
- **A brief black frame when you return to the app.** That's the reconnect: iOS suspends the app's networking in the background.
- **Mac logs.** `/tmp/opensidecar-mac.log` records connections, display rebuilds and errors.

Not done yet: forwarding audio to the iPad, a Bluetooth keyboard paired to the iPad, and encrypting Wi-Fi connections.

## Repository layout

| Path | What |
| --- | --- |
| `iOS/App/` | The Revive app: `VideoReceiver.swift` (network, decoding, protocol), `ReceiverViewController.swift` (video, touch, zoom, status), `HomeView.swift` (start screen, controls), `InputPanels.swift` (keyboard, trackpad, macro bar, lock panel), `Settings.swift` |
| `iOS/project.yml` | XcodeGen source for `iOS/LegacyPadDisplay.xcodeproj` (committed, so XcodeGen is optional) |
| `Mac/` | Submodule: unmodified upstream OpenDisplay |
| `patches/` | Revive's changes to OpenDisplay, applied in order at build time |
| `.github/workflows/` | `build-ipa.yml` (iPad app) and `build-mac.yml` (patched Mac app) |

## License and credits

- **The Revive iPad app (`iOS/`) and everything else outside `Mac/` and `patches/`:** MIT, see [LICENSE](LICENSE). Based on the iOS 12 client by cuongpham1. It talks to OpenDisplay over the network and contains no OpenDisplay code.
- **`Mac/`:** [OpenDisplay](https://github.com/peetzweg/opendisplay) by Philip Poloczek, GPL-3.0, included as an unmodified submodule.
- **`patches/` and any Mac app built from them:** a modified OpenDisplay, so GPL-3.0 as well. If you share a built Mac app, share this source with it. See [patches/README.md](patches/README.md).

"iPad", "iPhone" and "Mac" are trademarks of Apple Inc. Revive is an independent project, not affiliated with Apple.

*Keywords: old iPad as Mac display, iOS 12 iPad second monitor, use Mac from iPad in clamshell mode, Sidecar alternative for old iPads, free Duet Display / Luna Display alternative, OpenDisplay iOS 12 client.*
