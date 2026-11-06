# newdevmon

Emails you when a new device connects to your main or guest network.
Built for **Asuswrt-Merlin** routers (developed on an ASUS RT-BE86U) and meant to be run from **amtm** as a personal script.

## What it does

- Checks DHCP leases and the ARP table of all LAN bridges every minute (configurable): `br0` is the main network, `br1`/`br2`/... are guest networks.
- A device is "new" when its MAC address has never been seen before. The first run reports everything; use "Mark all connected devices as known" to start silently.
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
2. `m` to mark the devices currently connected as known (optional)
3. `s` then `i` to install the cron jobs and the startup hook

## Menu

| Key | Action |
|-----|--------|
| `c` | **C**heck for new devices now |
| `v` | **V**iew connected devices (with band and signal) |
| `d` | Known **d**evices and details |
| `f` | **F**orget a device (it will be reported again) |
| `m` | **M**ark all connected devices as known |
| `s` | **S**ettings and maintenance (see below) |
| `e` | **E**xit |

Settings submenu: `f` check **f**requency, `n` **n**otify by email about new versions, `l` read the **l**og, `t` send a **t**est email, `u` **u**pdate, `p` restore the **p**revious version, `i` **i**nstall cron jobs and startup hook, `r` **r**emove them, `b` back.

Command line: `newdevmon.sh [menu|run|cron|install|uninstall|baseline|test|list|detail NR|MAC|log|forget MAC|update-check|update [-y]|rollback]`

## How it works

- Cron runs `newdevmon.sh run` every `INTERVAL` minutes. A `services-start` hook restores the cron jobs after a reboot.
- Last-seen times are kept in RAM (`/tmp`) and written to flash at most once an hour, and only when something changed, to limit flash wear.
- "Online" comes from the Asus client list (`/jffs/nmp_cl_json.js`). Without it, everything in the leases/ARP table counts as seen.
- Band, signal and node come from `/tmp/clientlist.json`. If that file is missing or has a different layout, those fields are simply omitted.
- Devices with a private/random MAC address (iPhone, Android, Windows) can appear as new after a reset or per network.

## Limitations

- Detection is based on DHCP/ARP, so devices with a static IP that never talk to the router may be missed.
- The meaning of some Asus fields (`wireless`, `mlo`, band suffixes such as `_1`) is inferred and may differ per firmware.

## Updates

The repository is fixed in the script: `plompie010/Newdevmon` (branch `main`, file `newdevmon.sh`). A daily check sets an "update available" notice in the menu header, optionally with an email (Settings > `n`). Open `s` (Settings) then `u` to install; the old version is backed up (3 kept) and can be restored with `p` in the same submenu.

## Uninstall

Open Settings (`s`), press `r`, then delete `/jffs/scripts/newdevmon.sh` and `/jffs/addons/newdevmon`.

## Troubleshooting

- **No email**: check amtm's email test first; then use Settings > `t`. Read the log with Settings > `l`.
- **Everything shows as "Unknown network"**: the router could not map the IP to a bridge; run from the router itself, not a copy elsewhere.
- **Update says latest version**: the `VERSION` in the repository must be higher than the installed one.

## Changelog

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
