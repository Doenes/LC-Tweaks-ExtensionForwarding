#include "lcef_macho.h"
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <sys/stat.h>

void (*lcef_macho_log)(const char *msg) = 0;
static void LOGF(const char *fmt, const char *a) {
    if (!lcef_macho_log) return;
    char buf[512]; snprintf(buf, sizeof(buf), fmt, a); lcef_macho_log(buf);
}

// --- Mach-O layout (own definitions, no SDK headers) ---
#define MH_MAGIC_64   0xFEEDFACFu
#define FAT_MAGIC     0xCAFEBABEu
#define FAT_MAGIC_64  0xCAFEBABFu
#define CPU_ARM64     0x0100000Cu
#define MH_EXECUTE    2u
#define MH_DYLIB      6u
#define MH_PIE                0x200000u
#define MH_NO_REEXPORTED_DYLIBS 0x100000u
#define LC_SEGMENT_64     0x19u
#define LC_ID_DYLIB       0x0Du
#define LC_LOAD_DYLINKER  0x0Eu
#define LC_CODE_SIGNATURE 0x1Du
#define LC_RPATH          0x8000001Cu
#define RPATHSTR "@loader_path/../../Frameworks"

#pragma pack(push, 1)
typedef struct { uint32_t magic, cputype, cpusubtype, filetype, ncmds, sizeofcmds, flags, reserved; } mh64;
typedef struct { uint32_t cmd, cmdsize; } lc;
typedef struct { uint32_t cmd, cmdsize; char segname[16]; uint64_t vmaddr, vmsize, fileoff, filesize;
                 int32_t maxprot, initprot; uint32_t nsects, flags; } seg64;
typedef struct { char sectname[16], segname[16]; uint64_t addr, size; uint32_t offset, align,
                 reloff, nreloc, flags, r1, r2, r3; } sect64;
typedef struct { uint32_t cmd, cmdsize, name_off, timestamp, cur_ver, compat_ver; } dylibc;
typedef struct { uint32_t cmd, cmdsize, path_off; } rpathc;
typedef struct { uint32_t magic, nfat_arch; } fath;
typedef struct { uint32_t cputype, cpusubtype, offset, size, align; } fata;
typedef struct { uint32_t cputype, cpusubtype; uint64_t offset, size; uint32_t align, reserved; } fata64;
#pragma pack(pop)

static uint32_t bswap32(uint32_t x) { return __builtin_bswap32(x); }
static uint64_t bswap64(uint64_t x) { return __builtin_bswap64(x); }
static uint32_t rnd8(uint32_t n) { return (n + 7u) & ~7u; }

int lcef_patch_slice(uint8_t *buf, size_t len, uint32_t off, const char *name) {
    if ((size_t)off + sizeof(mh64) > len) return -1;
    mh64 *mh = (mh64 *)(buf + off);
    if (mh->magic != MH_MAGIC_64 || mh->cputype != CPU_ARM64) return 1;
    if (mh->filetype == MH_DYLIB) return 1;
    if (mh->filetype != MH_EXECUTE) return 1;

    uint32_t text_off = 0; int have_text = 0, has_id = 0, has_sig = 0, has_rpath = 0;
    uint32_t dyld_off = 0, dyld_sz = 0;
    uint8_t *p = buf + off + sizeof(mh64);
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        if (p + sizeof(lc) > buf + len) return -1;
        lc *c = (lc *)p;
        if (c->cmdsize < sizeof(lc) || p + c->cmdsize > buf + len) return -1;
        if (c->cmd == LC_SEGMENT_64) {
            seg64 *s = (seg64 *)p;
            if (s->vmaddr == 0 && strncmp(s->segname, "__PAGEZERO", 16) == 0) {
                s->vmaddr = 0x100000000ULL - 0x4000ULL; s->vmsize = 0x4000ULL;
            }
            if (strncmp(s->segname, "__TEXT", 16) == 0) {
                sect64 *se = (sect64 *)(p + sizeof(seg64));
                for (uint32_t j = 0; j < s->nsects; j++) {
                    if ((uint8_t *)(se + j + 1) > buf + len) return -1;
                    if (strncmp(se[j].sectname, "__text", 16) == 0) { text_off = se[j].offset; have_text = 1; }
                }
            }
        } else if (c->cmd == LC_ID_DYLIB) { has_id = 1; }
        else if (c->cmd == LC_CODE_SIGNATURE) { has_sig = 1; }
        else if (c->cmd == LC_LOAD_DYLINKER) { dyld_off = (uint32_t)(p - buf); dyld_sz = c->cmdsize; }
        else if (c->cmd == LC_RPATH) {
            rpathc *r = (rpathc *)p;
            if (r->path_off < c->cmdsize && strncmp((char *)p + r->path_off, RPATHSTR, c->cmdsize - r->path_off) == 0) has_rpath = 1;
        }
        p += c->cmdsize;
    }
    if (!have_text) return -1;
    uint8_t *cmds_end = p;
    long freeb = (long)(off + text_off) - (long)(cmds_end - buf);
    if (!has_sig) freeb -= 16;

    uint8_t add[256]; uint32_t add_len = 0, added = 0;
    if (!has_id) {
        uint32_t nl = (uint32_t)strlen(name) + 1, cs = rnd8(sizeof(dylibc) + nl);
        if ((long)cs <= freeb && add_len + cs <= sizeof(add)) {
            dylibc *d = (dylibc *)(add + add_len); memset(d, 0, cs);
            d->cmd = LC_ID_DYLIB; d->cmdsize = cs; d->name_off = sizeof(dylibc);
            d->timestamp = 2; d->cur_ver = 0x10000; d->compat_ver = 0x10000;
            memcpy((uint8_t *)d + sizeof(dylibc), name, strlen(name));
            add_len += cs; added++;
        } else if (dyld_sz >= sizeof(dylibc) + 8) {
            dylibc *d = (dylibc *)(buf + dyld_off); uint32_t keep = dyld_sz, maxn = keep - sizeof(dylibc);
            memset(d, 0, keep);
            d->cmd = LC_ID_DYLIB; d->cmdsize = keep; d->name_off = sizeof(dylibc);
            d->timestamp = 2; d->cur_ver = 0x10000; d->compat_ver = 0x10000;
            size_t cpy = strlen(name); if (cpy > maxn - 1) cpy = maxn - 1;
            memcpy((uint8_t *)d + sizeof(dylibc), name, cpy);
        } else { LOGF("%s: no room for LC_ID_DYLIB", name); return -1; }
    }
    if (!has_rpath) {
        uint32_t pl = (uint32_t)strlen(RPATHSTR) + 1, cs = rnd8(sizeof(rpathc) + pl);
        if ((long)(add_len + cs) <= freeb && add_len + cs <= sizeof(add)) {
            rpathc *r = (rpathc *)(add + add_len); memset(r, 0, cs);
            r->cmd = LC_RPATH; r->cmdsize = cs; r->path_off = sizeof(rpathc);
            memcpy((uint8_t *)r + sizeof(rpathc), RPATHSTR, strlen(RPATHSTR));
            add_len += cs; added++;
        }
    }
    if (add_len) memcpy(cmds_end, add, add_len);
    mh->filetype = MH_DYLIB;
    mh->ncmds += added;
    mh->sizeofcmds += add_len;
    mh->flags = (mh->flags | MH_NO_REEXPORTED_DYLIBS) & ~MH_PIE;
    return 0;
}

int lcef_patch_file(const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) return 0;
    fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
    if (n < (long)sizeof(mh64)) { fclose(f); return 0; }
    uint8_t *buf = (uint8_t *)malloc(n);
    if (!buf) { fclose(f); return 0; }
    if (fread(buf, 1, n, f) != (size_t)n) { free(buf); fclose(f); return 0; }
    fclose(f);

    int changed = 0, failed = 0;
    uint32_t magic_be = *(uint32_t *)buf;
    uint32_t magic = bswap32(magic_be);  // fat header is big-endian
    const char *base = strrchr(path, '/'); base = base ? base + 1 : path;
    if (magic == FAT_MAGIC || magic == FAT_MAGIC_64) {
        int is64 = (magic == FAT_MAGIC_64);
        uint32_t cnt = bswap32(((fath *)buf)->nfat_arch);
        uint8_t *fa = buf + sizeof(fath);
        for (uint32_t i = 0; i < cnt; i++) {
            uint32_t cputype; uint64_t off;
            if (is64) {
                fata64 *a = (fata64 *)(fa + i * sizeof(fata64));
                if ((uint8_t *)(a + 1) > buf + n) break;
                cputype = bswap32(a->cputype); off = bswap64(a->offset);
            } else {
                fata *a = (fata *)(fa + i * sizeof(fata));
                if ((uint8_t *)(a + 1) > buf + n) break;
                cputype = bswap32(a->cputype); off = bswap32(a->offset);
            }
            if (cputype == CPU_ARM64 && off < (uint64_t)n) {
                int r = lcef_patch_slice(buf, n, (uint32_t)off, base);
                if (r == 0) changed = 1; else if (r < 0) failed = 1;
            }
        }
    } else if (*(uint32_t *)buf == MH_MAGIC_64) {
        int r = lcef_patch_slice(buf, n, 0, base);
        if (r == 0) changed = 1; else if (r < 0) failed = 1;
    }

    // A slice that failed may be half-modified: then leave the whole file untouched.
    if (failed) { LOGF("%s: conversion failed, file left unchanged", base); free(buf); return 0; }
    if (changed) {
        // Write next to the original and rename over it, so an interrupted write
        // never leaves a truncated binary behind. Keep the original permissions.
        struct stat st; mode_t mode = stat(path, &st) == 0 ? (st.st_mode & 07777) : 0755;
        char tmp[1024];
        if (snprintf(tmp, sizeof(tmp), "%s.lcef-tmp", path) >= (int)sizeof(tmp)) { free(buf); return 0; }
        FILE *w = fopen(tmp, "wb");
        if (!w) { free(buf); return 0; }
        size_t wrote = fwrite(buf, 1, n, w);
        int closed = fclose(w);
        free(buf);
        if (wrote != (size_t)n || closed != 0) { remove(tmp); return 0; }
        chmod(tmp, mode);
        if (rename(tmp, path) != 0) { remove(tmp); return 0; }
        return 1;
    }
    free(buf);
    return 0;
}
