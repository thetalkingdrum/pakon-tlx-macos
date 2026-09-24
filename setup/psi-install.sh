#!/bin/bash
# Install Kodak's PSI -- the full Pakon scanning application, not the TLX demo
# client -- with the Windows 11 patches from
# github.com/juancholehmann-cpu/pakon-win11-enhanced, into its own Wine prefix.
#
#   ./run.sh install-psi                 fetch everything
#   ./run.sh install-psi --from <dir>    OEM files from a local copy instead
#
# PSI drives the same TLB.dll engine as the TLX client, so the scanner side is
# unchanged: pkusb.dll plus pakonusb.py.  What PSI adds is an Access database
# (mrd.mdb) it opens through ODBC at start-up, which needs two Microsoft
# components Wine does not have -- see docs/PSI.md for why each is needed:
#
#   * Jet 4.0 SP8, the Access engine and its ODBC driver;
#   * the MDAC 2.8 ODBC driver manager, used by PSI.exe only, because Wine's
#     own one does not translate PSI's ODBC 2.x calls for Jet's 3.x driver.
#
# Nothing third-party is stored in this repo.  Every download is pinned by
# SHA-256 and cached in ~/.local/share/psix/downloads.  Each step is idempotent.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
export WINEPREFIX="${WINEPREFIX:-$HOME/.wine-psi}"
PAKON="$WINEPREFIX/drive_c/Program Files/Pakon"
COM="${PAKON_INSTALL:-$PAKON/F-X35 COM Server}"
PSIDIR="$PAKON/PSI"
SYSWOW="$WINEPREFIX/drive_c/windows/syswow64"
DL="${PSIX_DOWNLOADS:-$HOME/.local/share/psix/downloads}"
TLX_PREFIX="${PAKON_TLX_PREFIX:-$HOME/.wine}"

FROM=""
tmp=""
work="$(mktemp -d)"
trap 'rm -rf "$work"; if [ -n "$tmp" ]; then rm -rf "$tmp"; fi; true' EXIT
[ "${1:-}" = "--from" ] && FROM="${2:?--from needs a directory}"

# --- pinned downloads ---------------------------------------------------------
OEM_URL="${PAKON_OEM_URL:-https://github.com/plonsker/pakon-scanning-software.git}"
OEM_BRANCH="${PAKON_OEM_BRANCH:-master}"
OEM_PSI_SUB="Pakon Update/program files/Pakon/PSI"
OEM_PSI_SHA=4f64b212deb96d1db5680a1600a36a1c02348c6eacfcd7f3d2d3a041711e6992

# Juan Cruz Lehmann's patched PSI.exe and TLB.dll, at a reviewed commit.  The
# MD5s are the ones his own installer checks; the SHA-256s are ours.
WIN11_RAW="https://raw.githubusercontent.com/juancholehmann-cpu/pakon-win11-enhanced/9085fd7c4c28b72c8e0be78cf866240e030cf941"
PSI_SHA=8d8e6e6cf920d8eb47f3c334e9a6cc426ed575574bb06e7a4a2109a9e3abe332
PSI_MD5=dcf44f028c85c9014770549205a81525
TLB_SHA=22b7004b68e7cc3c213153e4d565d0e6506e01679c2ac67bbf736760da4ea58e
TLB_MD5=ca383b45445d1f5cf4fed9d7ccc1f64f

# The same Microsoft packages, URLs and hashes winetricks uses for its jet40 and
# mdac28 verbs.  winetricks itself refuses both on a 64-bit prefix, and every
# prefix on macOS is one (WoW64), so the steps are done here by hand.
JET_URL="https://web.archive.org/web/20210225171713/http://download.microsoft.com/download/4/3/9/4393c9ac-e69e-458d-9f6d-2fe191c51469/Jet40SP8_9xNT.exe"
JET_SHA=b060246cd499085a31f15873689d5fa7df817e407c8261a5c71fa6b9f7042560
MDAC_URL="https://web.archive.org/web/20070127061938/https://download.microsoft.com/download/4/a/a/4aafff19-9d21-4d35-ae81-02c48dcbbbff/MDAC_TYP.EXE"
MDAC_SHA=157ebae46932cb9047b58aa849ac1885e8cbd2f218810cb83e57613b49c679d6

# --- helpers -----------------------------------------------------------------
WINE="$("$HERE/bootstrap.sh" --wine || true)"
WS=""
q() { MVK_CONFIG_LOG_LEVEL=0 WINEDEBUG=-all "$@"; }         # a quiet wine
win() { printf 'Z:%s' "$1" | tr '/' '\\'; }                 # mac path -> Wine
sha() { shasum -a 256 "$1" | cut -c1-64; }
md5of() { md5 -q "$1" 2>/dev/null || md5sum "$1" | cut -c1-32; }
flush() { [ -n "$WS" ] && q "$WS" -k >/dev/null 2>&1; sleep 1; return 0; }

fetch() {                       # fetch <url> <sha256> <name>  -> prints the path
    local url="$1" want="$2" out="$DL/$3"
    mkdir -p "$DL"
    if [ -f "$out" ] && [ "$(sha "$out")" = "$want" ]; then
        echo "$out"; return
    fi
    curl -fsSL --retry 3 -o "$out.part" "$url" \
        || { echo "download failed: $url" >&2; return 1; }
    if [ "$(sha "$out.part")" != "$want" ]; then
        echo "$3: SHA-256 mismatch -- refusing it" >&2
        echo "  expected $want" >&2
        echo "  got      $(sha "$out.part")" >&2
        rm -f "$out.part"; return 1
    fi
    mv "$out.part" "$out"
    echo "$out"
}

regimport() {                   # regimport <file> [32|64]
    q "$WINE" reg import "$(win "$1")" ${2:+/reg:$2} >/dev/null 2>&1
}

# ------------------------------------------------------------------------------
echo "installing PSI into:"
echo "  prefix   $WINEPREFIX"
echo "  PSI      $PSIDIR"
echo

echo "== 1/8  prerequisites"
"$HERE/bootstrap.sh" --install >/dev/null 2>&1 || true
WINE="$("$HERE/bootstrap.sh" --wine || true)"
[ -n "$WINE" ] || { echo "wine is missing -- run ./run.sh doctor --install"; exit 1; }
WS="$(dirname "$WINE")/wineserver"
[ -x "$WS" ] || WS=""
if [ ! -d "$WINEPREFIX/drive_c" ]; then
    q "$WINE" wineboot -u >/dev/null 2>&1 || true
    echo "        created the prefix"
else
    echo "        prefix exists"
fi

echo
echo "== 2/8  OEM engine (the same COM server the TLX client uses)"
if [ -f "$COM/TLB.dll" ]; then
    echo "        already installed at $COM"
else
    PAKON_INSTALL="$COM" "$HERE/fetch-oem.sh" ${FROM:+--from "$FROM"}
fi

echo
echo "== 3/8  Juan Lehmann's patched TLB.dll"
# Must be in place BEFORE setup.sh, which backs TLB.dll up to TLB.dll.orig and
# then redirects its VERSION.dll import to pkusb.dll.  The stock engine is kept
# as TLB.dll.stock.
tlb_src="$(fetch "$WIN11_RAW/TLB.dll" "$TLB_SHA" win11-TLB.dll)"
[ "$(md5of "$tlb_src")" = "$TLB_MD5" ] || { echo "TLB.dll MD5 mismatch"; exit 1; }
if [ -f "$COM/TLB.dll.orig" ]; then
    if [ "$(md5of "$COM/TLB.dll.orig")" = "$TLB_MD5" ]; then
        echo "        already installed (and patched by setup.sh)"
    else
        # A stock engine that setup.sh already patched: set it aside, and let
        # setup.sh back up and patch the new one.
        mv "$COM/TLB.dll.orig" "$COM/TLB.dll.stock"
        cp "$tlb_src" "$COM/TLB.dll"
        echo "        installed; stock engine kept as TLB.dll.stock"
    fi
elif [ "$(md5of "$COM/TLB.dll")" = "$TLB_MD5" ]; then
    echo "        already installed"
else
    [ -f "$COM/TLB.dll.stock" ] || cp -p "$COM/TLB.dll" "$COM/TLB.dll.stock"
    cp "$tlb_src" "$COM/TLB.dll"
    echo "        installed; stock engine kept as TLB.dll.stock"
fi

echo
echo "== 4/8  build and wire the shim (setup.sh)"
make -s -C "$ROOT/src"
WINEPREFIX="$WINEPREFIX" PAKON_INSTALL="$COM" "$HERE/setup.sh" \
    | grep -vE "^$|One step left|Scan -> Light|That runs the LED|See docs/SETUP|Run \./run\.sh, then" \
    | sed 's/^/        /'

echo
echo "== 5/8  PSI itself, with Juan Lehmann's patched PSI.exe"
psi_src="$(fetch "$WIN11_RAW/PSI.exe" "$PSI_SHA" win11-PSI.exe)"
[ "$(md5of "$psi_src")" = "$PSI_MD5" ] || { echo "PSI.exe MD5 mismatch"; exit 1; }
if [ ! -f "$PSIDIR/PSI.exe.orig" ]; then
    if [ -n "$FROM" ]; then
        src="$(dirname "$(find "$FROM" -ipath "*/Pakon/PSI/PSI.exe" | head -1)")"
        [ -f "$src/PSI.exe" ] || { echo "no Pakon/PSI/PSI.exe under $FROM"; exit 1; }
    else
        tmp="$(mktemp -d)"
        git clone --quiet --depth 1 --branch "$OEM_BRANCH" --filter=blob:none \
                  --sparse "$OEM_URL" "$tmp/oem" \
            || { echo "clone failed -- no network, or the archive moved."; exit 1; }
        git -C "$tmp/oem" sparse-checkout set --cone "$OEM_PSI_SUB" >/dev/null
        src="$tmp/oem/$OEM_PSI_SUB"
    fi
    if [ "$(sha "$src/PSI.exe")" != "$OEM_PSI_SHA" ]; then
        echo "        note: the OEM PSI.exe is not the build this was tested with"
    fi
    mkdir -p "$PSIDIR"
    # Never overwrite mrd.mdb: after the first run it is PSI's own database.
    (cd "$src" && find . -type f) | while IFS= read -r f; do
        [ -e "$PSIDIR/$f" ] && [ "$(basename "$f")" = "mrd.mdb" ] && continue
        mkdir -p "$PSIDIR/$(dirname "$f")"
        cp -p "$src/$f" "$PSIDIR/$f"
    done
    mv "$PSIDIR/PSI.exe" "$PSIDIR/PSI.exe.orig"
    echo "        OEM PSI copied (its PSI.exe kept as PSI.exe.orig)"
fi
cp "$psi_src" "$PSIDIR/PSI.exe"
# PSI.exe imports MFC 7.1 and its CRT, which a Windows install puts beside it.
for f in mfc71u.dll msvcp71.dll msvcr71.dll; do
    [ -f "$PSIDIR/$f" ] || cp -p "$COM/$f" "$PSIDIR/$f"
done
echo "        patched PSI.exe installed"

echo
echo "== 6/8  Jet 4.0 SP8 (the Access engine and its ODBC driver)"
if [ -f "$SYSWOW/msjet40.dll" ] && [ -f "$SYSWOW/odbcjt32.dll" ]; then
    echo "        already installed"
else
    jet="$(fetch "$JET_URL" "$JET_SHA" Jet40SP8_9xNT.exe)"
    # Two nested IExpress packages, then a cab.  Wine unpacks all three itself.
    mkdir -p "$work/jet1" "$work/jet2" "$work/jetcab"
    q "$WINE" "$(win "$jet")" /C "/T:$(win "$work/jet1")" /Q >/dev/null 2>&1
    q "$WINE" "$(win "$work/jet1/jetsetup.exe")" /C "/T:$(win "$work/jet2")" /Q >/dev/null 2>&1
    q "$WINE" extrac32 /e /l "$(win "$work/jetcab")" "$(win "$work/jet2/jetsetup.cab")" >/dev/null 2>&1
    [ -f "$work/jetcab/msjet40.dll" ] || { echo "could not unpack Jet"; exit 1; }
    # Where jetsetup.inf puts them: everything in the (32-bit) system directory,
    # msjetol1.dll renamed, and DAO under Common Files.
    for f in "$work/jetcab/"*.dll "$work/jetcab/jetodbc.rsp"; do
        b="$(basename "$f")"
        case "$b" in
            dao360.dll) continue ;;
            msjetol1.dll) b=msjetoledb40.dll ;;
        esac
        cp "$f" "$SYSWOW/$b"
    done
    dao="$WINEPREFIX/drive_c/Program Files (x86)/Common Files/Microsoft Shared/dao"
    mkdir -p "$dao"
    cp "$work/jetcab/dao360.dll" "$dao/"
    for d in msjet40 msjetoledb40 msrd2x40 msrd3x40 msexch40 msexcl40 msltus40 \
             mspbde40 mstext40 msxbde40 msjtes40; do
        q "$WINE" 'C:\windows\syswow64\regsvr32.exe' /s "C:\\windows\\syswow64\\$d.dll" \
            >/dev/null 2>&1 || echo "        regsvr32 $d failed"
    done
    q "$WINE" 'C:\windows\syswow64\regsvr32.exe' /s \
        'C:\Program Files (x86)\Common Files\Microsoft Shared\dao\dao360.dll' >/dev/null 2>&1 || true
    echo "        installed and registered"
fi
# What odbcconf would have written from jetodbc.rsp.  Wine's odbcconf does not
# implement INSTALLDRIVER, so it is written directly.
cat > "$work/jetodbc.reg" <<'EOF'
REGEDIT4

[HKEY_LOCAL_MACHINE\SOFTWARE\ODBC\ODBCINST.INI\ODBC Drivers]
"Microsoft Access Driver (*.mdb)"="Installed"

[HKEY_LOCAL_MACHINE\SOFTWARE\ODBC\ODBCINST.INI\Microsoft Access Driver (*.mdb)]
"Driver"="C:\\windows\\system32\\odbcjt32.dll"
"Setup"="C:\\windows\\system32\\odbcjt32.dll"
"APILevel"="1"
"ConnectFunctions"="YYN"
"DriverODBCVer"="02.50"
"FileExtns"="*.mdb"
"FileUsage"="2"
"SQLLevel"="0"
"UsageCount"=dword:00000001
EOF
regimport "$work/jetodbc.reg" 32
echo "        Access ODBC driver registered"

echo
echo "== 7/8  MDAC 2.8 ODBC driver manager, for PSI.exe only"
# Wine's odbc32 reaches Jet's odbcjt32 fine, but that driver is ODBC 3.x and
# exports none of the 2.x entry points PSI's MFC 7.1 database classes call
# (SQLSetStmtOption for the cursor type, SQLErrorW, ...).  Microsoft's driver
# manager maps them; Wine's does not (not even Wine master).  So PSI gets the
# native one, beside PSI.exe and overridden for PSI.exe alone.
ODBC_DLLS="odbc32.dll odbccp32.dll odbcint.dll odbc32gt.dll odbccu32.dll odbccr32.dll odbctrac.dll ds32gt.dll"
if [ -f "$PSIDIR/odbc32.dll" ] && [ -f "$PSIDIR/odbcint.dll" ]; then
    echo "        already installed"
else
    mdac="$(fetch "$MDAC_URL" "$MDAC_SHA" MDAC_TYP.EXE)"
    mkdir -p "$work/mdac" "$work/mdaccab"
    q "$WINE" "$(win "$mdac")" /C "/T:$(win "$work/mdac")" /Q >/dev/null 2>&1
    q "$WINE" extrac32 /e /l "$(win "$work/mdaccab")" "$(win "$work/mdac/mdacxpak.cab")" >/dev/null 2>&1
    for f in $ODBC_DLLS; do
        hit="$(find "$work/mdaccab" -maxdepth 1 -iname "$f" | head -1)"
        [ -n "$hit" ] || { echo "MDAC is missing $f"; exit 1; }
        cp "$hit" "$PSIDIR/$f"
    done
    echo "        installed beside PSI.exe"
fi
{
    printf 'REGEDIT4\n\n[HKEY_CURRENT_USER\\Software\\Wine\\AppDefaults\\PSI.exe\\DllOverrides]\n'
    for f in $ODBC_DLLS; do printf '"%s"="native,builtin"\n' "${f%.dll}"; done
} > "$work/override.reg"
regimport "$work/override.reg"
echo "        DLL overrides set for PSI.exe"

echo
echo "== 8/8  PSI settings"
# What the PSI installer and install_v4.ps1 write, less what is Windows-only.
# LoadFirmwareAtStartup*: PSI otherwise asks at every start whether to run
# TLB's PIC firmware updater.  pakonusb.py refuses that path regardless.
cat > "$work/psi.reg" <<'EOF'
REGEDIT4

[HKEY_LOCAL_MACHINE\SOFTWARE\Pakon\PSI\Setup]
"ProgramPath"="C:\\Program Files\\Pakon\\PSI"
"ContactEnabled"=dword:00000000
"SleeveEnabled"=dword:00000000
"SaveAsEnabled"=dword:00000000

[HKEY_LOCAL_MACHINE\SOFTWARE\Pakon\PSI\IQueue II]
"StartIQueue"=dword:00000000

[HKEY_LOCAL_MACHINE\SOFTWARE\Pakon\PSI\Scanner Settings]
"LoadFirmwareAtStartup"=dword:00000000
"LoadFirmwareAtStartupAlways"=dword:00000000

[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\PSI.exe]
@="C:\\Program Files\\Pakon\\PSI\\PSI.exe"
"Path"="C:\\Program Files\\Pakon\\"
EOF
regimport "$work/psi.reg" 32
echo "        registry written"

# PakonImau's own imports (ekjpegi, KODAKCMS, xerces ...) sit in the COM
# server directory.  The TLX client runs from there so it finds them; PSI runs
# from its own directory and fails with EC_WIN_LoadLibrary (178) naming
# PakonImau.dll.  A Windows install puts them in System32; here the directory
# goes on the system PATH instead.
ENVKEY='HKLM\System\CurrentControlSet\Control\Session Manager\Environment'
cur="$(q "$WINE" reg query "$ENVKEY" /v PATH 2>/dev/null | tr -d '\r' \
       | sed -n 's/^ *PATH *REG_[A-Z_]* *//p')"
case "$cur" in
    *"F-X35 COM Server"*) echo "        PATH already includes the COM server" ;;
    *)  q "$WINE" reg add "$ENVKEY" /v PATH /t REG_EXPAND_SZ \
            /d "$cur;C:\\Program Files\\Pakon\\F-X35 COM Server" /f >/dev/null 2>&1
        echo "        COM server directory added to PATH" ;;
esac

# Juan's RAW16 extraction stages frames here.
mkdir -p "$WINEPREFIX/drive_c/ProgramData/Pakon/Temp"
echo "        created C:\\ProgramData\\Pakon\\Temp"

# Light calibration lives only in the registry.  If the TLX prefix has run a
# Light Correction and this one has not, carry it over rather than make the
# user redo it; it is the same engine and the same scanner.
flush
if ! grep -aq 'Pakon\\\\TLB\\\\Scan\\\\DpiBase' "$WINEPREFIX/system.reg" 2>/dev/null \
   && [ -z "${PAKON_PSI_NO_CAL_IMPORT:-}" ] \
   && grep -aq '"FullLightCorrections"=dword:[1-9a-f]' "$TLX_PREFIX/system.reg" 2>/dev/null; then
    WINEPREFIX="$TLX_PREFIX" q "$WINE" reg export 'HKLM\Software\Pakon\TLB\Scan' \
        "$(win "$work/scan.reg")" /reg:32 /y >/dev/null 2>&1 || true
    WINEPREFIX="$TLX_PREFIX" q "$WS" -k >/dev/null 2>&1 || true
    if [ -s "$work/scan.reg" ]; then
        regimport "$work/scan.reg" 32
        echo "        light calibration copied from $TLX_PREFIX"
    fi
fi
flush

cat <<EOF

Done.  Power on the scanner, then:  $ROOT/run.sh psi
If the light calibration was not copied, run PSI's light correction once with
the film gate empty.  See docs/PSI.md.
EOF
