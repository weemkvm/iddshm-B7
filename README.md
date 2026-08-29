# IDDShm-B7

A fork of [Looking Glass](https://github.com/gnif/LookingGlass) (B7 tree) that
replaces the guest-side capture with a rebranded **Indirect Display Driver**
(IDD). The Windows guest presents a virtual display through the IDD and pushes
KVMFR frames over shared memory (ivshmem/kvmfr) to the host client.

> **Status: work in progress.** This is kinda AI slop, honest to god. It works
> as a *base* to continue from, not as a finished product. I'll attempt to keep
> updating it as I have time.

---

## Stealth Identity

All driver-facing identifiers have been renamed to avoid detection:

| Original | Renamed |
|---|---|
| `IDDShm.dll` | `ElgDisp.dll` |
| `IDDShm` service | `ElgDisp` |
| `IDDShmGroup` registry group | `ElgDispGrp` |
| `"IDD Cx Shared Memory Display"` | `"Elgato Virtual Display Adapter"` |
| `"Looking Glass"` endpoint name | `"Elgato Video Capture"` |
| `SOFTWARE\Looking Glass` reg key | `SOFTWARE\Elgato Systems` |
| `GUID_DEVINTERFACE_IDDShm` | `GUID_DEVINTERFACE_ElgDisp` (fresh GUID) |
| WPP trace GUID | Fresh random GUID |
| PCI kvmfr IDs | `8086:C0A5` (Intel, unmapped DID) |

Elgato is a real IDD vendor (their capture card drivers create virtual displays),
so this identity blends in on a gaming PC.

---

## Repo Layout

```
idd/LGIdd/          Windows IDD driver (UMDF2, builds with VS 2022 + WDK)
  IDDShm.inf        → builds as ElgDisp.inf / ElgDisp.dll
module/             Linux kvmfr kernel module
host/               IDDShmHost service (Windows/Linux)
client/             Looking Glass client (Linux host side)
tools/dse-patcher/  Unsigned driver installer (DSE bypass via RTCore64)
vendor/             Third-party headers (ivshmem, directx, getopt)
```

---

## Prerequisites

### Linux Host

- QEMU 8+ (project uses custom build at `/opt/AutoVirt/emulator/`)
- `kvmfr` kernel module built and loaded (see below)
- libvirt / virsh

### Windows Guest (Win11 23H2)

- Visual Studio 2022 with **Windows Driver Kit (WDK)** — matching SDK version
- **HVCI (Memory Integrity) must be OFF** — Settings → Windows Security →
  Device Security → Core Isolation → Memory Integrity → Off. Reboot.
  Without this, RTCore64 cannot write to kernel memory.
- Administrator shell for driver installation

---

## Step 1 — Build the Linux kvmfr Module

```bash
cd module/
make -C /lib/modules/$(uname -r)/build M=$(pwd) modules

# Install
sudo insmod kvmfr.ko static_size_mb=32
# or add to /etc/modules-load.d/ for persistence
```

Verify `/dev/kvmfr0` exists:

```bash
ls -la /dev/kvmfr0
sudo chmod 660 /dev/kvmfr0
sudo chown $USER:kvm /dev/kvmfr0
```

For persistence across reboots create `/etc/modprobe.d/kvmfr.conf`:

```
options kvmfr static_size_mb=32
```

And `/etc/modules-load.d/kvmfr.conf`:

```
kvmfr
```

---

## Step 2 — Wire the ivshmem Device into the VM XML

Add the following inside the `<qemu:commandline>` block of your VM XML
(`virsh edit <vmname>`). This creates the shared memory PCI device backed
by `/dev/kvmfr0` and presents it to the guest as `8086:C0A5`:

```xml
<qemu:arg value='-object'/>
<qemu:arg value='memory-backend-file,id=kvmfr0mem,share=on,mem-path=/dev/kvmfr0,size=32M'/>
<qemu:arg value='-device'/>
<qemu:arg value='ivshmem-plain,id=kvmfr0,memdev=kvmfr0mem,bus=pcie.0,addr=0x10,vendor-id=0x8086,device-id=0xC0A5'/>
```

> **Note:** `addr=0x10` must be a free PCIe slot. Adjust if you get a conflict.
> Check with `virsh dumpxml <vmname> | grep "slot="` to find used slots.

---

## Step 3 — Build the Windows IDD Driver

On the Windows guest (or a Windows build machine with VS 2022 + WDK installed):

1. Open `idd\LGIdd.sln` in Visual Studio 2022
2. Select **Release | x64**
3. Build → the output is `x64\Release\ElgDisp.dll` and `ElgDisp.inf`

> The INF references `ElgDisp.cat` but no catalog is generated — that is
> intentional. The DSE patcher handles signature enforcement bypass.

---

## Step 4 — Build the Windows IVSHMEM Guest Driver

The guest needs an IVSHMEM driver that publishes the custom interface GUID
`{8f008348-dfa6-43bc-8e2f-6ceb67577fc6}` and matches PCI ID `8086:C0A5`.

**Option A — Patch the upstream ivshmem-win driver (recommended):**

1. Clone [ivshmem-win](https://github.com/virtio-win/kvm-guest-drivers-windows)
2. In `ivshmem/ivshmem.inf`, change the hardware ID line from:
   ```
   %ivshmem.DeviceDesc%=ivshmem_Device, PCI\VEN_1AF4&DEV_1110
   ```
   to:
   ```
   %ivshmem.DeviceDesc%=ivshmem_Device, PCI\VEN_8086&DEV_C0A5
   ```
3. In `ivshmem/ivshmem.h`, replace `GUID_DEVINTERFACE_IVSHMEM` with:
   ```c
   DEFINE_GUID(GUID_DEVINTERFACE_IVSHMEM,
     0x8f008348,0xdfa6,0x43bc,0x8e,0x2f,0x6c,0xeb,0x67,0x57,0x7f,0xc6);
   ```
4. Build with VS 2022 + WDK. Output: `ivshmem.sys` + `ivshmem.inf`

The resulting driver must also be installed via the DSE patcher (same process,
just pass its INF instead of ElgDisp.inf).

---

## Step 5 — Build the DSE Patcher (from Linux host)

```bash
cd tools/dse-patcher/
make
# Output: dse-patcher.exe
```

Requires `x86_64-w64-mingw32-gcc` (install with `pacman -S mingw-w64-gcc` on
Arch/CachyOS, or `apt install gcc-mingw-w64-x86-64` on Debian/Ubuntu).

---

## Step 6 — Install Drivers in the Guest

Transfer to the Windows guest (shared folder, USB, whatever):
- `dse-patcher.exe`
- `RTCore64.sys` — from MSI Afterburner install dir:
  `C:\Program Files (x86)\MSI Afterburner\RTCore64.sys`
  (or download MSI Afterburner and grab it from the installer)
- `ElgDisp.dll` + `IDDShm.inf` (the INF file is still named IDDShm.inf on disk;
  rename it to `ElgDisp.inf` before running)
- `ivshmem.sys` + `ivshmem.inf` (from Step 4)

### Install IVSHMEM driver first

Open an **Administrator** CMD or PowerShell:

```bat
:: Disable HVCI first if not done (Settings > Windows Security > Core Isolation)
:: Then run:

dse-patcher.exe ivshmem.inf
```

Wait for success message. Check Device Manager — a device should appear under
**System devices** with hardware ID `PCI\VEN_8086&DEV_C0A5`.

### Install ElgDisp IDD driver

```bat
dse-patcher.exe ElgDisp.inf
```

Check Device Manager → **Display adapters** → `"Elgato Virtual Display Adapter"`
should appear.

If the device appears with a yellow exclamation:
- Code 52 (unsigned) → HVCI is still on, disable it and retry
- Code 10 (failed to start) → check Event Viewer → System for IDD errors

---

## Step 7 — Install the IDDShmHost on the Guest

The host service (`host/`) runs on the **Windows guest** side (despite the name
"host" — it's the host of the display data, not the KVM host):

```bat
IDDShmHost.exe --install
net start IDDShmHost
```

Configure `IDDShmHost.ini` to point at the correct ivshmem device index if
you have multiple ivshmem devices.

---

## Step 8 — Start the Client on the Linux Host

```bash
# Build the client
cd client/
mkdir build && cd build
cmake ..
make -j$(nproc)

# Run
./looking-glass-client
```

The client connects to `/dev/kvmfr0` directly. It should pick up frames from
the guest once IDDShmHost is running and ElgDisp is presenting frames.

---

## QEMU ivshmem Device Note

QEMU 8+ supports the `vendor-id`/`device-id` arguments on `ivshmem-plain`.
If your build doesn't (error: unknown property `vendor-id`), you need to either:
- Build QEMU from source with the ivshmem PCI ID patch, or
- Use the custom QEMU at `/opt/AutoVirt/emulator/` which already has it

---

## What's Missing / Next Steps

- Windows IVSHMEM guest driver source not included (must build from kvm-guest-drivers-windows)
- QEMU ivshmem-doorbell variant for interrupt-driven frame notification (currently polling)
- Proper EDID injection for the virtual monitor (currently reports generic modes)
- The `shmDevice` registry value under `SOFTWARE\Elgato Systems` selects which
  ivshmem device to use — needs to be set if more than one is present

---

## Upstream

- Looking Glass: https://github.com/gnif/LookingGlass
- Docs: https://looking-glass.io

License: GPLv2 (inherited from Looking Glass).