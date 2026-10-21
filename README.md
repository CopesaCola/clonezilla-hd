# clonezilla-hd

Automates [Clonezilla Live on hard drive](https://clonezilla.org/livehd.php)
from a USB stick. A laptop boots straight into Clonezilla from its own drive,
keeps disk images on a separate partition, and runs Clonezilla's **Lite
Server** to PXE-boot other computers and deploy images to them.

```
 USB stick (make-usb.sh)            laptop internal drive (after install)
 ┌──────────────────────────┐       ┌──────────┬───────────────────────────┐
 │ Clonezilla Live          │  ───► │ CZBOOT   │ CZIMAGES                  │
 │ + "Install Clonezilla to │       │ 2 GiB    │ rest of the drive, ext4   │
 │   this computer's HARD   │       │ FAT32/EFI│ = /home/partimag          │
 │   DRIVE" boot entry      │       │ /live    │   (your images)           │
 └──────────────────────────┘       └──────────┴───────────────────────────┘
```

## What the installer does

These are the steps from clonezilla.org/livehd.php, scripted:

1. Picks the internal drive. USB drives and the installer stick are never
   offered. If there's more than one internal drive, it asks which one.
2. Partitions it (GPT):
   - `CZBOOT`: a 2 GiB FAT32 EFI partition holding Clonezilla Live in
     `/live`. livehd.php renames it to `/live-hd`, but Lite Server only works
     with `/live`, so keep other Clonezilla USB sticks unplugged when you
     boot the laptop.
   - `CZIMAGES`: ext4, the rest of the drive, for images.
3. Rewrites Clonezilla's boot menus for the hard drive:
   - adds `ocs_repository="dev:///LABEL=CZIMAGES"`, so the images partition
     is already mounted as `/home/partimag` when Clonezilla starts.
   - adds a **Clonezilla Lite Server (PXE-boot other computers)** entry.
   - presets language and keyboard so Clonezilla doesn't ask on every boot.
4. Installs both boot loaders. UEFI uses Clonezilla's own signed shim and
   GRUB, so Secure Boot works. Legacy BIOS uses syslinux with the GPT MBR.
   On UEFI machines it also adds a "Clonezilla (hard drive)" boot entry.
5. Reboots into Clonezilla from the hard drive.

Run it again on a drive that already has this layout and it **upgrades**
instead: it replaces Clonezilla on `CZBOOT` and keeps your images on
`CZIMAGES`. You can also choose to wipe the drive and start over.

## 1. Make the USB stick (on any Linux PC)

```bash
git clone https://github.com/CopesaCola/clonezilla-hd.git
cd clonezilla-hd
lsblk -d -o NAME,SIZE,TRAN,MODEL           # find the USB stick, e.g. /dev/sdb
sudo ./make-usb.sh /dev/sdb
```

The script downloads the latest stable Clonezilla Live (checksum verified),
writes it to the stick, and adds the installer boot entry. To build a
`.img` to flash with Rufus or balenaEtcher instead, give it a filename:
`sudo ./make-usb.sh clonezilla-hd-installer.img`.

| Option | Default | |
|---|---|---|
| `--auto` | off | the installer is the default boot entry (5 s) and skips its prompts: plug in, power on, walk away. It refuses to run if the computer has more than one internal drive. |
| `--default lite-server` | `clonezilla` | make the hard drive boot into Lite Server by default |
| `--boot-size 4G` | `2G` | size of the Clonezilla partition |
| `--timeout 10` | `30` | boot menu timeout on the hard drive, in seconds |
| `--locale ''` `--keymap ''` | `en_US.UTF-8` / `us` | empty = Clonezilla asks at every boot |
| `--clonezilla 3.3.3-37` | latest | pin a version, or pass a zip URL or local zip file |

### Only have Windows?

1. Download the Clonezilla Live **zip** (amd64, stable) from clonezilla.org.
2. Format the USB stick as **FAT32**. Windows only offers FAT32 for sticks
   up to 32 GB; for a bigger stick, use Rufus with "Non bootable" and FAT32.
3. Extract the zip's contents to the root of the stick, so `live\`, `EFI\`
   and `utils\` sit directly on it.
4. On the stick, open `utils\win64`, right-click `makeboot64.bat`, choose
   **Run as administrator** and follow its prompts. Check that it names the
   USB stick's drive letter.
5. Copy this repo's `czhd` folder to the root of the stick. Don't edit the
   `.sh` files in Notepad: Windows line endings break them.
6. Boot the laptop from the stick. Choose **Clonezilla live**, pick your
   language and keyboard, then **Enter_shell**, then **cmd**.
7. Run `sudo bash /run/live/medium/czhd/install-to-hd.sh`.

The result is the same; you just don't get the extra boot entry or `--auto`.

## 2. Install onto the laptop

1. In the laptop's firmware settings, allow booting from USB.
2. Boot from the stick and pick **Install Clonezilla to this computer's HARD DRIVE**.
3. Confirm the drive by typing `YES`. Skipped with `--auto`.
4. When it says so, remove the stick. The laptop reboots into Clonezilla from its own drive.

## 3. Use it

The laptop's boot menu now offers:

- **Clonezilla live**: the normal wizard. Images are saved to and restored
  from `CZIMAGES`. At the repository question, pick
  **"skip — use existing /home/partimag"** if it's asked at all.
- **Clonezilla Lite Server**: PXE-boots other computers and restores an image
  from `CZIMAGES` onto them, one at a time or many at once by multicast.
  1. Connect the laptop and the clients to the same wired network or switch.
  2. Pick the Lite Server entry, then choose the image repository (the
     `CZIMAGES` partition, on the laptop's drive). It also asks whether to
     use an existing DHCP server or start its own: choose "start new" only
     on an isolated switch with no router.
  3. Set the clients to network/PXE boot. Secure Boot can stay on: Lite
     Server normally offers UEFI clients an unsigned boot loader, so this
     entry swaps in Clonezilla's signed shim and GRUB (`czhd/lite-server-helper.sh`,
     log in `/tmp/czhd-lite-server.log`). Signed network boot works best when
     Lite Server starts its own DHCP on an isolated switch.
- **Import images from a USB drive**: copies premade Clonezilla images from
  a USB drive onto `CZIMAGES`, then checks they're restorable.
  1. Pick the entry, plug in the drive when asked, and press Enter.
  2. Choose which of the listed images to copy (or `all`).

  The drive is mounted read-only. Images are found up to 3 folders deep,
  spaces in names become `_`, and a half-finished copy never shows up as an
  image. From a Clonezilla shell you can also run
  `sudo bash /run/live/medium/czhd/import-images.sh [/dev/sdXN]`.
- **Capturing new images**: Lite Server only sends images out. To
  capture a machine's disk, either:
  - connect that disk to the laptop (USB enclosure or dock) and use
    *Clonezilla live → device-image → savedisk*, or
  - save on the client with the regular stick, then copy the image folder to
    the laptop's `/home/partimag`.

## Notes and limits

- **x86-64 only**, as is Clonezilla's amd64 build.
- Keep other Clonezilla USB sticks unplugged when you boot the laptop. On
  UEFI, Clonezilla's GRUB finds its menu by looking for a marker file that
  every Clonezilla stick also has.
- `install-to-hd.sh` writes a log to `/tmp/czhd-install.log`. If anything
  fails it shows the error and drops you to a shell.
- Advanced/testing: `CZHD_DISK=/dev/nvme0n1` forces the target drive;
  `CZHD_NO_REBOOT=1` skips the final reboot.

## Development

```bash
shellcheck -x make-usb.sh czhd/*.sh
```

| File | Runs on | Purpose |
|---|---|---|
| `make-usb.sh` | any Linux PC | builds the installer USB stick (or `.img`) |
| `czhd/install-to-hd.sh` | the laptop, inside Clonezilla Live | partitions the drive and installs Clonezilla |
| `czhd/import-images.sh` | the laptop, inside Clonezilla Live | copies premade images from a USB drive onto CZIMAGES |
| `czhd/lite-server-helper.sh` | the laptop, inside Clonezilla Live | fixes Lite Server's client boot files (signed UEFI loader, no laptop-only settings) |
| `czhd/menu-lib.sh` | both | edits Clonezilla's syslinux and GRUB menus |
