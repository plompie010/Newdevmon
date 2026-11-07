# newdevmon

Emails you when a new device connects to your main or guest network.
Built for **Asuswrt-Merlin** routers (developed on an ASUS RT-BE86U) and meant to be run from **amtm** as a personal script.

## What it does

- Checks DHCP leases and the ARP table of all LAN bridges every minute (configurable): `br0` is the main network, `br1`/`br2`/... are guest networks.
- A device is "new" when its MAC address has never been seen before. The first run reports everything; use Settings > `m` ("Mark all connected devices as known") to start silently.
- All new devices found in one check are reported in a single email.
- Uses the email settings you already configured in amtm (`amtm > em`). No extra credentials.
- Shows names, vendor, band, signal strength and AiMesh node from the Asus client lists when available.
- Checks GitHub once a day for a newer version. Updates are only installed from the menu, after confirmation, with backup and rollback.

## Requirements

- Asuswrt-Merlin with amtm, and amtm email configured and working
- JFFS enabled (for the script, the known-device list and cron persistence)

## Install

SSH into the router and run:

```sh
curl -fsSL https://raw.githubusercontent.com/plompie010/Newdevmon/main/newdevmon.sh -o /jffs/scripts/newdevmon.sh
chmod 755 /jffs/scripts/newdevmon.sh
```

Then start `amtm`, press `p`, and pick `newdevmon.sh`. In the menu choose:

1. `s` then `t` to send a test email
2. `s` then `m` to mark the devices currently connected as known without an email (optional)
3. `s` then `i` to install the cron jobs and the startup hook

## Menu

| Key | Action |
|-----|--------|
| `1` | Check for new devices now |
| `2` | Devices: list with band, signal and node; check now, details per device, forget a device |
| `s` | **S**ettings and maintenance (see below) |
| `e` | **E**xit |

Settings submenu: `f` check **f**requency, `n` **n**otify by email about new versions, `m` **m**ark all connected devices as known (no email is sent), `o` download the vendor list (**o**ui), `l` read the **l**og, `t` send a **t**est email, `u` **u**pdate, `p` restore the **p**revious version, `i` **i**nstall cron jobs and startup hook, `r` **r**emove them. Press Enter to go back.

Command line: `newdevmon.sh [menu|run|cron|install|uninstall|baseline|test|list|detail NR|MAC|debug NR|MAC|portscan NR|MAC|oui-update|log|forget MAC|update-check|update [-y]|rollback]`

## How it works

- Cron runs `newdevmon.sh run` every `INTERVAL` minutes. A `services-start` hook restores the cron jobs after a reboot.
- Last-seen times are kept in RAM (`/tmp`) and written to flash at most once an hour, and only when something changed, to limit flash wear.
- "Online" comes from the Asus client list (`/jffs/nmp_cl_json.js`). Without it, everything in the leases/ARP table counts as seen.
- Band, signal and node come from `/tmp/clientlist.json`. If that file is missing or has a different layout, those fields are simply omitted.
- Devices with a private/random MAC address (iPhone, Android, Windows) can appear as new after a reset or per network.

## Vendor list and port scan

- The vendor of a device is looked up in a local copy of the IEEE list. Download it once in Settings > `o`. The vendor shown by Asus itself (from its network map) is used as a fallback. Devices with a private/random MAC address have no vendor. Small vendors with their own address block (MA-M and MA-S) are included; a device from a block that is privately registered still shows no vendor.
- Port scan (device detail > `s`): TCP connect to about 50 common ports using `nmap` (the script offers to install it through Entware if it is missing), a few seconds per device. Only private addresses are scanned. A device that drops packets looks the same as one with closed ports.

## Limitations

- Detection is based on DHCP/ARP, so devices with a static IP that never talk to the router may be missed.
- Behind an AiMesh node the router often cannot tell Wi-Fi from wired; those devices show `wired?`.
- The meaning of some Asus fields (`wireless`, `mlo`, band suffixes such as `_1`) is inferred and may differ per firmware.

## Updates

The repository is fixed in the script: `plompie010/Newdevmon` (branch `main`, file `newdevmon.sh`). A daily check sets an "update available" notice in the menu header, optionally with an email (Settings > `n`). Open `s` (Settings) then `u` to install; the old version is backed up (3 kept) and can be restored with `p` in the same submenu.

## Uninstall

Open Settings (`s`), press `r` and confirm. This removes the cron jobs, the startup hook, the vendor list and the data folder `/jffs/addons/newdevmon` (including the known-devices list). Finally delete the script itself: `rm /jffs/scripts/newdevmon.sh`.

## Troubleshooting

- **No email**: check amtm's email test first; then use Settings > `t`. Read the log with Settings > `l`.
- **Everything shows as "Unknown network"**: the router could not map the IP to a bridge; run from the router itself, not a copy elsewhere.
- **Update says latest version**: the `VERSION` in the repository must be higher than the installed one.

## Changelog

### 0.1.31
- Port scan now uses only nmap; if it is missing the script offers to install it through Entware (after confirmation). The nc and curl fallbacks were removed

### 0.1.30
- Port scan: more robust detection of curl (several locations) and optional use of nmap (Entware) when installed

### 0.1.29
- Port scan falls back to curl when nc is not available on the router

### 0.1.28
- Uninstall now also removes the data folder (/jffs/addons/newdevmon: known devices, settings, log)

### 0.1.27
- Uninstall now also removes the downloaded vendor list and its folder on the USB drive

### 0.1.26
- Fix: vendor list download failed with HTTP 418; the IEEE server blocks short user agents, so a full browser user agent is now sent

### 0.1.25
- The new-device email now includes the vendor (from the vendor list, else from Asus)
- Fewer flash writes: the known-devices file is no longer touched every minute, and the update flag is only rewritten when it changes

### 0.1.24
- Vendor list now also includes the IEEE MA-M and MA-S registries (small vendors with their own address block); lookups try the most specific match first

### 0.1.23
- The vendor list is stored on the USB drive (`/opt/share/newdevmon/`) when Entware is present, so the flash is spared; otherwise on JFFS. An older copy on the flash is removed when the list moves to USB

### 0.1.22
- Detail screen: vendor from a local IEEE vendor list (download it once with Settings > `o`; about 2 MB, stored on the USB drive under `/opt` when Entware is present, otherwise on JFFS; only written when you press `o`). Private/random addresses have no vendor
- Detail screen: `s` scans about 50 common TCP ports on the device (private addresses only, needs `nmap`, installable from the script); also `portscan NR|MAC` on the command line

### 0.1.21
- Devices screen: `c` checks for new devices and refreshes the list

### 0.1.20
- Link shows `wired?` for devices behind an AiMesh node that are only listed as wired: nodes often do not report Wi-Fi clients (for example sleeping cameras), so the router cannot tell Wi-Fi from wired. A plain `wired` now only appears for devices on the router itself

### 0.1.19
- Link/Node: when a device is listed under both the router and an AiMesh node with the same connection type, the node is chosen (the router only sees it through the backhaul)

### 0.1.18
- New `debug NR|MAC` command that prints the raw Asus data about one device, to diagnose wrong Link/Node information

### 0.1.17
- Fixed the banner on busybox awk (no `%*s` support)

### 0.1.16
- Exit splash screen ("Thanks for using New Device Monitor") instead of an empty screen

### 0.1.15
- New ASCII header (name, version, router model, repository)
- A clear bar is printed before every new screen, so it is easy to find when the terminal keeps scrolling

### 0.1.14
- Enter goes back everywhere (the Settings menu no longer uses `b`)

### 0.1.13
- After a failed email the script waits 30 minutes before trying again (no more retry every minute); a manual check (menu 1) ignores the pause and the dashboard shows the pause
- Removed the test override for the update source: the repository is now fixed in the script

### 0.1.12
- Settings menu shows the same header/dashboard as the main menu; title is now "New Device Monitor"

### 0.1.11
- Devices list: MAC column removed (still in the detail screen), Node column added (router or AiMesh node the device is connected to)

### 0.1.10
- A new device with a private MAC address and the same name as a known device is flagged in the email ("Similar to: ...") and in the detail screen ("Same name as: ...")
- Link column no longer flips between wired and Wi-Fi: the Wi-Fi entry with a signal value wins
- Devices that were never online since being added show "never online" instead of "-"

### 0.1.9
- Menu options 2-4 merged into one Devices screen: the list (now with band and signal), details, and forget at the bottom

### 0.1.8
- Added a note to the script header that the code was written with the help of Claude AI

### 0.1.7
- "Mark all connected devices as known" moved to Settings (`m`) with a note that no email is sent

### 0.1.6
- Main menu actions are numbered 1-5; `s` (Settings) and `e` (Exit) keep letters

### 0.1.5
- Update screen shows the changelog of the new versions (from README.md) instead of a line count

### 0.1.4
- Log, test email, update, rollback, install and remove moved to the Settings submenu; main menu is shorter
- Removed legacy Dutch label handling (reset the known-device list when upgrading from older versions)

### 0.1.3
- Added band, signal, vendor, Asus name, MLO and AiMesh node (from Asus client lists)
- Asus device names are preferred over DHCP host names
- Everything translated to English (script, mails, README)
- Settings moved to a submenu
- Menu is a single column with mnemonic keys (`u` update, `r` remove, ...)

### 0.1.2
- Device detail screen with forget action

### 0.1.1
- Dashboard, colours, first/last seen, online status

### 0.1
- Initial version: new-device mails, menu, GitHub update check

## License

GPL-3.0-or-later. See `LICENSE`.
