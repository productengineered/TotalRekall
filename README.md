# Total Rekall

Total Rekall is a small macOS menu bar app (a bear icon) that puts your monitors and windows back where they were after you dock or undock your Mac.

When you connect a laptop to a dock, macOS often swaps two identical monitors, or throws your windows onto the wrong screen or the wrong desktop. Total Rekall saves where your windows were while your desk was connected. When your displays change, it restores that layout.

It does two things:

- **Fixes monitor order swaps.** It detects when two monitors have changed places and swaps them back.
- **Restores windows and desktops.** It moves each window back to its saved position, display, and desktop (Space).

You can also run both yourself from the menu: **Restore Now** and **Fix Monitors**.

## Requirements

- macOS 26 (Tahoe) or later.
- A Mac you dock to one or more external monitors. The app does nothing useful on a display setup that never changes.
- Accessibility permission for the app. Without it, the app cannot move windows.
- To build from source: Xcode 26 or later.

## Install

### Option A: disk image

If you have a `TotalRekall-<version>.dmg` file:

1. Open the `.dmg`.
2. Drag **TotalRekall** onto **Applications**.
3. Open **TotalRekall** from Applications.

Builds are not notarized by Apple. On first open, macOS may block the app. Open **System Settings > Privacy & Security**, find the message about TotalRekall, and click **Open Anyway**. The [user guide](docs/USER_GUIDE.md) has the full steps.

### Option B: build from source

1. Clone this repository.
2. Choose one of these:
   - **Signed with your Apple developer team (recommended).** Copy `app/Config/Local.xcconfig.example` to `app/Config/Local.xcconfig` and put your team ID in it. Then run `scripts/install.sh`.
   - **Ad-hoc signed, no developer account.** Run `scripts/install.sh --adhoc`.
3. The script builds a Release app, copies it to `/Applications/TotalRekall.app`, and opens it.

An ad-hoc build has a different signature every time you build it. macOS may drop the Accessibility permission each time you reinstall, and you will need to grant it again in **System Settings > Privacy & Security > Accessibility**. A build signed with your team ID keeps the permission.

To make a disk image yourself, run `scripts/make-dmg.sh`. It writes `dist/TotalRekall-<version>.dmg`.

You can also open `app/TotalRekall.xcodeproj` in Xcode and run it.

## Why it needs Accessibility

macOS only lets an app move other apps' windows if you give it Accessibility permission. Total Rekall uses it for two things:

- **Reading** the position, size, and state of your windows, so it can save them.
- **Setting** the position and size of your windows, so it can restore them.

It does not read or record what you type, and it does not read the contents of your windows. It does save each window's title and app name in its local layout file, so it can match a window to its saved place.

**Network.** Total Rekall makes no network requests. The code does not use `URLSession`, sockets, or any other networking API, and the app has no update checker, analytics, or crash reporting. Nothing leaves your Mac unless you choose to send a diagnostics file yourself.

The app is not sandboxed. It asks macOS for notification permission so it can tell you when a restore fails.

## Private macOS APIs

Moving a window to another desktop (Space) has no public macOS API. Total Rekall uses private functions from Apple's SkyLight framework to read which Space each window is on and to move windows between Spaces. It also uses one private Accessibility function, `_AXUIElementGetWindow`, to match an Accessibility window to its on-screen window.

What this means for you:

- Apple does not document or support these functions. A macOS update can change or remove them.
- If they stop working, the app falls back to position only: it puts windows back at the right place on the right display, but it cannot move them to the right desktop.
- This code is why the app cannot be distributed through the Mac App Store.

All private API use is in one file: `app/TotalRekall/Services/SpaceBridge.swift`.

## Where your data lives

Everything is in `~/Library/Application Support/TotalRekall`:

- `snapshots.json` and `snapshots.last-good.json`: saved window layouts, including window titles.
- `restore-log.json`: what the last restores did.
- `exports/`: diagnostics zips, if the Desktop could not be used.
- `instance.lock`: stops two copies of the app from running at once.

The folder is readable only by your user account. The app also keeps a few settings (such as whether setup is finished and Launch at Login) in macOS preferences.

**To reset:** quit the app, delete the `TotalRekall` folder above, and open the app again. It starts with no saved layouts. To remove the settings too, run `defaults delete com.productengineered.TotalRekall` in Terminal.

## Export Diagnostics

If something goes wrong, click the bear, then **Export Diagnostics…**. The app writes a zip named `TotalRekall-Diagnostics-YYYY-MM-DD-HHMM.zip` to your Desktop. It contains a short activity log, the last restore log, a summary of the saved layouts, your display list, and the app and macOS versions. Window titles in the restore log are replaced with `[redacted]`. The raw layout file is not included. The app does not upload the zip; you send it yourself.

## User guide

See the [user guide](docs/USER_GUIDE.md) for install steps, setting up Accessibility, what the menu shows, and uninstalling.

## Known limitations

- The monitor swap fix has been tested on one setup: a MacBook Pro with two identical monitors on one dock. Other setups may behave differently.
- Desktop (Space) restore depends on private APIs that macOS updates can break.
- macOS 26 or later only.

## Support

Total Rekall is free. If it saves you some window-dragging and you'd like to say thanks, you can [buy me a coffee](https://www.dynamiccorporateleader.com/offers/LC2KfjsD).

Found a bug or have an idea? [Open an issue](https://github.com/productengineered/TotalRekall/issues).

## License

Not yet chosen.
