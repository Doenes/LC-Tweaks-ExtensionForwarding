// Self-contained MH_EXECUTE -> MH_DYLIB conversion for app-extension binaries,
// so LiveProcess can dlopen them. Same transform as patch_appex.py, but run at
// LiveContainer's sign time (see LCExtForwardHost.m). No Apple SDK headers, so
// the identical code compiles into the iOS dylib and into a native test tool.
#ifndef LCEF_MACHO_H
#define LCEF_MACHO_H
#include <stdint.h>
#include <stddef.h>

// Optional log sink (printf-style message already formatted). Default: none.
extern void (*lcef_macho_log)(const char *msg);

// Convert one arm64 slice in place. 0 = converted, 1 = skipped, -1 = failed.
int lcef_patch_slice(uint8_t *buf, size_t len, uint32_t off, const char *name);

// Convert every arm64 executable slice of the Mach-O file at `path` in place.
// 1 = file changed and rewritten, 0 = nothing to do / error.
int lcef_patch_file(const char *path);

#endif
