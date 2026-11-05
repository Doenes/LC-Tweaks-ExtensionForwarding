#!/usr/bin/env python3
"""Make the app extensions of an IPA loadable by LCExtForward.

LiveContainer turns only an app's main executable into a dylib when it imports
the app. An appex executable stays MH_EXECUTE, which dlopen refuses, so this
does the same to every PlugIns/*.appex before the import (like
LCPatchExecSlice): MH_DYLIB file type, no PIE flag, a one-page __PAGEZERO,
an LC_ID_DYLIB, and an LC_RPATH of @loader_path/../../Frameworks so the appex
finds the guest app's frameworks. Code signatures become invalid; LiveContainer
signs the whole bundle again during the import.

    python3 patch_appex.py Input.ipa Output.ipa
"""
import plistlib
import posixpath
import struct
import sys
import zipfile

MH_MAGIC_64 = 0xFEEDFACF
FAT_MAGIC, FAT_MAGIC_64 = 0xCAFEBABE, 0xCAFEBABF
CPU_TYPE_ARM64 = 0x0100000C
MH_EXECUTE, MH_DYLIB = 2, 6
MH_PIE, MH_NO_REEXPORTED_DYLIBS = 0x200000, 0x100000
LC_SEGMENT_64, LC_ID_DYLIB, LC_LOAD_DYLINKER = 0x19, 0xD, 0xE
LC_CODE_SIGNATURE, LC_RPATH = 0x1D, 0x8000001C
HEADER_SIZE = 32
RPATH = b"@loader_path/../../Frameworks"


def rnd8(n):
    return (n + 7) & ~7


def id_dylib_command(name):
    size = rnd8(24 + len(name) + 1)
    return struct.pack("<6I", LC_ID_DYLIB, size, 24, 2, 0x10000, 0x10000) + name.ljust(size - 24, b"\0")


def rpath_command(path):
    size = rnd8(12 + len(path) + 1)
    return struct.pack("<3I", LC_RPATH, size, 12) + path.ljust(size - 12, b"\0")


def patch_slice(buf, off, name):
    magic, cputype, _, filetype, ncmds, sizeofcmds, flags = struct.unpack_from("<7I", buf, off)
    if magic != MH_MAGIC_64 or cputype != CPU_TYPE_ARM64:
        return "skipped (not arm64)"
    if filetype == MH_DYLIB:
        return "already patched"
    if filetype != MH_EXECUTE:
        return "skipped (file type %d)" % filetype

    text_offset, has_id, has_sig, dylinker, rpaths = None, False, False, None, set()
    p = off + HEADER_SIZE
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<2I", buf, p)
        if cmd == LC_SEGMENT_64:
            segname = buf[p + 8:p + 24].rstrip(b"\0")
            vmaddr, _, _, _, _, _, nsects = struct.unpack_from("<4Q2iI", buf, p + 24)
            if vmaddr == 0 and segname == b"__PAGEZERO":
                struct.pack_into("<2Q", buf, p + 24, 0x100000000 - 0x4000, 0x4000)
            if segname == b"__TEXT":
                for j in range(nsects):
                    s = p + 72 + 80 * j
                    if buf[s:s + 16].rstrip(b"\0") == b"__text":
                        text_offset = struct.unpack_from("<I", buf, s + 48)[0]
        elif cmd == LC_ID_DYLIB:
            has_id = True
        elif cmd == LC_CODE_SIGNATURE:
            has_sig = True
        elif cmd == LC_LOAD_DYLINKER:
            dylinker = (p, size)
        elif cmd == LC_RPATH:
            str_off = struct.unpack_from("<I", buf, p + 8)[0]
            rpaths.add(bytes(buf[p + str_off:p + size]).split(b"\0")[0])
        p += size
    if text_offset is None:
        return "failed: no __TEXT,__text"

    free = off + text_offset - p
    if not has_sig:
        free -= 16  # the signature LiveContainer adds
    new_cmds, added = b"", 0
    if not has_id:
        cmd = id_dylib_command(name.encode())
        if len(cmd) <= free:
            new_cmds += cmd
            added += 1
        elif dylinker and dylinker[1] >= 32:
            # Not enough room: reuse LC_LOAD_DYLINKER's space, as LiveContainer does.
            short = name.encode()[: dylinker[1] - 25]
            buf[dylinker[0]:dylinker[0] + dylinker[1]] = id_dylib_command(short).ljust(dylinker[1], b"\0")
            struct.pack_into("<I", buf, dylinker[0] + 4, dylinker[1])
        else:
            return "failed: no room for LC_ID_DYLIB"
    note = ""
    if RPATH not in rpaths:
        cmd = rpath_command(RPATH)
        if len(new_cmds) + len(cmd) <= free:
            new_cmds += cmd
            added += 1
        else:
            note = " (no room for LC_RPATH, the guest's frameworks may not be found)"

    buf[p:p + len(new_cmds)] = new_cmds
    ncmds += added
    flags = (flags | MH_NO_REEXPORTED_DYLIBS) & ~MH_PIE
    struct.pack_into("<I", buf, off + 12, MH_DYLIB)
    struct.pack_into("<2I", buf, off + 16, ncmds, sizeofcmds + len(new_cmds))
    struct.pack_into("<I", buf, off + 24, flags)
    return "patched" + note


def patch_macho(data, name):
    buf = bytearray(data)
    magic = struct.unpack_from(">I", buf, 0)[0]
    if magic in (FAT_MAGIC, FAT_MAGIC_64):
        count = struct.unpack_from(">I", buf, 4)[0]
        results = []
        for i in range(count):
            if magic == FAT_MAGIC:
                cputype, _, offset = struct.unpack_from(">3I", buf, 8 + 20 * i)
            else:
                cputype, _, offset = struct.unpack_from(">2IQ", buf, 8 + 32 * i)
            if cputype == CPU_TYPE_ARM64:
                results.append(patch_slice(buf, offset, name))
        return bytes(buf), ", ".join(results) or "skipped (no arm64 slice)"
    result = patch_slice(buf, 0, name)
    return bytes(buf), result


def main(src, dst):
    with zipfile.ZipFile(src) as zin:
        names = zin.namelist()
        targets = {}
        for n in names:
            parts = n.split("/")
            if len(parts) == 5 and parts[0] == "Payload" and parts[2] == "PlugIns" and parts[4] == "Info.plist":
                info = plistlib.loads(zin.read(n))
                exe = info.get("CFBundleExecutable")
                if exe:
                    targets[posixpath.join(posixpath.dirname(n), exe)] = parts[3]
        if not targets:
            print("No app extensions found.")
        with zipfile.ZipFile(dst, "w", zipfile.ZIP_DEFLATED) as zout:
            for info in zin.infolist():
                data = zin.read(info)
                if info.filename in targets:
                    data, result = patch_macho(data, posixpath.basename(info.filename))
                    print("%s: %s" % (targets[info.filename], result))
                zout.writestr(info, data)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
