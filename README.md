# TotalRekall

<p align="center">
  <img src="docs/images/app-icon.png" width="128" alt="The TotalRekall app icon, a bear">
</p>

<p align="center"><strong>Your desk, the way you left it.</strong></p>

Tired of fixing your monitors and app locations each time you reconnect your Mac to your dock? Monitors arranged incorrectly, windows all over the place.

TotalRekall fixes that. It remembers your setup and restores your monitor order, window positions and sizes, and desktops when you reconnect. It runs quietly from your menu bar, so you can get back to what you were doing.

> **TotalRekall is in beta.** Please report bugs early and often: if something doesn't work the way you expect, even something small, [open an issue](https://github.com/productengineered/TotalRekall/issues). See [Report a problem](#report-a-problem) for what to include.

## What it restores

- **Monitor order/arrangement.** Puts your monitors back in the right arrangement, so moving between screens works the way you expect.
- **Window positions and sizes.** Returns your windows to the right screens, at the size and position you left them.
- **Desktops (Spaces).** Moves windows back to the desktops they were on before you undocked.

While you're docked, TotalRekall takes continual snapshots of your layout (every 10 minutes). When you reconnect, it puts everything back where it was.

## Support the project

TotalRekall is free. If it saves you some window-dragging, you can buy me a coffee.

<a href="https://www.dynamiccorporateleader.com/offers/LC2KfjsD"><img src="https://img.shields.io/badge/%E2%98%95%20Buy%20me%20a%20coffee-FFDD00?style=for-the-badge" alt="Buy me a coffee" height="36"></a>

## Get started

You'll need **macOS 26 (Tahoe) or later** and a Mac you connect to external monitors.

### Install from a disk image

If you have a `TotalRekall-<version>.dmg`:

1. Open it and drag **TotalRekall** into **Applications**.
2. Open **TotalRekall**.
3. Follow the setup window to enable **Accessibility** in System Settings.
4. If you're docked, give your desk a name, then click **Save**.

<table>
  <tr>
    <td align="center" valign="top"><img src="docs/images/setup-needs-access.png" width="260" alt="The setup window asking for Accessibility access, with an Open System Settings button"></td>
    <td align="center" valign="top"><img src="docs/images/setup-ready.png" width="260" alt="The setup window saying You're all set, with a Continue button"></td>
    <td align="center" valign="top"><img src="docs/images/setup-name-desk.png" width="260" alt="The setup window asking you to name this desk, with a name field and a Save button"></td>
  </tr>
  <tr>
    <td align="center">First launch: turn on Accessibility</td>
    <td align="center">Access granted</td>
    <td align="center">Name your desk</td>
  </tr>
</table>

Builds are not yet notarized by Apple. If macOS blocks the first launch, go to **System Settings > Privacy & Security** and choose **Open Anyway**. See the [user guide](docs/USER_GUIDE.md) for the full steps.

### Build from source

Requires **Xcode 26 or later**.

```sh
git clone https://github.com/productengineered/TotalRekall.git
cd TotalRekall
scripts/install.sh --adhoc
```

The script builds the app, installs it in `/Applications`, and opens it. No developer account is required for this option. Ad-hoc builds may need Accessibility permission granted again after each reinstall.

For a stable signing identity, copy `app/Config/Local.xcconfig.example` to `app/Config/Local.xcconfig`, enter your Apple developer team ID, and run `scripts/install.sh` without `--adhoc`.

You can also open `app/TotalRekall.xcodeproj` in Xcode. To package a disk image, run `scripts/make-dmg.sh`; the file is written to `dist/`.

### Once it's running

While docked, create your first snapshot by clicking the bear icon <img src="docs/images/menubar-icon.png" height="20" alt="the bear menu bar icon"> in the menu bar and choosing **Save Snapshot Now**. After that, dock and undock as usual. If you've just rearranged your windows, choose **Save Snapshot Now** before you undock. Choose **Launch at Login** if you'd like TotalRekall to start with your Mac.

<p align="center"><img src="docs/images/menu.png" width="390" alt="The TotalRekall menu: status line, last restore result, Save Snapshot Now, Restore Now, Fix Monitors, Reveal Restore Log, Export Diagnostics, Desks, Launch at Login, and Quit TotalRekall"></p>

### More than one desk

If you dock in more than one place, such as at home and at work, TotalRekall remembers each desk separately. During setup it asks you to name the desk you're connected to. The first time you connect to a new set of monitors, it asks whether to save that desk and what to call it. If you skip the question, it keeps working and uses a name like "Desk 2" that you can change later.

The **Desks** menu lists your desks, with the current one checked. From there you can rename the current desk, save its current monitor arrangement, or forget it.

<p align="center"><img src="docs/images/menu-desks.png" width="560" alt="The Desks submenu: the current desk with a checkmark, then Rename, Save Current Arrangement, and Forget Desk"></p>

The [user guide](docs/USER_GUIDE.md) covers setup, menu controls, troubleshooting, and uninstalling.

## Permissions and privacy

TotalRekall needs **Accessibility** permission to read and change window positions and sizes. It keeps a local record of your windows on your Mac so it can put them back. It does not record keystrokes or read the contents of your windows.

The app makes **no network requests**. There are no analytics, crash uploads, or update checks. Layouts and logs stay on your Mac in `~/Library/Application Support/TotalRekall`, in a folder restricted to your user account.

The app is not sandboxed. It also requests notification permission so it can alert you when an automatic restore needs attention.

## Limitations

**Space restoration uses private macOS APIs.** Apple can change these in a macOS update. If Apple changes them, moving windows between Spaces may stop working until TotalRekall is updated. This also prevents distribution through the Mac App Store.

## Report a problem

Choose **Export Diagnostics…** from the bear menu, then [open an issue](https://github.com/productengineered/TotalRekall/issues) with the ZIP, your macOS version, your monitor setup, and what went wrong.

The ZIP is saved to your Desktop, with a fallback to the app's local data folder. Window titles are redacted and raw saved layouts are excluded. App names and display serial numbers are included, so you can inspect it before sharing. Nothing is uploaded automatically.

<details>
<summary>Local files and resetting the app</summary>

Data is stored in `~/Library/Application Support/TotalRekall`:

- `snapshots.json` and `snapshots.last-good.json`: saved layouts, including window titles.
- `restore-log.json`: restore results.
- `exports/`: diagnostics exports when the Desktop is unavailable.
- `instance.lock`: prevents multiple copies from running at once.

To clear saved layouts and logs, quit TotalRekall, delete this folder, and reopen the app. To also remove preferences, run:

```sh
defaults delete com.productengineered.TotalRekall
```

</details>

## License

A license has not yet been selected.
