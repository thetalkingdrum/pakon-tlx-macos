# Kodak PSI

The TLX client is Kodak's SDK demo. **PSI** is the full application Pakon
shipped with the scanner: roll and strip management, the order database,
framing and colour tools, and Save As in several formats. It drives the same
`TLB.dll` engine, so it runs on this bridge unchanged, with the same
`pkusb.dll` and `pakonusb.py`.

This installs PSI with the patches from Juan Cruz Lehmann's
[pakon-win11-enhanced](https://github.com/juancholehmann-cpu/pakon-win11-enhanced):
full 3000 × 2000 frames at Base 16, a Positive film mode, Ignore DX, half-frame
splitting, profiles, and RAW16 extraction (Help → Extract RAW16, then Save As
Raw).

```sh
./run.sh install-psi          # once; about as long as ./run.sh install
./run.sh psi                  # start the bridge if needed, then PSI
```

PSI lives in its own Wine prefix, `~/.wine-psi` (`PAKON_PSI_PREFIX` to
change it), so the TLX setup in `~/.wine` is never touched. Both use the same
USB server, one at a time: starting either client closes the other.

Tested on an F-135 Plus (serial 5963): initialisation, a strip scan, and saves
as RAW16, TIFF and JPEG.

## What gets installed, and why

Nothing third-party is in this repo. `install-psi` fetches each piece, checks it
against a pinned SHA-256, and caches it in `~/.local/share/psix/downloads`.

| Piece | From | Why |
|---|---|---|
| OEM engine | the same archive as `./run.sh install` | PSI drives `TLB.dll` like the TLX client |
| PSI | the same archive, `Pakon Update/program files/Pakon/PSI` | the application itself, and its `mrd.mdb` database |
| `PSI.exe`, `TLB.dll` | pakon-win11-enhanced at commit `9085fd7` (MD5s as his installer checks) | the Win11 patches. The stock files are kept as `PSI.exe.orig` and `TLB.dll.stock` |
| Jet 4.0 SP8 | Microsoft, via archive.org (winetricks' URL and hash) | PSI opens `mrd.mdb` through the Access ODBC driver at every start |
| MDAC 2.8 ODBC driver manager | Microsoft, via archive.org (winetricks' URL and hash) | see below; used by `PSI.exe` only |

His `TLB.dll` is a binary patch of the same TLB 3.1.0.28 this project was
built on: 726 changed bytes and one added section. It still imports
`VERSION.dll`, so `setup.sh` redirects it to `pkusb.dll` exactly as it does the
stock one.

### Why Wine needs Microsoft's ODBC manager for PSI

At start-up PSI creates an ODBC data source, `MRD Log`, on `mrd.mdb` with
`SQLConfigDataSource`. Without Jet that fails with *"SQLConfigDataSource
Failed. Please call technical support."* With Jet it connects, and then fails
on its first query. PSI's MFC 7.1 database classes speak ODBC 2.x
(`SQLSetStmtOption` for the cursor type, `SQLErrorW`, `SQLSetConnectOptionW`).
Jet's `odbcjt32.dll` is a Unicode ODBC 3.x driver and exports only the 3.x
equivalents. On Windows the driver manager translates between the two; Wine's
`odbc32` maps only two statement options (not even in Wine master), so the
cursor call fails and MFC throws.

The fix is Microsoft's own driver manager (`odbc32`, `odbccp32`, `odbcint` and
friends from MDAC 2.8), copied beside `PSI.exe` and enabled by a Wine DLL
override for `PSI.exe` alone. Jet itself goes where its installer puts it, in
`syswow64`. winetricks has verbs for both (`jet40`, `mdac28`) but refuses to
run them on a 64-bit prefix, and every prefix on macOS is one, so the installer
does their steps directly.

### Other things PSI needs that the TLX client does not

- **The COM server directory on `PATH`.** `PakonImau.dll` imports `ekjpegi`,
  `KODAKCMS` and `xerces-c_2_2_0`, which sit in the COM server directory. The
  TLX client runs from there; PSI runs from `Pakon\PSI` and otherwise fails at
  scanner initialisation with *error code 178* (`EC_WIN_LoadLibrary`, naming
  `PakonImau.dll`).
- **`C:\ProgramData\Pakon\Temp`**, where RAW16 extraction stages its frames.
- **Registry** from the PSI installer and Juan's `install_v4.ps1`: the program
  path, IQueue off, Save As Raw off by default, and the firmware prompt below.
- **Light calibration.** If `~/.wine` has run a Light Correction and the PSI
  prefix has not, it is copied across; it is the same engine and the same
  scanner. `PAKON_PSI_NO_CAL_IMPORT=1` skips that, and then PSI's own light
  correction has to run once with the film gate empty.

## PSI can reflash the scanner's PICs

TLB contains a PIC firmware updater (`FN_bUpdate`) with the images in
`Config\Firmware\`, and PSI offers to run it at start-up (*"Scanner firmware
may need updating... Would you like to update the firmware if necessary?"*).
The TLX client never calls it. A flash that stalls halfway through this bridge
would leave a controller half-written, and recovering one takes a bootloader
flash tool.

Three things keep that from happening:

1. **`pakonusb.py` refuses the path.** Before erasing anything the updater
   puts the chip in its bootloader (`FN_bPicToBootLoaderState`): a WRITE of
   register `0x0A` = `00 55` to the application address, then type-4 command
   `0x01` (`0x0D` on a `0x24` PICM), then a ping to the bootloader address. The
   server refuses the first two, and anything but that ping sent to
   `0x22`/`0x26`/`0x42`/`0x46`. None of it occurs in ordinary scanning, and
   TLB's controller probe (a type-4 `0x00` ping across `0x44`, `0x46`, `0x24`,
   `0x26`) still passes. The updater then fails at its first packet, with the
   chip still running its application.
2. **The prompt defaults to no.** `install-psi` sets `LoadFirmwareAtStartup`
   and `LoadFirmwareAtStartupAlways` to 0 under `HKLM\Software\Pakon\PSI\Scanner
   Settings`. If PSI asks anyway, answer **No**.
3. **It would find nothing to do on a current unit.** The updater flashes only
   when `Config\Firmware` holds a strictly newer version for the hardware
   revision the chip reports. An F-135 Plus on `NL050A` / `NM0506` (Lamp
   `0x05,0x0A`, Motor `0x05,0x06` in `PakonErrorLogMain.txt`) is already on the
   newest. One exception: before entering the bootloader it saves an "update in
   progress" marker, and a set marker skips the version check at the next start.

## Notes

- `dx-override.conf` applies to PSI too; it lives in the server, not the client.
  PSI also has its own Setup → Ignore DX.
- One RAW16 save produced a file named
  `AA_0000A.raw:Users:mats:Desktop:AA_0000A.raw` (Finder shows the colons as
  slashes): the right data under a name with the save path appended. The other
  files from the same session were named normally. Not yet reproduced.
