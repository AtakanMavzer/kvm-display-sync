# kvm-display-sync

**Fixes the macOS "phantom display" problem with KVM monitors.** When your monitor's
built-in KVM switches to another computer, macOS keeps treating the monitor as a
connected screen. Windows open on a display you can't see, the menu bar and mouse
cursor vanish onto it, and everything shuffles around when you switch back.

`kvm-display-sync` is a tiny background daemon (Swift, zero dependencies, ~10 MB
RAM, 0% idle CPU) that detects the KVM switch through the monitor's USB hub and
fixes the display layout automatically, in both directions.

No BetterDisplay Pro, no DDC tricks, no unplugging cables.

---

## Symptoms this solves

You have a MacBook and a desktop PC (or a second Mac, or a console) sharing one
monitor with a built-in KVM switch over USB-C / Thunderbolt, and:

- After switching the monitor to the PC, **new windows open on the invisible external display**.
- The **menu bar, Dock, or mouse cursor disappears** because they live on the monitor you're not looking at.
- The MacBook **doesn't notice the monitor "left"**. System Settings still shows it as connected.
- When you switch back, **windows are rearranged** or the main display has changed.
- "Disconnecting" the display with a third-party tool leaves the monitor showing
  **"USB-C No Signal"** when you switch back, and it never recovers.

This happens because many USB-C monitors keep the DisplayPort link to the Mac
alive while showing a different input. macOS has no "input switched" event, so it
never learns the screen went dark.

## How it works

macOS may not know the monitor switched inputs, but it does see the monitor's
USB hub disappear the instant the KVM routes USB to the other machine. IOKit
reports that immediately. That is the signal.

```
KVM switches to Mac                 KVM switches to PC
        |                                   |
        v                                   v
monitor's USB device appears     monitor's USB device disappears
        |                                   |
        v                                   v
restore the extended layout      mirror external onto built-in
(monitor back as main, windows   (one logical screen: nothing
 where they were)                 can get lost on the phantom)
```

- **Detection**: `IOServiceAddMatchingNotification` on one USB device that lives
  inside the monitor (by vendor/product ID). Never a keyboard or mouse, so
  unplugging a peripheral doesn't trigger it.
- **Debounce**: two seconds on detach (USB hubs flap while re-enumerating), a
  fraction of a second on attach so the switch-back feels instant.
- **Actuation**: by default, mirror the external display onto the built-in one
  while the KVM is away, and restore the previous arrangement (positions and
  main display) when it comes back. Mirroring keeps the video link alive, which
  matters: see [Why mirror, not disable](#why-mirror-not-disable).
- **Sleep-proof**: the daemon reads the real display state from the system
  rather than remembering what it last did, pauses during sleep, re-checks a
  few seconds after wake, and reconciles every 30 seconds as a safety net. A
  KVM that switches while the Mac is asleep is caught on wake.
- **Recovery**: on stop or crash the daemon restores the display, so it never
  leaves you stranded. `launchd` restarts it automatically.

## Quick start

One line. It builds from source (needs the Xcode Command Line Tools) and runs a
short wizard that finds your display and USB device by watching you switch the
KVM once, then installs a launch agent:

```sh
curl -fsSL https://raw.githubusercontent.com/AtakanMavzer/kvm-display-sync/main/install.sh | sh
```

The wizard takes about a minute. Run it from a terminal on your Mac's built-in
screen and use the built-in keyboard, since your USB keyboard follows the KVM.

```
Step 1/3  Which display does the KVM control?
  Found one external display, using it:
    XG27UCDMG  vendor 1715  model 10230  3840x2160  (main)

Step 2/3  Which USB device follows the KVM?
  Make sure the monitor is currently showing THIS Mac.
  Press Enter when it is:
  Now switch the monitor to the OTHER computer using its KVM / input button.
  Press Enter (on the built-in keyboard) once it has switched:
  Devices that disappeared:
    0x0B05:0x1BFE  ROG Gaming Display Aura Device
    0x0B05:0x1C03  USB2.1 Hub
    ...
  Using: ROG Gaming Display Aura Device
  Switch the monitor back to this Mac.
  Press Enter once it has switched back:
  Confirmed: ROG Gaming Display Aura Device is back.

Step 3/3  Install
  ...
Done. The daemon is running and will start at login.
```

Afterwards:

```sh
~/.local/bin/kvm-display-sync status      # what it sees and whether the display is in sync
~/.local/bin/kvm-display-sync uninstall   # unload and remove everything
```

After the first login, macOS may show a "background item added" notice. Leave
it allowed under System Settings > General > Login Items & Extensions.

### Manual install

If you'd rather not run a script, or want to pass options yourself:

```sh
git clone https://github.com/AtakanMavzer/kvm-display-sync.git
cd kvm-display-sync
swift build -c release
.build/release/kvm-display-sync setup              # same wizard
```

or skip the wizard entirely:

```sh
.build/release/kvm-display-sync usb        # with the KVM on the Mac, then again after switching away
.build/release/kvm-display-sync displays   # EDID vendor/model of your monitor
.build/release/kvm-display-sync install \
    --usb-vendor 0x0B05 --usb-product 0x1BFE \
    --display-vendor 1715 --display-model 10230
```

`install` copies the binary to `~/.local/bin`, writes
`~/Library/LaunchAgents/io.github.kvm-display-sync.plist`, and loads it. It
starts at login and survives reboots. Logs go to
`~/Library/Logs/kvm-display-sync.log`.

## Commands

| command       | what it does |
|---------------|--------------|
| `setup`       | Interactive first run: detects display and USB device, then installs |
| `watch`       | Run in the foreground (this is what the launch agent runs) |
| `status`      | Show USB presence, display state, and whether they agree |
| `displays`    | List displays with EDID vendor/model, main/active flags, and bounds |
| `usb`         | List USB devices in the IORegistry with vendor:product IDs |
| `test off`    | Run the actuator's disconnect step once |
| `test on`     | Run the actuator's connect step once |
| `install`     | Install and load the launch agent with the given options |
| `uninstall`   | Unload and remove the launch agent and binary |

## Options

```
--usb-vendor <id>       USB vendor ID to watch (default 0x0B05, ASUS)
--usb-product <id>      USB product ID to watch (default 0x1BFE, ROG Gaming Display Aura Device)
--display-vendor <n>    EDID vendor of the display to manage (default 1715)
--display-model <n>     EDID model of the display to manage (default 10230)
--any-external          Manage the first non-builtin display instead of matching vendor/model
--display-name <name>   Display name for the betterdisplay actuator (default XG27UCDMG)
--actuator <kind>       mirror | disable | command | betterdisplay (default mirror)
--on-connect <cmd>      Shell command for the command actuator (KVM back on Mac)
--on-disconnect <cmd>   Shell command for the command actuator (KVM away)
--debounce <seconds>    Wait after the hub disappears before disconnecting (default 2.0)
--connect-debounce <s>  Wait after the hub appears before reconnecting (default 0.3)
--reconcile <seconds>   Re-check USB vs display state this often; 0 disables (default 30)
--no-initial-sync       Don't apply the current state at startup
--verbose, -v           Debug logging
```

Options given to `install` are baked into the launch agent. Re-run `install` to
change them.

## Actuators

| actuator        | mechanism                                   | when to use |
|-----------------|---------------------------------------------|-------------|
| `mirror`        | public `CGConfigureDisplayMirrorOfDisplay`  | default; any Mac with a built-in display |
| `disable`       | private `CGSConfigureDisplayEnabled`        | removes the display entirely; only if your monitor routes USB regardless of video |
| `command`       | your own shell commands                     | Mac mini / Mac Studio, or any tool you prefer |
| `betterdisplay` | BetterDisplay's CLI `--connected=on/off`     | if you own BetterDisplay Pro |

`mirror` and `disable` both record the arrangement before acting and restore it
afterwards, so the monitor comes back as main (or not) exactly as it was.

### Why mirror, not disable

Truly disabling the display is the cleaner result, and it works on current
macOS. But it also drops the DisplayPort output, and many KVM monitors will not
route their USB hub to an input that has no video. Switch back and the monitor
shows "USB-C No Signal", the Mac never sees the hub, and nothing wakes the
display up again. Mirroring keeps a signal on the wire, so the switch-back is
always detected. The cost is a brief flash of the mirrored laptop screen when
you switch back, gone in a fraction of a second.

## Compatibility

Tested on a MacBook Pro (Apple Silicon, macOS 26) with an ASUS ROG Swift
XG27UCDMG over USB-C, with a Windows desktop on DisplayPort.

It should work with any monitor whose KVM exposes a USB device of its own
(a hub, an OSD control device, an RGB/lighting controller) that appears and
disappears with the switch. That covers most KVM monitors from ASUS, Dell,
LG, Samsung, Gigabyte, and BenQ. Run `usb` before and after a switch to
confirm and to get the IDs.

Known limits:

- **No built-in display** (Mac mini, Mac Studio): `mirror` has nothing to
  mirror onto. Use `disable` if your monitor routes USB independently of video,
  or `command` with a tool of your choice.
- **Monitors that drop the DisplayPort link on switch**: macOS removes the
  display itself and there is nothing to fix. The daemon notices and stays
  quiet.
- **Sleep/wake and monitor power cycles** also make the hub vanish and return.
  The debounce absorbs the flap; a genuine state change still gets applied.

## Troubleshooting

- `status` says the USB device is absent while the KVM is on the Mac: your
  monitor's KVM setting may route USB to the other upstream port for this
  input. Check the monitor's OSD KVM assignment.
- Display didn't come back after `test off` with the `disable` actuator: turn
  the monitor off and on, or run `test on`. Then use `mirror`.
- Watch the daemon live: `tail -f ~/Library/Logs/kvm-display-sync.log`.

## License

MIT. See [LICENSE](LICENSE).
