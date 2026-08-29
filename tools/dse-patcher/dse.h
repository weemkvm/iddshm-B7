/*
 * dse.h — DSE (Driver Signature Enforcement) disable/restore via g_CiEnabled
 */

#pragma once
#include <windows.h>
#include <stdint.h>
#include <stdbool.h>

/*
 * Locate the address of g_CiEnabled in the running kernel's ci.dll module.
 *
 * Strategy:
 *   1. NtQuerySystemInformation(SystemModuleInformation) → get ci.dll load base
 *   2. Load ci.dll from disk, parse PE exports/sections
 *   3. Scan for g_CiEnabled using known byte-pattern signature around it
 *   4. Return kernel VA of the flag
 */
bool    DSE_FindCiEnabled(uint64_t *out_addr);

/*
 * Read current value of g_CiEnabled (should be 1 normally).
 * Returns false on R/W failure.
 */
bool    DSE_Read(uint64_t addr, uint8_t *out_val);

/*
 * Write val to g_CiEnabled.
 * val=0 disables DSE, val=6 (or original) restores it.
 */
bool    DSE_Write(uint64_t addr, uint8_t val);
