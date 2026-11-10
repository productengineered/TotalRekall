# TotalRekall: User Guide

This page tells you how to install TotalRekall, switch it on, tell whether it is working, and export diagnostics if it is not.

The macOS security prompts described below can change between macOS versions. If your screen does not match, follow what macOS shows you.

## What TotalRekall does

TotalRekall is a small menu bar app (a bear icon). When you dock or undock your Mac, macOS often throws your windows onto the wrong screen or the wrong desktop. TotalRekall remembers where your windows were while your desk was connected, and puts them back when your displays change.

## Requirements

- macOS 26 or later.
- A Mac you can dock to one or more external monitors. The app does nothing useful on a single, never-changing display.
- Permission to turn on Accessibility for the app (explained below). Without it, the app cannot move windows.

## Install A: the disk image (recommended)

You need a disk image file named like `TotalRekall-1.0.dmg`. You can build one with `scripts/make-dmg.sh`.

1. Double-click the `.dmg` file. A window named **TotalRekall** opens.
2. Drag **TotalRekall** onto the **Applications** folder shown in that window.
3. Close the window. In Finder, eject **TotalRekall** from the sidebar (click the eject button next to it).
4. Open **Applications** and double-click **TotalRekall**.
5. If macOS refuses to open it, that is because the app is not notarized by Apple.
   1. Click **Done** (or **OK**) on the message. Do not move the app to the Trash.
   2. Open **System Settings > Privacy & Security**.
   3. Scroll down to the message about **TotalRekall** being blocked. Click **Open Anyway**.
   4. Enter your Mac password if asked, then click **Open** when macOS asks again.
6. The setup window opens. Continue with "Switch on Accessibility" below.

### Updating to a new build

If a build is signed differently from the one you had before (for example, an ad-hoc build), macOS treats it as a different app. After you install a new build, Accessibility is probably switched off for it and the app will show a warning.

After you reinstall, or update from an older build, macOS may switch off TotalRekall's Accessibility permission: open System Settings > Privacy & Security > Accessibility, switch **TotalRekall** back on (or remove it with the minus button and add it again), then use **Relaunch** in the app.

1. Quit the old app: click the bear, then **Quit TotalRekall**.
2. Drag the new **TotalRekall** onto **Applications**. Click **Replace** when asked.
3. Open it. The first-open block in step 5 above may appear again.
4. If the setup window asks for Accessibility again, follow "Switch on Accessibility" below. If TotalRekall is already in the list and looks switched on but the app still complains, switch it off and on again in the list, then use **Relaunch** (see below).

## Install B: build it yourself

Do this if you have Xcode and a copy of the source.

1. Install Xcode (from the App Store) and open it once so it finishes setup.
2. In Terminal, go to the project folder. To sign with your Apple developer team, copy `app/Config/Local.xcconfig.example` to `app/Config/Local.xcconfig`, put your team ID in it, and run `scripts/install.sh`. To build without a developer account, run `scripts/install.sh --adhoc`.
3. The script builds the app, copies it to `/Applications/TotalRekall.app`, and opens it.
4. With `--adhoc`, the script prints a warning that the Accessibility permission may be lost on every reinstall. That is expected. Switch it on again as described below each time you reinstall. A build signed with your team ID normally keeps the permission.

## Switch on Accessibility

Accessibility is the macOS permission that lets an app move other apps' windows. TotalRekall asks for nothing else for its main job. It makes no network requests.

1. When you first open the app, a window titled **Let TotalRekall arrange your windows** appears.
2. Click **Open System Settings**. This opens System Settings > Privacy & Security > Accessibility.
3. In the list, switch on **TotalRekall**. Enter your password if asked.
4. Go back to the setup window. It updates by itself and changes to **You're all set**. Click **Done**.

If the setup window instead says **Already granted? Relaunch to finish enabling**, macOS has not yet told the app about the permission. Click **Relaunch**. The app quits and opens again.

If you close the setup window and want it back: click the bear, then **Accessibility access needed**. The line **Already granted? Relaunch to Finish Enabling** sits just below it.

If you later switch Accessibility off, the window comes back with **TotalRekall needs Accessibility again**. Click **Open System Settings** to turn it on, or **Not Now** to leave it off. While it is off, your windows will not move back.

## What normal looks like

- A **bear icon** in the menu bar. While the app is restoring windows, the bear animates (it stays still if you have Reduce Motion turned on).
- Click the bear. The top line tells you what the app is doing. Normal lines are:
  - `Watching your desk · last snapshot 4 min. ago`
  - `Watching your desk · no snapshot yet` (right after the first start)
  - `Restoring windows…`
  - `Paused — display change in progress`, `Paused — desk monitors not connected`, `Paused — monitor layout not verified`. These are not errors. The app waits so it does not save a wrong layout.
- Under it, a **Last restore** line, for example `Last restore: 7 of 7 windows, 2:35 PM`. Hover over it to open a small list showing what triggered the restore and what happened to each app. Before the first restore it says `No restore yet`.
- Other menu items: **Save Snapshot Now**, **Restore Now**, **Fix Monitors**, **Reveal Restore Log**, **Export Diagnostics…**, **Launch at Login**, **Quit TotalRekall**.

Nothing else needs doing. Dock and undock as usual.

## The attention badge and notifications

**The badge.** If the bear shows a warning badge, the last restore did not fully work. The menu top line says `Needs attention — see Last restore`. Hover over **Last restore** to see which apps failed. If the Accessibility permission is missing, the icon is a warning triangle instead and the top line says `Accessibility access needed`.

**The notification.** When an automatic restore (after a display change, after waking the Mac, or at app start) goes wrong, macOS shows a notification titled **TotalRekall**. The first time, macOS asks whether the app may send notifications; allow it if you want these alerts. The message is one of:

- `Couldn't restore. Open the restore log for details.`
- `Partly restored. N of M windows.` (for example 5 of 7)
- `Couldn't fix monitors. Open the restore log for details.`

Click the notification to open Finder with the restore log selected. Restores you start yourself from the menu do not send a notification.

## Export diagnostics

If something went wrong, export diagnostics right after it happens.

1. Click the bear, then **Export Diagnostics…**
2. Wait a few seconds. The menu item briefly reads `Exporting Diagnostics…`.
3. A note appears under it: `Diagnostics saved to the Desktop`. Finder opens with the file selected.
4. The file is a zip on your Desktop named `TotalRekall-Diagnostics-YYYY-MM-DD-HHMM.zip`.
5. Attach the zip to your report (see "Reporting a problem" below). The app never uploads it.

If the Desktop cannot be used, the note says `Couldn't use the Desktop. Saved in TotalRekall's folder.` The zip is then in `~/Library/Application Support/TotalRekall/exports`. If it says `Export failed`, describe what happened in your report.

**What is inside the zip:** a short activity log from the app; the last restore log; a summary of the saved layouts; a list of your displays (size, position, and which desktops each has); the app version and macOS version; and a list of what is included.

**No window titles.** Window titles can contain private things (document names, web pages). The app does not copy the raw restore log or saved layouts into the zip. Every window title in the restore log is replaced with `[redacted]`. The zip does contain app names and display serial numbers. It also contains the desk names you chose (for example "Studio"), because they help us tell your desks apart; leave a name generic if you do not want to share it. You can open it and check before sending.

## Known limitations

- The fix for two identical monitors swapping places has been tested on one setup only: a MacBook Pro with two identical monitors on one dock. Other setups may behave differently.
- It needs macOS 26 or later.
- Moving windows between desktops uses a macOS feature that Apple does not document. If macOS 26 changes it, the app falls back to **position only**: it puts windows back at the right place on the screen but cannot move them to the right desktop.
- If the app is signed ad-hoc (without an Apple developer account), macOS may switch Accessibility off after each reinstall or update. You will need to switch it on again.
- First open of a build that is not notarized needs the "Open Anyway" step described above.

## Reporting a problem

Open an issue at https://github.com/productengineered/TotalRekall/issues and include:

- The diagnostics zip, exported right after the problem (see "Export diagnostics").
- Your macOS version.
- Your monitor setup: how many displays, their models, and how they connect. Leave out serial numbers.
- What you expected to happen and what happened instead.

## Quit and uninstall

- **Quit:** click the bear, then **Quit TotalRekall**.
- **Stop it starting at login:** click the bear and untick **Launch at Login**.
- **Uninstall:**
  1. Quit the app.
  2. Drag `/Applications/TotalRekall.app` to the Trash.
  3. In **System Settings > Privacy & Security > Accessibility**, select **TotalRekall** and click the minus (-) button.
  4. Optional: delete the folder `~/Library/Application Support/TotalRekall` (saved layouts and logs).

## Sharing a build you made

Build the disk image with `scripts/make-dmg.sh`. It builds an ad-hoc signed Release app and writes `dist/TotalRekall-<version>.dmg`, which holds the app and an Applications link. It does not touch your installed copy.

If you share the bare app instead of the DMG, zip it so it keeps its signature: `ditto -c -k --keepParent /Applications/TotalRekall.app TotalRekall.zip`. Whoever receives it unzips it, moves it to Applications, and follows the same "Open Anyway" step. If macOS still refuses, this command removes the download marker:

`xattr -dr com.apple.quarantine /Applications/TotalRekall.app`
