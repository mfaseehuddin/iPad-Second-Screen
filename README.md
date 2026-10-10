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
- **Pinch to zoom.** Zoom into part of the Mac screen on the iPad. The zoom follows the Mac pointer.
- **Mac trackpad gestures.** Three-finger swipes switch desktops, open Mission Control and show an app's windows; pinch zooms in apps.
- **Clipboard sync.** Copy text on one device, paste it on the other.
- **Status bar.** The Mac's battery, the round-trip latency, and frames per second.
- **Your own macros.** Add any shortcut, such as ⌘⇧P, with a name.
- **Settings.** Quality, display size, start automatically, overlay opacity and height, trackpad speed, scroll direction, tap-to-click on the picture, and the macro list.
- **Cable or Wi-Fi.** The Mac prefers the cable (lower, steadier latency) and falls back to Wi-Fi when you unplug it.

## How it works

Two apps, one on each side:

- **Mac: [OpenDisplay](https://github.com/peetzweg/opendisplay)** with two small patches. OpenDisplay creates the virtual display, captures it, encodes H.264, and sends it to the device over USB (`usbmuxd`) or Wi-Fi (Bonjour). It also turns the device's input into mouse and keyboard events. OpenDisplay's own iPad app needs iPadOS 17, which is why this project exists.
- **iPad: `LegacyPadDisplay`** (`iOS/`), a clean-room iOS 12 client of OpenDisplay's protocol. It listens on port 9000, decodes the video, draws the Mac's cursor, and sends touch, keyboard and trackpad input back.

The patches (`patches/`, details in [patches/README.md](patches/README.md)) add what the iPad needs to be in charge:

| Message | Effect |
| --- | --- |
| `hello` with `mode` and `quality` | Start in `extend` or `mirror` at `best`, `balanced` or `fast` quality, whatever the Mac's own pickers say. The iPad sends `hello` only after you tap a mode. |
| `standby` | Stop: the Mac removes the display and dials the iPad again, ready for the next tap. |
| `key`, `text`, `mouse` | Keyboard, typed text and trackpad input. |
| `subscribe`, `clipboard`, `macStatus` | Opt-in clipboard sync (both ways, text only) and the Mac's battery status. |
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
| Tap / drag on the picture | Click / drag there, or move the pointer like a trackpad (see *Picture touch* below) |
| Two-finger drag on the picture | Scroll |
| Pinch the picture / two-finger double-tap | Zoom in on the iPad / zoom back out |
| Arrow, bottom-right corner | Open the keyboard and trackpad overlay |
| ⌄ in the macro bar | Close the overlay |
| Three-finger tap | Switch mode, open Settings, or **Stop** (back to the start screen) |

**Keyboard.** Modifiers work two ways. You can hold ⌘ while tapping C. Or tap ⌘ once, and it lights up for the next key only. Tap a lit modifier again to cancel it. Delete, space and the arrow keys repeat while held. Keys are sent as Mac key codes, so the Mac's keyboard layout decides which character you get, just like a real keyboard.

**Trackpad.** One finger moves the pointer, with acceleration. Tap to click, two-finger tap to right-click, two-finger drag to scroll. To drag, hold **L** and move with another finger. There's a second pair of **L** / **R** buttons at the left end of the macro bar, so your left thumb can click while your right hand is on the trackpad.

**Keyboard and Trackpad switches.** The macro bar's **Keyboard** and **Trackpad** buttons show or hide each panel. With only the trackpad, the overlay shrinks to a short bar. With neither, only the macro bar is left.

**Picture touch.** Settings → Touch → Picture:
- **Click:** tap where you want to click.
- **Trackpad:** drag anywhere on the picture to move the pointer, tap to click, two-finger tap to right-click, three-finger swipe for desktops and Mission Control.
- **Auto** (default): Trackpad while the overlay is open with its trackpad switched off, Click otherwise.
- **Off:** touches on the picture do nothing.

Two-finger scroll and pinch-to-zoom work in every mode.

**Tap to drag.** On the trackpad, or on the picture in Trackpad mode: tap, then touch again and move to drag, like macOS's "tap to drag". Lift to drop.

**Momentum scrolling.** Flick to scroll (two fingers, or the scroll strip), and the page keeps going and slows to a stop. Touch again to stop it.

**Edge swipes.** Swipe in from the left edge to open the keyboard and trackpad, or down from the top edge for the controls. Touches that start right at those edges never click on the Mac.

**Lock screen.** When the Mac locks, the picture pauses and the iPad says so. Type your Mac password there to unlock it, or tap **Wake display**. The password is typed as key presses and never stored. macOS may block typed input at the lock screen; if Unlock does nothing, that's why.

**Scrolling without gestures.** Slide one finger along the strip at the trackpad's right edge, or hold **▲** / **▼** in the macro bar. Holding scrolls faster the longer you hold.

**Status bar.** Shows the Mac's and the iPad's battery, latency, and fps. It says *idle* when the Mac screen is still, because the Mac only sends frames when something changes. It turns red when either battery is at 15% or less and not charging, even if the status bar is switched off. You can turn the warning off in Settings.

**Trackpad gestures.** Three-finger swipe left or right switches desktops (⌃→ / ⌃←), swipe up opens Mission Control, swipe down shows the app's windows. Pinch on the trackpad zooms in apps (⌘+ / ⌘−).

**Your own macros.** Settings → Macro bar → Add macro. Give it a key (a character such as `p`, or a name such as `esc`, `f5`, `pageup`) and modifiers. It shows up in the macro bar. Swipe left on it in Settings to delete it.

**Display settings.** *Quality* trades sharpness for latency (Fast is good over Wi-Fi). *Size* changes how big the Mac's interface looks in Extend mode: Larger text, Default or More space. Changing either restarts the picture for a moment. *Start automatically* starts your last mode when the app opens. *Sync clipboard* sends copied text both ways while streaming.

**Upright iPad.** Settings → When the iPad is upright:
- **Picture on top, keyboard below** (default): the Mac display stays landscape at the top, with the keyboard and trackpad docked under it.
- **Turn the Mac display upright:** the Mac rebuilds the display in portrait to fill the screen (Extend mode only). Windows on it may move.
- **Stay in landscape:** the app doesn't rotate.

## Clamshell: run the Mac with the lid closed

Use **Extend**, not Mirror. Mirror shows the Mac's own screen, and that screen turns off when the lid closes. In Extend, the iPad's display becomes the main display once the built-in one goes away.

1. Start **Extend** and check that the keyboard and trackpad work. If you'll turn the iPad upright, pick **Picture on top, keyboard below** in Settings. It keeps the Mac display in landscape, so rotating never rebuilds the Mac's only screen. "Turn the Mac display upright" also works with the lid closed: the Mac builds the new display before removing the old one, but it takes a few seconds.
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
