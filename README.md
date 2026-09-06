# kvm-display-sync

Keeps macOS's display layout in sync with a monitor's built-in KVM switch.

## The problem

Monitors with a KVM (here an ASUS ROG XG27UCDMG) route their USB hub to whichever
computer is selected. When the monitor switches to the desktop PC, the Mac's
USB-C DisplayPort link stays alive, so macOS keeps rendering to a screen you can
no longer see. Windows and the cursor get lost on a phantom display.

macOS has no "KVM switched" event. But it does see the monitor's USB hub vanish,
immediately, through IOKit. That is a clean, reliable signal.

```
KVM -> Mac            KVM -> PC
  |                     |
  v                     v
USB hub appears     USB hub disappears
  |                     |
  v                     v
enable display      disable display
```

## How it works

- `USBWatcher` registers `IOServiceAddMatchingNotification` for one specific USB
  device (default: the "ROG Gaming Display Aura Device", `0x0B05:0x1BFE`, which
  lives inside the monitor and is never confused with a keyboard or mouse).
- `Daemon` debounces events (two seconds on detach, a fraction of a second on
  attach so the mirrored image is barely visible), re-queries the registry, and
  acts only on real transitions. Failed actions retry a few times with a delay
  (needed on switch-back, when the DP link can renegotiate after USB comes up).
- An `Actuator` does the display work. Four are available:

| actuator        | mechanism                                            | notes |
|-----------------|------------------------------------------------------|-------|
| `mirror`        | public `CGConfigureDisplayMirrorOfDisplay`           | default; mirrors external onto built-in, keeps the video link alive |
| `disable`       | private `CGSConfigureDisplayEnabled`                 | removes the display entirely; see the trap below |
| `command`       | your own `--on-connect` / `--on-disconnect` shell    | anything |
| `betterdisplay` | BetterDisplay's CLI `set --connected=on/off`         | needs BetterDisplay Pro |

Both `mirror` and `disable` record the arrangement (positions and which display
is main) before acting and restore it on reconnect, so the layout comes back
exactly as it was instead of macOS's default placement.

On SIGTERM the daemon reconnects the display if it had disconnected it, so
stopping the agent never leaves the screen stranded.

### Why mirror is the default, not disable

`disable` works on macOS 26 and is the cleaner result: the display is gone.
But it also drops the DisplayPort output. On the XG27UCDMG that is a trap:
when the KVM switches back to the Mac the monitor sees "USB-C no signal",
never routes its USB hub to the Mac, and the daemon never gets the event that
would re-enable the display. `mirror` keeps a signal on the wire, so the
switch-back is always detected. Use `disable` only if your monitor routes USB
independently of video.

## Build

```
swift build -c release
.build/release/kvm-display-sync status
```

## Find your IDs

```
kvm-display-sync usb        # USB vendor:product IDs currently in the registry
kvm-display-sync displays   # EDID vendor/model of each display
```

Run `usb` once with the KVM on the Mac and once with it away; the device that
disappears and belongs to the monitor is your `--usb-vendor` / `--usb-product`.

## Test the actuator before installing

```
kvm-display-sync test off    # display should drop out of the layout
kvm-display-sync test on     # and come back
```

If `test on` cannot bring it back, turn the monitor off and on again (or replug).

## Install as a launch agent

```
kvm-display-sync install                       # defaults: XG27UCDMG, mirror actuator
kvm-display-sync install --actuator disable    # or any other option set
kvm-display-sync uninstall
```

`install` copies the binary to `~/.local/bin/kvm-display-sync`, writes
`~/Library/LaunchAgents/com.atakan.kvm-display-sync.plist`, and loads it.
Logs go to `~/Library/Logs/kvm-display-sync.log`.

## Options

```
--usb-vendor <id>       USB vendor ID to watch (default 0x0B05)
--usb-product <id>      USB product ID to watch (default 0x1BFE)
--display-vendor <n>    EDID vendor of the display to manage (default 1715)
--display-model <n>     EDID model of the display to manage (default 10230)
--any-external          Manage the first non-builtin display instead
--display-name <name>   Name for the betterdisplay actuator (default XG27UCDMG)
--actuator <kind>       mirror | disable | command | betterdisplay
--on-connect <cmd>      Shell command for the command actuator
--on-disconnect <cmd>   Shell command for the command actuator
--debounce <seconds>    Wait after the hub disappears before disconnecting (default 2.0)
--connect-debounce <s>  Wait after the hub appears before reconnecting (default 0.3)
--no-initial-sync       Don't apply the current state at startup
--verbose, -v           Debug logging
```

## Caveats

- `disable` relies on an undocumented CoreGraphics call and, on this monitor,
  breaks switch-back detection (see above). It stays available for hardware
  where it works.
- Sleep/wake and monitor power cycles also make the hub vanish and return.
  The debounce absorbs the flap; a real state change still gets applied.
- Monitor power-off and cable unplug look identical to a KVM switch. The
  desired action is the same, so this is by design.
