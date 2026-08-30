![IDDShm-B7](iddshm.jpg)

<div align="center">

# IDDShm-B7

**A Looking Glass B7 fork that replaces guest-side capture with a rebranded Indirect Display Driver.**

[![License: GPLv2](https://img.shields.io/badge/License-GPLv2-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Host-Linux%20KVM-informational)](https://looking-glass.io)
[![Guest](https://img.shields.io/badge/Guest-Windows%2011-informational)](https://looking-glass.io)
[![Status](https://img.shields.io/badge/Status-WIP-yellow)](https://github.com/weemkvm/iddshm-B7)

The Windows guest presents a virtual display through a UMDF Indirect Display Driver, pushing KVMFR frames over shared memory directly to the Linux host client.

</div>

---

## Table of Contents

- [How It Works](#how-it-works)
- [Stealth Identity](#stealth-identity)
- [Prerequisites](#prerequisites)
- [Build Guide](#build-guide)
  - [1. Patch QEMU](#1-patch-qemu)
  - [2. Build kvmfr kernel module](#2-build-kvmfr-kernel-module)
  - [3. Build the client](#3-build-the-client)
  - [4. Build the ivshmem guest driver](#4-build-the-ivshmem-guest-driver)
  - [5. Build ElgDisp IDD driver](#5-build-elgdisp-idd-driver)
  - [6. Build DSE patcher](#6-build-dse-patcher)
- [Setup](#setup)
  - [Step 1 — Load kvmfr](#step-1--load-kvmfr)
  - [Step 2 — Wire ivshmem into VM](#step-2--wire-ivshmem-into-vm)
  - [Step 3 — Install ivshmem driver (guest)](#step-3--install-ivshmem-driver-guest)
  - [Step 4 — Install ElgDisp IDD driver (guest)](#step-4--install-elgdisp-idd-driver-guest)
  - [Step 5 — Start IDDShmHost (guest)](#step-5--start-iddshmhost-guest)
  - [Step 6 — Start the client (host)](#step-6--start-the-client-host)
- [Troubleshooting](#troubleshooting)
- [Repo Layout](#repo-layout)
- [Upstream](#upstream)

---

## How It Works

```
┌─────────────────────────────────┐      ┌──────────────────────────────────┐
│         Windows Guest           │      │           Linux Host             │
│                                 │      │                                  │
│  ElgDisp.dll (UMDF IDD)         │      │  iddshm-client                   │
│    │ captures swapchain frames  │      │    │ reads frames from kvmfr0    │
│    ▼                            │      │    ▼                             │
│  IDDShmHost.exe                 │      │  /dev/kvmfr0  ◄─────────────┐   │
│    │ pushes LGMP frames         │      │  kvmfr.ko (kernel module)   │   │
│    ▼                            │      └─────────────────────────────│───┘
│  IVSHMEM device ────────────────────────── ivshmem-plain QEMU device─┘
│    shared memory region (32 MiB)│
└─────────────────────────────────┘
```

---

## Stealth Identity

Every string visible to the OS is renamed to blend in as a common peripheral driver.
PCI IDs and interface GUIDs are **randomized per build** — each user generates their
own unique identifiers, so no two installs share a fingerprint.

The included `tools/build-ivshmem.bat` handles ID generation and patching automatically.

| Component | Renamed To |
|:---|:---|
| Driver DLL | `ElgDisp.dll` |
| Service name | `ElgDisp` |
| Device group | `ElgDispGrp` |
| Display name | Generic display adapter string |
| Registry path | Non-LG vendor path |
| PCI device ID | Random per build |
| Interface GUID | Random per build |

---

## Prerequisites

### Linux Host
- QEMU 8+ (with the ivshmem PCI ID patch — see [Build Guide](#1-patch-qemu))
- Kernel headers for your running kernel
- `x86_64-w64-mingw32-gcc` (for building the DSE patcher)

### Windows Guest
- Windows 11 (tested on 23H2)
- Visual Studio 2022 + Windows Driver Kit (WDK) + matching SDK
- **HVCI (Memory Integrity) must be OFF**
  > Settings → Windows Security → Device Security → Core Isolation → Memory Integrity → **Off** → Reboot
- **RTCore64.sys** from MSI Afterburner (`C:\Program Files (x86)\MSI Afterburner\RTCore64.sys`)
- Administrator shell for all driver install steps

---

## Build Guide

### 1. Patch QEMU

Stock QEMU does not allow setting custom PCI vendor/device IDs on `ivshmem-plain`.
You need to add two properties to the ivshmem-plain device type.

In your QEMU source tree, edit `hw/misc/ivshmem-pci.c`:

**Add fields to `IVShmemState`:**
```c
struct IVShmemState {
    PCIDevice parent_obj;

    uint32_t features;
    uint16_t user_vendor_id;   // ← add
    uint16_t user_device_id;   // ← add
    // ... rest unchanged
```

**Add properties to `ivshmem_plain_properties`:**
```c
static const Property ivshmem_plain_properties[] = {
    DEFINE_PROP_ON_OFF_AUTO("master", IVShmemState, master, ON_OFF_AUTO_OFF),
    DEFINE_PROP_LINK("memdev", IVShmemState, hostmem, TYPE_MEMORY_BACKEND,
                     HostMemoryBackend *),
    DEFINE_PROP_UINT16("vendor-id", IVShmemState, user_vendor_id, 0),  // ← add
    DEFINE_PROP_UINT16("device-id", IVShmemState, user_device_id, 0),  // ← add
};
```

**Override PCI config in `ivshmem_plain_realize`, after `ivshmem_common_realize()`:**
```c
    ivshmem_common_realize(dev, errp);

    if (s->user_vendor_id) {
        pci_config_set_vendor_id(dev->config, s->user_vendor_id);
    }
    if (s->user_device_id) {
        pci_config_set_device_id(dev->config, s->user_device_id);
    }
```

Rebuild and install QEMU:
```bash
cd build/
ninja -j$(nproc)
sudo cp qemu-system-x86_64 /usr/local/bin/  # or wherever your QEMU lives
```

Verify the new properties exist:
```bash
qemu-system-x86_64 -device ivshmem-plain,help | grep -E 'vendor|device'
```

---

### 2. Build kvmfr kernel module

```bash
cd module/
make -C /lib/modules/$(uname -r)/build M=$(pwd) modules
```

Output: `kvmfr.ko`

---

### 3. Build the client

```bash
cd client/
cmake -B build -DDEVELOPER=1 .
make -C build -j$(nproc)
```

Output: `client/build/iddshm-client`

---

### 4. Build the ivshmem guest driver

The guest needs an IVSHMEM driver with randomized PCI IDs and interface GUID.
A build script handles this automatically.

1. Clone [kvm-guest-drivers-windows](https://github.com/virtio-win/kvm-guest-drivers-windows)
2. Copy `tools/build-ivshmem.bat` into the repo root
3. Open a **VS 2022 Developer Command Prompt**
4. Run:

```bat
build-ivshmem.bat
```

The script will:
- Generate a random PCI device ID and interface GUID
- Patch `ivshmem\ivshmem.inf` and `ivshmem\ivshmem.h`
- Build the driver
- Write `hwid.txt` with all generated values

Output: `ivshmem.sys`, `ivshmem.inf`, `hwid.txt`

> [!IMPORTANT]
> After building, update the matching files in this repo to use the same identifiers:
>
> 1. Edit `vendor/ivshmem/ivshmem.h` — replace the `DEFINE_GUID` line with the
>    one from `hwid.txt`
> 2. Note the PCI device ID from `hwid.txt` — you'll use it in QEMU args (Step 2 of Setup)
> 3. Rebuild ElgDisp so it links against the updated GUID

---

### 5. Build ElgDisp IDD driver

> [!IMPORTANT]
> Must be built on Windows. UMDF drivers cannot be cross-compiled.
> Build **after** updating `vendor/ivshmem/ivshmem.h` with your generated GUID.

1. Open `idd\LGIdd.sln` in Visual Studio 2022
2. Select **Release | x64**
3. Build
4. Output: `x64\Release\ElgDisp.dll`
5. Copy `idd\LGIdd\IDDShm.inf` alongside the DLL and rename to `ElgDisp.inf`

---

### 6. Build DSE patcher

Cross-compiled from Linux to Windows:

```bash
# Install MinGW if needed
# Arch/CachyOS:  sudo pacman -S mingw-w64-gcc
# Debian/Ubuntu: sudo apt install gcc-mingw-w64-x86-64

cd tools/dse-patcher/
make
```

Output: `dse-patcher.exe`

---

## Setup

### Step 1 — Load kvmfr

```bash
sudo insmod module/kvmfr.ko static_size_mb=32
sudo chmod 660 /dev/kvmfr0
sudo chown $USER:kvm /dev/kvmfr0
```

<details>
<summary>Persist across reboots</summary>

Create `/etc/modprobe.d/kvmfr.conf`:
```
options kvmfr static_size_mb=32
```

Create `/etc/modules-load.d/kvmfr.conf`:
```
kvmfr
```

</details>

> [!NOTE]
> If QEMU runs under libvirt, you may also need to add `/dev/kvmfr0` to the
> `cgroup_device_acl` list in `/etc/libvirt/qemu.conf` and restart libvirtd.

---

### Step 2 — Wire ivshmem into VM

`virsh edit <vmname>` — add inside the `<qemu:commandline>` block, using the PCI
device ID from your `hwid.txt`:

```xml
<qemu:arg value='-object'/>
<qemu:arg value='memory-backend-file,id=kvmfr0mem,share=on,mem-path=/dev/kvmfr0,size=32M'/>
<qemu:arg value='-device'/>
<qemu:arg value='ivshmem-plain,id=kvmfr0,memdev=kvmfr0mem,bus=pcie.0,addr=0x10,vendor-id=0x8086,device-id=YOUR_DEVICE_ID'/>
```

Replace `YOUR_DEVICE_ID` with the value from `hwid.txt` (e.g. `0xB7F3`).

> [!NOTE]
> `addr=0x10` must be a free PCIe slot. Check used slots:
> ```bash
> virsh dumpxml <vmname> | grep "slot="
> ```

---

### Step 3 — Install ivshmem driver (guest)

Transfer these files into the guest:
- `dse-patcher.exe`
- `ivshmem.sys` + `ivshmem.inf`
- `RTCore64.sys` (from MSI Afterburner)

Place `RTCore64.sys` in the same folder as `dse-patcher.exe`, then run as **Administrator**:

```bat
dse-patcher.exe ivshmem.inf
```

Verify in Device Manager → System devices → device matching your PCI ID.

---

### Step 4 — Install ElgDisp IDD driver (guest)

Transfer `ElgDisp.dll` + `ElgDisp.inf` to the guest.

```bat
dse-patcher.exe ElgDisp.inf
```

Verify: Device Manager → Display adapters → `"Elgato Virtual Display Adapter"`

---

### Step 5 — Start IDDShmHost (guest)

```bat
IDDShmHost.exe --install
net start IDDShmHost
```

---

### Step 6 — Start the client (host)

```bash
./client/build/iddshm-client
```

The client reads from `/dev/kvmfr0` and begins receiving frames once IDDShmHost is
running and ElgDisp is presenting.

---

## Troubleshooting

| Symptom | Cause | Fix |
|:---|:---|:---|
| Device code **52** (unsigned driver) | HVCI still enabled | Turn off Memory Integrity → Reboot → Retry |
| Device code **10** (failed to start) | IDD init error | Check Event Viewer → System for IDD/UMDF errors |
| `pnputil` non-zero exit | Not running as admin | Open CMD as Administrator |
| `RTCore64` device not found | Driver didn't load | `sc query RTCore64` — may need reboot after HVCI off |
| `dse-patcher` can't find `g_CiEnabled` | ci.dll version changed | Open an issue with your Win11 build number |
| ivshmem device not in guest | Wrong PCI slot or QEMU version | Verify patched QEMU and free PCIe slot |
| `Property 'ivshmem-plain.vendor-id' not found` | Unpatched QEMU | Apply the QEMU patch from [Build Guide](#1-patch-qemu) |
| QEMU `can't open /dev/kvmfr0: Operation not permitted` | cgroup device ACL | Add `/dev/kvmfr0` to `cgroup_device_acl` in `/etc/libvirt/qemu.conf` |
| Client gets no frames | IDDShmHost not running or GUID mismatch | Verify `vendor/ivshmem/ivshmem.h` GUID matches the built ivshmem.sys |

---

## Repo Layout

```
idd/LGIdd/              Windows IDD driver source (UMDF2)
module/                  Linux kvmfr kernel module
host/                    IDDShmHost service
client/                  Looking Glass host client (Linux)
tools/
  dse-patcher/           Unsigned driver installer — DSE bypass via RTCore64
  build-ivshmem.bat      Patches + builds ivshmem driver with random IDs
vendor/ivshmem/          Vendored ivshmem interface header (GUID must match driver)
```

---

## Upstream

- [Looking Glass](https://github.com/gnif/LookingGlass) — base project
- [Docs](https://looking-glass.io)

**License:** GPLv2 (inherited from Looking Glass)
