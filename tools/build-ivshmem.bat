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
::    ivshmem\x64\Win11Release\ivshmem.sys
::    ivshmem\ivshmem.inf  (patched)
::    hwid.txt  (your generated values -- keep this)
:: ============================================================

:: Check we're in the right place
if not exist "ivshmem\ivshmem.inf" (
    echo ERROR: Run this from the kvm-guest-drivers-windows root.
    echo        ivshmem\ivshmem.inf not found.
    exit /b 1
)

if not exist "ivshmem\Public.h" (
    echo ERROR: ivshmem\Public.h not found.
    echo        Make sure this is a full kvm-guest-drivers-windows checkout.
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
    echo #   DEFINE_GUID(GUID_DEVINTERFACE_IVSHMEM, %GUID_MACRO%^);
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
::  Patch Public.h -- interface GUID
:: -----------------------------------------------------------

echo Patching ivshmem\Public.h...

powershell -NoProfile -Command ^
    "$f = Get-Content 'ivshmem\Public.h' -Raw; " ^
    "$pattern = 'DEFINE_GUID\s*\(\s*GUID_DEVINTERFACE_IVSHMEM\s*,\s*[^)]+\)'; " ^
    "$replacement = 'DEFINE_GUID(GUID_DEVINTERFACE_IVSHMEM, %GUID_MACRO%)'; " ^
    "$f = [regex]::Replace($f, $pattern, $replacement); " ^
    "Set-Content 'ivshmem\Public.h' $f -NoNewline"

:: -----------------------------------------------------------
::  Build
:: -----------------------------------------------------------

echo.
echo Building ivshmem driver (Win11 Release x64)...
echo.

msbuild ivshmem\ivshmem.vcxproj /p:Configuration="Win11 Release" /p:Platform=x64 /v:minimal
if errorlevel 1 (
    echo.
    echo Win11 config failed, trying Win10 Release...
    echo.
    msbuild ivshmem\ivshmem.vcxproj /p:Configuration="Win10 Release" /p:Platform=x64 /v:minimal
    if errorlevel 1 (
        echo.
        echo BUILD FAILED
        echo.
        echo Make sure you have:
        echo   - Visual Studio 2022 with C++ desktop workload
        echo   - Windows Driver Kit (WDK) matching your SDK version
        echo   - Running from a Developer Command Prompt
        exit /b 1
    )
    set BUILD_CONFIG=Win10Release
) else (
    set BUILD_CONFIG=Win11Release
)

:: Find the output
set OUT_DIR=ivshmem\x64\!BUILD_CONFIG!
if not exist "!OUT_DIR!\ivshmem.sys" (
    set OUT_DIR=ivshmem\x64\Win11 Release
    if not exist "!OUT_DIR!\ivshmem.sys" (
        set OUT_DIR=ivshmem\x64\Win10 Release
    )
)

echo.
echo ============================================================
echo  Build complete
echo ============================================================
echo.
echo   Driver:  !OUT_DIR!\ivshmem.sys
echo   INF:     ivshmem\ivshmem.inf (patched)
echo   Config:  hwid.txt
echo.
echo Next steps:
echo   1. Copy ivshmem.sys + patched ivshmem.inf into the guest
echo   2. Update your IDDShm repo:
echo      - vendor/ivshmem/ivshmem.h GUID must match (see hwid.txt)
echo      - QEMU args must use: vendor-id=0x8086,device-id=%DEVICE_ID%
echo   3. Rebuild ElgDisp.dll with the matching GUID
echo   4. In the guest: dse-patcher.exe ivshmem.inf
echo.
