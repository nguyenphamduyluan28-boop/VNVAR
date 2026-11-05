#!/usr/bin/env python3
"""Kiểm tra APK có hỗ trợ trang bộ nhớ 16 KB (yêu cầu của Google Play).

Google Play yêu cầu app nhắm Android 15+ chạy được trên máy dùng trang 16 KB:
mọi thư viện native (.so) 64-bit phải có các đoạn LOAD căn lề >= 16 KB, và
.so không nén trong APK phải nằm ở offset chia hết cho 16 KB.

Cách dùng:
    python3 tool/check_16kb_page_size.py build/app/outputs/flutter-apk/app-release.apk

Exit 1 và liệt kê thư viện lỗi nếu không đạt. Chỉ dùng thư viện chuẩn Python.
"""

import struct
import sys
import zipfile

PAGE = 16 * 1024
# Chỉ ABI 64-bit bắt buộc 16 KB; 32-bit (armeabi-v7a, x86) được bỏ qua.
CHECKED_ABIS = ("arm64-v8a", "x86_64")
PT_LOAD = 1


def elf_min_load_align(data: bytes):
    """Căn lề nhỏ nhất của các đoạn PT_LOAD (ELF64), None nếu không phải ELF64."""
    if len(data) < 64 or data[:4] != b"\x7fELF" or data[4] != 2:
        return None
    endian = "<" if data[5] == 1 else ">"
    e_phoff = struct.unpack_from(endian + "Q", data, 0x20)[0]
    e_phentsize, e_phnum = struct.unpack_from(endian + "HH", data, 0x36)
    aligns = []
    for i in range(e_phnum):
        off = e_phoff + i * e_phentsize
        if off + 56 > len(data):
            break
        p_type = struct.unpack_from(endian + "I", data, off)[0]
        if p_type == PT_LOAD:
            aligns.append(struct.unpack_from(endian + "Q", data, off + 48)[0])
    return min(aligns) if aligns else None


def data_offset(zf: zipfile.ZipFile, info: zipfile.ZipInfo) -> int:
    """Offset dữ liệu của entry (sau local file header) trong file zip."""
    zf.fp.seek(info.header_offset)
    header = zf.fp.read(30)
    name_len, extra_len = struct.unpack("<HH", header[26:30])
    return info.header_offset + 30 + name_len + extra_len


def main(path: str) -> int:
    problems = []
    checked = 0
    with zipfile.ZipFile(path) as zf:
        for info in zf.infolist():
            name = info.filename
            parts = name.split("/")
            if not name.endswith(".so") or len(parts) < 3 or parts[0] != "lib":
                continue
            if parts[1] not in CHECKED_ABIS:
                continue
            checked += 1
            align = elf_min_load_align(zf.read(info))
            if align is None:
                problems.append(f"{name}: không đọc được ELF64")
            elif align < PAGE:
                problems.append(f"{name}: LOAD căn lề {align} byte (< 16384)")
            if info.compress_type == zipfile.ZIP_STORED:
                offset = data_offset(zf, info)
                if offset % PAGE:
                    problems.append(f"{name}: offset {offset} trong APK không chia hết cho 16384")
    print(f"Đã kiểm tra {checked} thư viện .so ({', '.join(CHECKED_ABIS)}).")
    if problems:
        print("KHÔNG ĐẠT 16 KB page size:")
        for problem in problems:
            print("  - " + problem)
        return 1
    print("Đạt yêu cầu 16 KB page size.")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(2)
    sys.exit(main(sys.argv[1]))
