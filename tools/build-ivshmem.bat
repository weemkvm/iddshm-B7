@echo off
setlocal EnableDelayedExpansion

:: ============================================================
::  build-ivshmem.bat
::
::  Patches kvm-guest-drivers-windows with randomized PCI IDs
::  and interface GUID, then builds the ivshmem driver.
::
::  Usage:
::    1. Clone kvm-guest-drivers-windows somewhere
::    2. Copy this script into the repo root (next to ivshmem\)
::    3. Open a VS 2022 Developer Command Prompt
::    4. Run:  build-ivshmem.bat
::
::  Outputs:
::    ivshmem\x64\Release\ivshmem.sys
::    ivshmem\x64\Release\ivshmem.inf
::    hwid.txt  (your generated values -- keep this)
:: ============================================================

:: Check we're in the right place
if not exist "ivshmem\ivshmem.inf" (
    echo ERROR: Run this from the kvm-guest-drivers-windows root.
    echo        ivshmem\ivshmem.inf not found.
    exit /b 1
)

:: Check MSBuild is available
where msbuild >nul 2>&1
if errorlevel 1 (
    echo ERROR: msbuild not found. Run from a VS 2022 Developer Command Prompt.
    exit /b 1
)

echo.
echo ============================================================
echo  IDDShm ivshmem driver builder
echo ============================================================
echo.

:: -----------------------------------------------------------
::  Generate random PCI device ID and interface GUID
:: -----------------------------------------------------------

echo Generating random hardware identifiers...

:: Use PowerShell for random values
for /f "delims=" %%A in ('powershell -NoProfile -Command "$did = Get-Random -Minimum 0xA000 -Maximum 0xFFFF; '0x{0:X4}' -f $did"') do set DEVICE_ID=%%A
for /f "delims=" %%A in ('powershell -NoProfile -Command "[guid]::NewGuid().ToString()"') do set IFACE_GUID=%%A

:: Extract GUID components for DEFINE_GUID macro
for /f "delims=" %%A in ('powershell -NoProfile -Command ^
    "$g = [guid]'%IFACE_GUID%'; $b = $g.ToByteArray(); " ^
    "'0x{0:x8},0x{1:x4},0x{2:x4},0x{3:x2},0x{4:x2},0x{5:x2},0x{6:x2},0x{7:x2},0x{8:x2},0x{9:x2},0x{10:x2}' -f " ^
    "[BitConverter]::ToUInt32($b,0),[BitConverter]::ToUInt16($b,4),[BitConverter]::ToUInt16($b,6)," ^
    "$b[8],$b[9],$b[10],$b[11],$b[12],$b[13],$b[14],$b[15]"') do set GUID_MACRO=%%A

:: Format device ID without 0x prefix for INF
for /f "delims=" %%A in ('powershell -NoProfile -Command "'%DEVICE_ID%'.Replace('0x','')"') do set DEVICE_ID_BARE=%%A

echo.
echo   PCI Vendor ID : 0x8086 (Intel)
echo   PCI Device ID : %DEVICE_ID%
echo   Interface GUID: {%IFACE_GUID%}
echo.

:: -----------------------------------------------------------
::  Save generated values
:: -----------------------------------------------------------

(
    echo # IDDShm generated hardware identifiers
    echo # Keep this file -- you need these values for QEMU and ElgDisp
    echo #
    echo # QEMU ivshmem-plain args:
    echo #   vendor-id=0x8086,device-id=%DEVICE_ID%
    echo #
    echo # vendor/ivshmem/ivshmem.h GUID line:
    echo #   DEFINE_GUID(GUID_DEVINTERFACE_IVSHMEM, %GUID_MACRO%);
    echo #
    echo PCI_VENDOR_ID=0x8086
    echo PCI_DEVICE_ID=%DEVICE_ID%
    echo IFACE_GUID={%IFACE_GUID%}
    echo GUID_MACRO=%GUID_MACRO%
) > hwid.txt

echo Saved identifiers to hwid.txt

:: -----------------------------------------------------------
::  Patch ivshmem.inf -- hardware ID
:: -----------------------------------------------------------

echo Patching ivshmem\ivshmem.inf...

powershell -NoProfile -Command ^
    "$f = Get-Content 'ivshmem\ivshmem.inf' -Raw; " ^
    "$f = $f -replace 'PCI\\VEN_[0-9A-Fa-f]{4}&DEV_[0-9A-Fa-f]{4}', 'PCI\VEN_8086&DEV_%DEVICE_ID_BARE%'; " ^
    "Set-Content 'ivshmem\ivshmem.inf' $f -NoNewline"

:: -----------------------------------------------------------
::  Patch ivshmem.h -- interface GUID
:: -----------------------------------------------------------

echo Patching ivshmem\ivshmem.h...

powershell -NoProfile -Command ^
    "$f = Get-Content 'ivshmem\ivshmem.h' -Raw; " ^
    "$pattern = 'DEFINE_GUID\s*\(\s*GUID_DEVINTERFACE_IVSHMEM\s*,\s*[^)]+\)'; " ^
    "$replacement = 'DEFINE_GUID(GUID_DEVINTERFACE_IVSHMEM, %GUID_MACRO%)'; " ^
    "$f = [regex]::Replace($f, $pattern, $replacement); " ^
    "Set-Content 'ivshmem\ivshmem.h' $f -NoNewline"

:: -----------------------------------------------------------
::  Build
:: -----------------------------------------------------------

echo.
echo Building ivshmem driver (Release x64)...
echo.

msbuild ivshmem\ivshmem.vcxproj /p:Configuration=Release /p:Platform=x64 /v:minimal
if errorlevel 1 (
    echo.
    echo BUILD FAILED
    exit /b 1
)

echo.
echo ============================================================
echo  Build complete
echo ============================================================
echo.
echo   Driver:  ivshmem\x64\Release\ivshmem.sys
echo   INF:     ivshmem\x64\Release\ivshmem.inf
echo   Config:  hwid.txt
echo.
echo Next steps:
echo   1. Copy ivshmem.sys + ivshmem.inf to the guest
echo   2. Update your IDDShm repo:
echo      - vendor/ivshmem/ivshmem.h GUID must match (see hwid.txt)
echo      - QEMU args must use: vendor-id=0x8086,device-id=%DEVICE_ID%
echo   3. Rebuild ElgDisp.dll with the matching GUID
echo   4. Run: dse-patcher.exe ivshmem.inf
echo.
