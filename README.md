# IDDShm-B7

A fork of [Looking Glass](https://github.com/gnif/LookingGlass) (B7 tree) that
replaces the guest-side capture with a rebranded **Indirect Display Driver**
(IDD). The Windows guest presents a virtual display through the IDD and pushes
KVMFR frames over shared memory (ivshmem/kvmfr) to the host client.

> **Status: work in progress.** Honest to god this is AI slop as a base.
> It works — continue from here, don't ship it as-is.

---

## Stealth Identity

All driver-facing identifiers are renamed to blend in:

| Original | Renamed |
|---|---|
| `IDDShm.dll` | `ElgDisp.dll` |
| `IDDShm` service | `ElgDisp` |
| `"IDD Cx Shared Memory Display"` | `"Elgato Virtual Display Adapter"` |
| `"Looking Glass"` endpoint strings | `"Elgato Video Capture"` |
| `SOFTWARE\Looking Glass` reg key | `SOFTWARE\Elgato Systems` |
| `GUID_DEVINTERFACE_IDDShm` | `GUID_DEVINTERFACE_ElgDisp` (fresh GUID) |
| kvmfr PCI IDs | `8086:C0A5` (Intel, no inbox driver) |

Elgato is a real IDD vendor — their capture card drivers create virtual displays,
so this identity is invisible on a gaming PC.

---

## Repo Layout

```
idd/LGIdd/          Windows IDD driver (UMDF2, VS 2022 + WDK)
module/             Linux kvmfr kernel module
host/               IDDShmHost service
client/             Looking Glass client (Linux host side)
tools/dse-patcher/  Unsigned driver installer (DSE bypass, RTCore64 vector)
vendor/             Third-party headers
```

---

## Quick Start — Using Pre-Built Releases

> If you just want to wire this in, grab the release and skip to the guest
> install steps. No build environment needed on the guest.

### What you need

1. **Release archive** — download `iddshm-B7-vX.X-guest-drivers.zip` from
   [Releases](https://github.com/weemkvm/iddshm-B7/releases)
   and extract it. Contains:
   - `dse-patcher.exe`
   - `ElgDisp.dll` + `ElgDisp.inf`
   - `ivshmem.sys` + `ivshmem.inf`

2. **RTCore64.sys** — not bundled in the release (closed binary).
   Get it from your MSI Afterburner installation:
   ```
   C:\Program Files (x86)\MSI Afterburner\RTCore64.sys
   ```
   If Afterburner isn't installed, download it, run the installer, grab the
   file, then uninstall. Place `RTCore64.sys` in the same folder as
   `dse-patcher.exe`.

3. **HVCI must be OFF** in the guest before running the patcher:
   Settings → Windows Security → Device Security → Core Isolation →
   Memory Integrity → **Off** → Reboot

### Step 1 — Linux host: load kvmfr

```bash
# Build against your running kernel
cd module/
make -C /lib/modules/$(uname -r)/build M=$(pwd) modules

# Load (32 MiB static region)
sudo insmod kvmfr.ko static_size_mb=32

# Set permissions
sudo chmod 660 /dev/kvmfr0
sudo chown $USER:kvm /dev/kvmfr0
```

For persistence, create `/etc/modprobe.d/kvmfr.conf`:
```
options kvmfr static_size_mb=32
```
And `/etc/modules-load.d/kvmfr.conf`:
```
kvmfr
```

### Step 2 — Linux host: add ivshmem to the VM XML

`virsh edit <vmname>` — add inside the existing `<qemu:commandline>` block:

```xml
<qemu:arg value='-object'/>
<qemu:arg value='memory-backend-file,id=kvmfr0mem,share=on,mem-path=/dev/kvmfr0,size=32M'/>
<qemu:arg value='-device'/>
<qemu:arg value='ivshmem-plain,id=kvmfr0,memdev=kvmfr0mem,bus=pcie.0,addr=0x10,vendor-id=0x8086,device-id=0xC0A5'/>
```

> `addr=0x10` must be a free PCIe slot. Check used slots with:
> `virsh dumpxml <vmname> | grep "slot="`

### Step 3 — Windows guest: install the IVSHMEM driver

Transfer the release folder + `RTCore64.sys` into the guest.
Open an **Administrator** CMD:

```bat
dse-patcher.exe ivshmem.inf
```

Expected output ends with `SUCCESS`. Check Device Manager → System devices →
a device should appear matching `PCI\VEN_8086&DEV_C0A5`.

### Step 4 — Windows guest: install the ElgDisp IDD driver

```bat
dse-patcher.exe ElgDisp.inf
```

Check Device Manager → Display adapters → `"Elgato Virtual Display Adapter"`.

**Troubleshooting:**
- **Code 52** (unsigned) → HVCI is still enabled. Turn it off and retry.
- **Code 10** (device failed to start) → check Event Viewer → System for IDD errors.
- **pnputil non-zero exit** → run as Administrator, not just elevated.

### Step 5 — Windows guest: start IDDShmHost

```bat
IDDShmHost.exe --install
net start IDDShmHost
```

### Step 6 — Linux host: start the client

```bash
cd client/build/
./looking-glass-client
```

---

## Building From Source

### Requirements

**Linux host:**
- `x86_64-w64-mingw32-gcc` (for DSE patcher cross-compile)
  - Arch/CachyOS: `sudo pacman -S mingw-w64-gcc`
  - Debian/Ubuntu: `sudo apt install gcc-mingw-w64-x86-64`
- Kernel headers matching your running kernel
- CMake, GCC (for host/client)

**Windows (for IDD driver):**
- Visual Studio 2022
- Windows Driver Kit (WDK) — matching SDK version
- Must build on Windows; UMDF drivers cannot be cross-compiled

---

### Build: kvmfr kernel module (Linux)

```bash
cd module/
make -C /lib/modules/$(uname -r)/build M=$(pwd) modules
# Output: kvmfr.ko
```

---

### Build: DSE patcher (Linux → Windows EXE)

```bash
cd tools/dse-patcher/
make
# Output: dse-patcher.exe
```

---

### Build: ElgDisp IDD driver (Windows)

1. Open `idd\LGIdd.sln` in Visual Studio 2022
2. Build → **Release | x64**
3. Output: `x64\Release\ElgDisp.dll`
4. Rename `IDDShm.inf` → `ElgDisp.inf` (or copy alongside the DLL)

---

### Build: IVSHMEM guest driver (Windows)

The guest needs an IVSHMEM driver patched for PCI ID `8086:C0A5` and our
custom interface GUID `{8f008348-dfa6-43bc-8e2f-6ceb67577fc6}`.

1. Clone [kvm-guest-drivers-windows](https://github.com/virtio-win/kvm-guest-drivers-windows)
2. In `ivshmem\ivshmem.inf` change the hardware ID:
   ```
   %ivshmem.DeviceDesc%=ivshmem_Device, PCI\VEN_8086&DEV_C0A5
   ```
3. In `ivshmem\ivshmem.h` replace the interface GUID:
   ```c
   DEFINE_GUID(GUID_DEVINTERFACE_IVSHMEM,
     0x8f008348,0xdfa6,0x43bc,0x8e,0x2f,0x6c,0xeb,0x67,0x57,0x7f,0xc6);
   ```
4. Build with VS 2022 + WDK. Output: `ivshmem.sys` + `ivshmem.inf`

Install the same way as ElgDisp — via `dse-patcher.exe ivshmem.inf`.

---

### Build: Looking Glass client (Linux)

```bash
cd client/
mkdir build && cd build
cmake ..
make -j$(nproc)
# Output: looking-glass-client
```

---

## Packaging a Release

Structure for `iddshm-B7-vX.X-guest-drivers.zip`:

```
iddshm-B7-vX.X-guest-drivers.zip
├── dse-patcher.exe       ← from tools/dse-patcher/make
├── ElgDisp.dll           ← from VS build (x64/Release/)
├── ElgDisp.inf           ← renamed IDDShm.inf
├── ivshmem.sys           ← patched build
└── ivshmem.inf           ← patched INF
```

> Do **not** bundle `RTCore64.sys` in public releases.

---

## QEMU Version Note

The `vendor-id`/`device-id` args on `ivshmem-plain` require QEMU 8+. If your
distro QEMU doesn't support them (unknown property error), use the custom build
at `/opt/AutoVirt/emulator/bin/qemu-system-x86_64` which has the patch.

---

## What's Missing / Next Steps

- IVSHMEM guest driver source not included — must build from kvm-guest-drivers-windows
- ivshmem-doorbell variant for interrupt-driven frames (currently polling)
- EDID injection for the virtual monitor
- `shmDevice` under `SOFTWARE\Elgato Systems` selects ivshmem device index
  when multiple devices are present — default is 0

---

## Upstream

- Looking Glass: https://github.com/gnif/LookingGlass
- Docs: https://looking-glass.io

License: GPLv2 (inherited from Looking Glass).