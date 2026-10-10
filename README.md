# iPad Second Screen

Use an old iPad stuck on iOS 12 as a display, keyboard and trackpad for your Mac, over a Lightning cable or Wi-Fi. Free, and self-hosted: nothing leaves your desk.

Extend your desktop onto the iPad or mirror the Mac's screen, chosen and started from the iPad. With the on-screen keyboard and trackpad, the iPad can stand in for the whole Mac with the lid closed.

Tested on an iPad Air (A1475, iOS 12.5.8) with a Mac on macOS 26. An iPhone on iOS 12 or later works too, but the screen is small.

## What you get

- **Extend or Mirror, from the iPad.** A start screen shows the connection (Cable or Wi-Fi) and two tiles. Tap one and the Mac sets the display up.
- **Touch.** Tap the picture to click there, drag to drag, and use two fingers to scroll.
- **See-through keyboard and trackpad.** A small arrow in the bottom-right corner opens an overlay: a full Mac keyboard on the left three quarters, a trackpad on the right quarter, and a macro bar above both.
- **Macros.** One-tap shortcuts such as ⌃C, ⌃← / ⌃→ (switch desktops), Mission Control, ⌘Tab and Spotlight. Pick which ones appear in Settings.
- **Portrait your way.** Hold the iPad upright for a Game Boy layout (the picture on top, keyboard and trackpad docked below), turn the Mac display upright to fill the screen, or stay in landscape.
- **Settings.** Overlay opacity and height, trackpad speed, scroll direction, tap-to-click on the picture, and the macro list.
- **Cable or Wi-Fi.** The Mac prefers the cable (lower, steadier latency) and falls back to Wi-Fi when you unplug it.

## How it works

Two apps, one on each side:

- **Mac: [OpenDisplay](https://github.com/peetzweg/opendisplay)** with two small patches. OpenDisplay creates the virtual display, captures it, encodes H.264, and sends it to the device over USB (`usbmuxd`) or Wi-Fi (Bonjour). It also turns the device's input into mouse and keyboard events. OpenDisplay's own iPad app needs iPadOS 17, which is why this project exists.
- **iPad: `LegacyPadDisplay`** (`iOS/`), a clean-room iOS 12 client of OpenDisplay's protocol. It listens on port 9000, decodes the video, draws the Mac's cursor, and sends touch, keyboard and trackpad input back.

The patches (`patches/`, details in [patches/README.md](patches/README.md)) add what the iPad needs to be in charge:

| Message (iPad → Mac) | Effect |
| --- | --- |
| `hello` with `mode` | Start in `extend` or `mirror`, whatever the Mac's own picker says. The iPad sends `hello` only after you tap a mode. |
| `standby` | Stop: the Mac removes the display and dials the iPad again, ready for the next tap. |
| `key`, `text`, `mouse` | Keyboard, typed text and trackpad input. |
| Bonjour TXT `gate=1` | A Wi-Fi iPad you've connected once can start a session at any time. |

Devices you have never connected from the Mac still need one click there first. Another iPad on the same Wi-Fi can't start mirroring your screen.

## 1. Get the code

```bash
git clone --recurse-submodules https://github.com/mfaseehuddin/iPad-Second-Screen.git
cd iPad-Second-Screen
```

`Mac/` is a submodule of unmodified upstream OpenDisplay. If you cloned without `--recurse-submodules`, run `git submodule update --init --recursive`.

## 2. Install the Mac app

You need the patched build. Upstream's prebuilt app still shows the picture, but it ignores the iPad's mode choice, keyboard and trackpad.

**Built on GitHub (no Xcode needed):**

1. In your fork's **Actions** tab, run **Build Mac app**. It also runs on every push that changes `patches/`.
2. Download the `OpenDisplay-patched-mac` artifact and unzip it.
3. Install it and clear the download quarantine. The build is ad-hoc signed, with no Apple certificate.

   ```bash
   osascript -e 'quit app "OpenDisplay"'
   rm -rf /Applications/OpenDisplay.app
   cp -R ~/Downloads/OpenDisplay.app /Applications/
   xattr -dr com.apple.quarantine /Applications/OpenDisplay.app
   ```

**From source:** apply the patches, generate the project, and run scheme **OpenSidecarMac** in Xcode:

```bash
for p in patches/*.patch; do git -C Mac apply "../$p"; done
cd Mac && xcodegen generate && open OpenSidecar.xcodeproj
```

**Permissions.** OpenDisplay needs **Screen Recording** (for the picture) and **Accessibility** (for input). Grant both in System Settings → Privacy & Security, then quit with ⌘Q and reopen the app. Flipping the switches is not enough.

macOS ties these permissions to the app's signature, and every new build is signed differently. After installing a new build, reset both and grant them again:

```bash
tccutil reset ScreenCapture com.peetzweg.opensidecar.mac
tccutil reset Accessibility com.peetzweg.opensidecar.mac
```

**Turn off auto-update.** OpenDisplay updates itself with Sparkle. Accepting an update would replace the patched build with upstream's. Turn off the checks:

```bash
defaults write com.peetzweg.opensidecar.mac SUEnableAutomaticChecks -bool NO
```

## 3. Install the iPad app

The **Build unsigned IPA** workflow builds the app on every push that changes `iOS/`. Download the `LegacyPadDisplay-ipa` artifact. It contains two files:

- `LegacyPadDisplay-fakesigned.ipa`: for **jailbroken** devices with AppSync Unified. It never expires.
- `LegacyPadDisplay.ipa`: unsigned, for **Sideloadly** with a free Apple ID. It expires after 7 days.

**Jailbroken (AppSync Unified):** install over the cable with libimobiledevice:

```bash
brew install libimobiledevice ideviceinstaller
ideviceinstaller -i LegacyPadDisplay-fakesigned.ipa
```

Or install over SSH. This needs OpenSSH and `appinst` from Cydia or Sileo:

```bash
scp LegacyPadDisplay-fakesigned.ipa root@<ipad-ip>:/var/mobile/
ssh root@<ipad-ip> 'appinst /var/mobile/LegacyPadDisplay-fakesigned.ipa && uicache -a'
```

**Not jailbroken:** open [Sideloadly](https://sideloadly.io), plug the iPad in, drop `LegacyPadDisplay.ipa` in, and sign in with your Apple ID. On the iPad, trust the certificate under Settings → General → VPN & Device Management. With a free Apple ID the app stops opening after 7 days; run Sideloadly again to refresh it.

**With Xcode:** open `iOS/LegacyPadDisplay.xcodeproj`, set your Team under Signing & Capabilities, pick the iPad and press Run. Recent Xcode versions can't install to iOS 12 without its DeviceSupport files. Without them, the iPad doesn't show up as a destination, or Xcode reports "Failed to prepare the device for development". Copy the files in once:

```bash
curl -L -o /tmp/12.5.zip https://raw.githubusercontent.com/apptim/iPhoneOSDeviceSupport/master/12.5.zip
unzip -o /tmp/12.5.zip -d /tmp/ds125
cp -R /tmp/ds125/12.5 ~/Library/Developer/Xcode/iOS\ DeviceSupport/
```

`iOS/project.yml` is the XcodeGen source for the project. Run `xcodegen generate` after you edit it.

## 4. Use it

1. Open OpenDisplay on the Mac and LegacyPadDisplay on the iPad.
2. Plug in the cable, or use the same Wi-Fi. Over Wi-Fi, connect the iPad once from OpenDisplay's device list, and allow **Local Network** on the iPad if asked. The status changes to **Mac connected · Cable** or **Wi-Fi**.
3. Tap **Extend** or **Mirror**. You can also tap a mode before the Mac connects, and it starts as soon as the Mac connects.

While streaming:

| Do this | To |
| --- | --- |
| Tap / drag on the picture | Click / drag there (turn off in Settings for trackpad-only use) |
| Two-finger drag on the picture | Scroll |
| Arrow, bottom-right corner | Open the keyboard and trackpad overlay |
| ⌄ in the macro bar | Close the overlay |
| Three-finger tap | Switch mode, open Settings, or **Stop** (back to the start screen) |

**Keyboard.** Modifiers work two ways. You can hold ⌘ while tapping C. Or tap ⌘ once, and it lights up for the next key only. Tap a lit modifier again to cancel it. Delete, space and the arrow keys repeat while held. Keys are sent as Mac key codes, so the Mac's keyboard layout decides which character you get, just like a real keyboard.

**Trackpad.** One finger moves the pointer, with acceleration. Tap to click, two-finger tap to right-click, two-finger drag to scroll. To drag, hold **L** and move with another finger. There's a second pair of **L** / **R** buttons at the left end of the macro bar, so your left thumb can click while your right hand is on the trackpad.

**Upright iPad.** Settings → When the iPad is upright:
- **Picture on top, keyboard below** (default): the Mac display stays landscape at the top, with the keyboard and trackpad docked under it.
- **Turn the Mac display upright:** the Mac rebuilds the display in portrait to fill the screen (Extend mode only). Windows on it may move.
- **Stay in landscape:** the app doesn't rotate.

## Clamshell: run the Mac with the lid closed

Use **Extend**, not Mirror. Mirror shows the Mac's own screen, and that screen turns off when the lid closes. In Extend, the iPad's display becomes the main display once the built-in one goes away.

1. Start **Extend** and check that the keyboard and trackpad work.
2. In Settings on the iPad, turn off **Tap the picture to click** if you'll drive the Mac only with the trackpad.
3. Keep the Mac awake with the lid closed. macOS only stays awake in clamshell when it detects a real external display, and a virtual one may not count. To be sure, turn sleep off (and turn it back on with `0` when you're done):

   ```bash
   sudo pmset -a disablesleep 1
   ```

   Keep the Mac somewhere it can cool. It won't sleep in a bag.
4. Keep the Mac from locking. ScreenCaptureKit stops capturing at the lock screen, so the picture freezes until the Mac is unlocked. Set System Settings → Lock Screen → "Require password after screen saver begins or display is turned off" to a long delay or Never, and keep the display from turning off on power. That's a security trade-off, so only do it where it's safe.
5. For ⌃← / ⌃→ and Mission Control, the shortcuts must be enabled in System Settings → Keyboard → Keyboard Shortcuts → Mission Control.

## Troubleshooting

- **The iPad says "Waiting for your Mac".** No connection has reached it. Check that OpenDisplay is running and is the patched build: `codesign -dv /Applications/OpenDisplay.app` should say `Signature=adhoc`. Check that the cable is plugged in, or that both devices are on the same Wi-Fi.
- **Connected, but no picture.** Screen Recording is missing for this build. Reset it with `tccutil`, grant it again, and relaunch the app (step 2). OpenDisplay's log, `tail -30 /tmp/opensidecar-mac.log`, says "Screen Recording permission missing" when this is the cause.
- **Picture but no input.** Accessibility is missing. Fix it the same way.
- **⌃← / ⌃→ do nothing.** Enable the Mission Control shortcuts on the Mac (clamshell step 5).
- **A brief black frame when you return to the app.** That's the reconnect: iOS suspends the listener in the background, and the app restarts it when it comes back.
- **`updateRequired` from the Mac.** A newer OpenDisplay raised its minimum protocol version. The iPad app speaks protocol 1, which the patched version (v1.13.0) accepts.

Not done yet: a hardware (Bluetooth) keyboard on the iPad.

## Repository layout

| Path | What |
| --- | --- |
| `iOS/App/` | The iPad app: `VideoReceiver.swift` (network, decoding, protocol), `ReceiverViewController.swift` (video, touch), `HomeView.swift` (start screen, controls), `InputPanels.swift` (keyboard, trackpad, macros), `Settings.swift` |
| `iOS/project.yml` | XcodeGen source for `iOS/LegacyPadDisplay.xcodeproj` (committed, so XcodeGen is optional) |
| `Mac/` | Submodule: unmodified upstream OpenDisplay |
| `patches/` | The Mac-side changes, applied in order at build time |
| `.github/workflows/` | `build-ipa.yml` (iPad app) and `build-mac.yml` (patched Mac app) |

## License

- **iPad app (`iOS/`) and everything else in this repository outside `Mac/` and `patches/`:** MIT, see [LICENSE](LICENSE). It talks to OpenDisplay over the network and contains no OpenDisplay code.
- **`Mac/`:** [OpenDisplay](https://github.com/peetzweg/opendisplay), GPL-3.0, Copyright (c) 2026 Philip Poloczek. Included as an unmodified submodule.
- **`patches/` and any Mac app built from them:** a modified OpenDisplay, so GPL-3.0 as well. If you share a built Mac app, share this source with it. See [patches/README.md](patches/README.md).

*Keywords: iPad iOS 12 second monitor for Mac, old iPad as external display, Sidecar alternative for iOS 12, free Duet Display / Luna Display alternative, OpenDisplay iOS 12 client, use Mac from iPad in clamshell mode, LegacyPadDisplay.*
