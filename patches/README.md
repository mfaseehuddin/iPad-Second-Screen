# Patches to OpenDisplay

`Mac/` is an unmodified submodule of [OpenDisplay](https://github.com/peetzweg/opendisplay) (GPL-3.0, Copyright (c) 2026 Philip Poloczek). The Mac app this project uses is OpenDisplay with these patches applied, in order:

| Patch | What it changes |
| --- | --- |
| `01-ipad-chooses-mode.patch` | `hello` may carry `mode` (`extend` / `mirror`), which overrides the Mac's Mode picker for that device. The new `standby` message ends the session, and the Mac dials again so the device can start the next one. Remembered Wi-Fi devices advertising `gate=1` are dialed at any time. |
| `02-keyboard-trackpad.patch` | New `key`, `text` and `mouse` messages, injected with the existing Accessibility permission. Input also works in Mirror mode. |
| `03-quality-clipboard-status.patch` | `hello` may carry `quality` (`best` / `balanced` / `fast`). A receiver that sends `subscribe` gets two-way clipboard sync (`clipboard` messages, text only) and/or a `macStatus` message with battery and power every 15 s. |
| `04-greedy-connection.patch` | Keeps the session alive with the lid closed. When the device rotates, the new display is built before the old one is removed, so the Mac always has a screen. Failed rebuilds retry on the same connection, and a device that's still reachable is dialed again when its session ends or fails to start. |
| `05-lock-state.patch` | Tells receivers that subscribe to status when the Mac locks or unlocks (`macLock`, and `locked` in `macStatus`). The picture pauses on the lock screen, so the receiver can explain why and offer to type the password. |

Apply them yourself with:

```bash
for p in patches/*.patch; do git -C Mac apply "../$p"; done
```

## License

These patches modify GPL-3.0 code, so they are licensed under the [GNU General Public License v3.0](../Mac/LICENSE), the same as OpenDisplay. Any Mac app built from them is a modified OpenDisplay and is also GPL-3.0: if you share the built app, share this source with it. The rest of this repository (the iOS app) is MIT; see [LICENSE](../LICENSE).
