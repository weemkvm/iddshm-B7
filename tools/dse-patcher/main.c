/*
 * main.c — ElgDisp DSE patcher
 *
 * Usage (run as Administrator):
 *   dse-patcher.exe [path\to\ElgDisp.inf]
 *
 * What it does:
 *   1. Drop RTCore64.sys (bundled) to a temp path and load it as a service
 *   2. Open the RTCore64 device to get kernel R/W primitive
 *   3. Find g_CiEnabled in the running ci.dll
 *   4. Save original value, write 0 (DSE disabled)
 *   5. Run pnputil /add-driver <inf> /install
 *   6. Restore original g_CiEnabled value
 *   7. Unload and delete RTCore64.sys
 *
 * Requirements:
 *   - Must run as Administrator (SeLoadDriverPrivilege needed)
 *   - Win11 HVCI must NOT be enabled (Settings > Windows Security > Core Isolation)
 *   - RTCore64.sys must be in the same directory as this EXE, or in drivers\
 */

#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>

#include "km_rw.h"
#include "dse.h"

#define DRIVER_NAME     "RTCore64"
#define DRIVER_DISPLAY  "Realtek Core Service"  /* innocuous service display name */

/* ------------------------------------------------------------------ */
/* Service helpers                                                     */
/* ------------------------------------------------------------------ */

static bool driver_install(const char *sys_path)
{
    SC_HANDLE scm = OpenSCManagerA(NULL, NULL, SC_MANAGER_ALL_ACCESS);
    if (!scm) {
        fprintf(stderr, "[main] OpenSCManager failed: %lu\n", GetLastError());
        return false;
    }

    /* Remove stale entry if present */
    SC_HANDLE svc = OpenServiceA(scm, DRIVER_NAME, SERVICE_ALL_ACCESS);
    if (svc) {
        SERVICE_STATUS ss;
        ControlService(svc, SERVICE_CONTROL_STOP, &ss);
        DeleteService(svc);
        CloseServiceHandle(svc);
    }

    svc = CreateServiceA(
        scm, DRIVER_NAME, DRIVER_DISPLAY,
        SERVICE_ALL_ACCESS,
        SERVICE_KERNEL_DRIVER,
        SERVICE_DEMAND_START,
        SERVICE_ERROR_NORMAL,
        sys_path,
        NULL, NULL, NULL, NULL, NULL
    );

    if (!svc) {
        fprintf(stderr, "[main] CreateService failed: %lu\n", GetLastError());
        CloseServiceHandle(scm);
        return false;
    }

    bool ok = StartServiceA(svc, 0, NULL);
    if (!ok && GetLastError() != ERROR_SERVICE_ALREADY_RUNNING) {
        fprintf(stderr, "[main] StartService failed: %lu\n", GetLastError());
    } else {
        ok = true;
    }

    CloseServiceHandle(svc);
    CloseServiceHandle(scm);
    return ok;
}

static void driver_unload(void)
{
    SC_HANDLE scm = OpenSCManagerA(NULL, NULL, SC_MANAGER_ALL_ACCESS);
    if (!scm) return;

    SC_HANDLE svc = OpenServiceA(scm, DRIVER_NAME, SERVICE_ALL_ACCESS);
    if (svc) {
        SERVICE_STATUS ss;
        ControlService(svc, SERVICE_CONTROL_STOP, &ss);
        Sleep(500);
        DeleteService(svc);
        CloseServiceHandle(svc);
    }
    CloseServiceHandle(scm);
}

/* ------------------------------------------------------------------ */
/* Driver file helpers                                                 */
/* ------------------------------------------------------------------ */

/* RTCore64.sys is expected next to the EXE or in a "drivers" subdir */
static bool find_rtcore(char *out, size_t out_sz)
{
    char exe_dir[MAX_PATH];
    GetModuleFileNameA(NULL, exe_dir, sizeof(exe_dir));
    char *last = strrchr(exe_dir, '\\');
    if (last) *last = '\0';

    /* Try: <exe dir>\RTCore64.sys */
    snprintf(out, out_sz, "%s\\RTCore64.sys", exe_dir);
    if (GetFileAttributesA(out) != INVALID_FILE_ATTRIBUTES) return true;

    /* Try: <exe dir>\drivers\RTCore64.sys */
    snprintf(out, out_sz, "%s\\drivers\\RTCore64.sys", exe_dir);
    if (GetFileAttributesA(out) != INVALID_FILE_ATTRIBUTES) return true;

    return false;
}

/* Copy RTCore64.sys to System32 so SCM can load it */
static bool stage_driver(const char *src, char *staged, size_t staged_sz)
{
    char win[MAX_PATH];
    GetWindowsDirectoryA(win, sizeof(win));
    snprintf(staged, staged_sz, "%s\\System32\\RTCore64.sys", win);

    if (!CopyFileA(src, staged, FALSE)) {
        fprintf(stderr, "[main] CopyFile to System32 failed: %lu\n", GetLastError());
        return false;
    }
    return true;
}

/* ------------------------------------------------------------------ */
/* Privilege helpers                                                   */
/* ------------------------------------------------------------------ */

static bool enable_privilege(const char *name)
{
    HANDLE tok;
    if (!OpenProcessToken(GetCurrentProcess(),
            TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, &tok))
        return false;

    TOKEN_PRIVILEGES tp;
    if (!LookupPrivilegeValueA(NULL, name, &tp.Privileges[0].Luid)) {
        CloseHandle(tok);
        return false;
    }

    tp.PrivilegeCount = 1;
    tp.Privileges[0].Attributes = SE_PRIVILEGE_ENABLED;
    AdjustTokenPrivileges(tok, FALSE, &tp, sizeof(tp), NULL, NULL);
    CloseHandle(tok);
    return (GetLastError() == ERROR_SUCCESS);
}

/* ------------------------------------------------------------------ */
/* Main                                                                */
/* ------------------------------------------------------------------ */

int main(int argc, char *argv[])
{
    printf("=== ElgDisp DSE Patcher ===\n\n");

    if (argc < 2) {
        fprintf(stderr, "Usage: %s <path\\to\\ElgDisp.inf>\n", argv[0]);
        return 1;
    }

    const char *inf_path = argv[1];
    if (GetFileAttributesA(inf_path) == INVALID_FILE_ATTRIBUTES) {
        fprintf(stderr, "[main] INF not found: %s\n", inf_path);
        return 1;
    }

    /* Need load driver privilege */
    enable_privilege("SeLoadDriverPrivilege");

    /* Locate RTCore64.sys */
    char rtcore_src[MAX_PATH];
    if (!find_rtcore(rtcore_src, sizeof(rtcore_src))) {
        fprintf(stderr,
            "[main] RTCore64.sys not found.\n"
            "       Place it next to this EXE or in a 'drivers' subfolder.\n"
            "       Get it from MSI Afterburner installation directory.\n");
        return 1;
    }
    printf("[main] RTCore64.sys found at: %s\n", rtcore_src);

    /* Stage to System32 */
    char staged[MAX_PATH];
    if (!stage_driver(rtcore_src, staged, sizeof(staged))) return 1;
    printf("[main] staged to: %s\n", staged);

    /* Load driver */
    printf("[main] loading RTCore64 service...\n");
    if (!driver_install(staged)) {
        DeleteFileA(staged);
        return 1;
    }
    printf("[main] driver loaded OK\n");

    /* Open device */
    if (!KmRw_Init()) {
        driver_unload();
        DeleteFileA(staged);
        return 1;
    }
    printf("[main] kernel R/W channel open\n");

    /* Find g_CiEnabled */
    uint64_t ci_addr = 0;
    if (!DSE_FindCiEnabled(&ci_addr)) {
        KmRw_Close();
        driver_unload();
        DeleteFileA(staged);
        return 1;
    }

    /* Read current value */
    uint8_t orig = 0;
    if (!DSE_Read(ci_addr, &orig)) {
        fprintf(stderr, "[main] failed to read g_CiEnabled\n");
        KmRw_Close();
        driver_unload();
        DeleteFileA(staged);
        return 1;
    }
    printf("[main] g_CiEnabled = %u (original)\n", orig);

    /* Disable DSE */
    printf("[main] disabling DSE (g_CiEnabled = 0)...\n");
    if (!DSE_Write(ci_addr, 0)) {
        fprintf(stderr, "[main] failed to patch g_CiEnabled\n");
        KmRw_Close();
        driver_unload();
        DeleteFileA(staged);
        return 1;
    }

    /* Install the driver */
    printf("[main] installing %s ...\n", inf_path);
    char cmd[MAX_PATH * 2];
    snprintf(cmd, sizeof(cmd), "pnputil /add-driver \"%s\" /install", inf_path);

    int ret = system(cmd);
    printf("[main] pnputil exit code: %d\n", ret);

    /* Restore DSE */
    printf("[main] restoring g_CiEnabled = %u ...\n", orig);
    if (!DSE_Write(ci_addr, orig)) {
        fprintf(stderr, "[main] WARNING: failed to restore g_CiEnabled! Reboot recommended.\n");
    } else {
        printf("[main] DSE restored\n");
    }

    /* Cleanup */
    KmRw_Close();
    Sleep(500);
    driver_unload();
    Sleep(500);
    DeleteFileA(staged);

    if (ret == 0) {
        printf("\n[main] SUCCESS — ElgDisp driver installed.\n");
        printf("[main] Use Device Manager to verify 'Elgato Virtual Display Adapter' appears.\n");
        printf("[main] If the device does not appear, run:\n");
        printf("[main]   devcon rescan\n");
        printf("[main] or install devcon from the WDK Extras.\n");
    } else {
        printf("\n[main] pnputil returned non-zero. Check Device Manager for error details.\n");
        printf("[main] If code 52 (unsigned), the DSE patch may not have taken — verify HVCI is off.\n");
    }

    return (ret == 0) ? 0 : 1;
}
