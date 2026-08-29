# IDDShm-B7

A fork of [Looking Glass](https://github.com/gnif/LookingGlass) (B4 tree) that
replaces the guest-side capture with a rebranded **Indirect Display Driver**
(IDD). This is the "IDDShm" variant: the Windows guest presents a virtual
display through the IDD (built as `IDDShm.dll` / `Root\IDDShm`) and pushes
KVMFR frames over shared memory (ivshmem/kvmfr) straight to the host client.

> **Status: work in progress.** This is kinda AI slop, honest to god. It works
> as a *base* to continue from, not as a finished product. I'll attempt to keep
> updating it as I have time.

## What's customized

- **`idd/LGIdd`** – Looking Glass's IDD driver, rebranded `LGIdd` → `IDDShm`
  with a fresh device-interface GUID (`GUID_DEVINTERFACE_IDDShm`) and its own
  INF (`IDDShm.inf`) so it installs and runs alongside / instead of the stock
  driver.
- **`vendor/ivshmem/ivshmem.h`** – the IVSHMEM wire/IOCTL header, also given a
  fresh `GUID_DEVINTERFACE_IVSHMEM`. *NOTE:* the corresponding Windows IVSHMEM
  guest driver must publish this same GUID to be found by `CIVSHMEM::Init()`.
- **`module/kvmfr.c`** – PCI vendor/device ID spoofed to `0x8086 / 0xC0A5`
  (Intel vendor, an otherwise-unmapped device ID so no inbox driver claims it),
  so the custom IVSHMEM/IDD stack owns the device.
- **`host/`** – host side renamed to `IDDShmHost` (config file
  `IDDShmHost.ini`, PipeWire stream tagged "IDDShm Host").

## Repo layout

```
idd/        Windows IDD driver (UMDF, builds with VS 2022 + WDK)
module/     Linux kvmfr kernel module (partially updated for the spoofed IDs)
host/       guest "host" service sources (Windows/Linux)
client/     Linux host client (Looking Glass client)
vendor/     third-party / submodule headers (ivshmem, directx, getopt)
```

## What's missing / next steps

- Windows **IVSHMEM guest driver** source is not included (was a git
  submodule) – it must be built with an INF matching `8086:C0A5` and
  publishing the custom interface GUID.
- QEMU must present the ivshmem device as `8086:0xC0A5` to match
  (`hw/misc/ivshmem-pci.c`, DEVICE_ID `0x1110` → `0xC0A5`).
- Driver signing / test-signing for the guest.
- Wire the 32 MiB `ivshmem-plain` / `ivshmem-doorbell` device into the VM XML
  backed by `/dev/kvmfr0`.

## Upstream

- Looking Glass: https://github.com/gnif/LookingGlass
- Docs: https://looking-glass.io

License: GPLv2 (inherited from Looking Glass).