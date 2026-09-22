#!/usr/bin/env python3
"""Writes the Finder window layout for the Panoptos disk image.

Finder keeps a folder's window geometry, icon view options, and icon positions
in .DS_Store. Asking Finder to set them through AppleScript no longer persists
the view options on current macOS, so the release script writes the file
directly instead, using only the standard library.

Usage:
  dmg-layout.py --volume /Volumes/NAME --background .background/background.tiff
                --window X,Y,W,H --icon-size 128 --text-size 13
                --item "Panoptos.app=180,190" --item "Applications=480,190"

The volume must be a mounted, writable HFS+ image: the background alias
records the file's catalog node ID, which survives conversion to a compressed
read-only image.
"""

import argparse
import datetime
import os
import plistlib
import struct

# Alias records date from the classic Mac OS epoch, 1904-01-01 UTC.
MAC_EPOCH_OFFSET = int((datetime.datetime(1970, 1, 1, tzinfo=datetime.timezone.utc)
                        - datetime.datetime(1904, 1, 1, tzinfo=datetime.timezone.utc)).total_seconds())


def mac_seconds(unix_time):
    return int(unix_time) + MAC_EPOCH_OFFSET


def mac_fixed_point(unix_time):
    """Seconds since the Mac epoch as a 48.16 fixed-point value."""
    return int((unix_time + MAC_EPOCH_OFFSET) * 65536)


def pascal(value, width):
    data = value.encode("mac_roman")[: width - 1]
    return bytes([len(data)]) + data + b"\0" * (width - 1 - len(data))


def alias_record(volume, relative_path):
    """A version 2 alias record for a file on the volume, as Finder stores
    for icon view backgrounds."""
    volume = os.path.abspath(volume)
    target = os.path.join(volume, relative_path)
    volume_name = os.path.basename(volume)
    volume_stat = os.stat(volume)
    target_stat = os.stat(target)
    parent = os.path.dirname(target)
    parent_stat = os.stat(parent)

    components = relative_path.split("/")
    cnid_path = []
    walk = volume
    for component in components[:-1]:
        walk = os.path.join(walk, component)
        cnid_path.append(os.stat(walk).st_ino)
    filename = components[-1]
    carbon_path = volume_name + ":" + ":".join(components)
    folder_name = os.path.basename(parent)

    body = struct.pack(
        ">h28pI2shI64pII4s4shhI2s10s",
        0,                                   # kind: file
        volume_name.encode("mac_roman"),
        mac_seconds(volume_stat.st_birthtime),
        b"H+",
        0,                                   # fixed disk
        parent_stat.st_ino,
        filename.encode("mac_roman"),
        target_stat.st_ino,
        mac_seconds(target_stat.st_birthtime),
        b"\0\0\0\0", b"\0\0\0\0",
        -1, -1,                              # levels from / to
        0,                                   # volume attributes
        b"\0\0",
        b"\0" * 10,
    )

    def utf16(text):
        encoded = text.encode("utf-16-be")
        return struct.pack(">h", len(encoded) // 2) + encoded

    extras = [
        (0, folder_name.encode("mac_roman")),
        (1, struct.pack(">%dI" % len(cnid_path), *cnid_path)),
        (2, carbon_path.encode("mac_roman")),
        (14, utf16(filename)),
        (15, utf16(volume_name)),
        (16, struct.pack(">Q", mac_fixed_point(volume_stat.st_birthtime))),
        (17, struct.pack(">Q", mac_fixed_point(target_stat.st_birthtime))),
        (18, ("/" + relative_path).encode("utf-8")),
        (19, volume.encode("utf-8")),
    ]
    tail = b""
    for tag, value in extras:
        tail += struct.pack(">hh", tag, len(value)) + value
        if len(value) & 1:
            tail += b"\0"
    tail += struct.pack(">hh", -1, 0)

    record = b"\0\0\0\0" + struct.pack(">hh", 0, 2) + body + tail
    return record[:4] + struct.pack(">h", len(record)) + record[6:]


def blob(data):
    return struct.pack(">I", len(data)) + data


def record(filename, struct_id, type_code, payload):
    name = filename.encode("utf-16-be")
    return struct.pack(">I", len(name) // 2) + name + struct_id + type_code + payload


def build_store(records):
    """Lays out a single-leaf B-tree in the buddy allocator Finder expects.

    Relative offsets (from the 4-byte prefix):
      0x0000  allocator header, 32 bytes
      0x0040  master block (DSDB), 32 bytes
      0x1000  tree node, 4096 bytes
      0x2000  bookkeeping block, 2048 bytes
    """
    node = struct.pack(">II", 0, len(records)) + b"".join(records)
    if len(node) > 4096:
        raise SystemExit("layout does not fit in one 4096-byte node")
    node += b"\0" * (4096 - len(node))

    master = struct.pack(">IIIII", 2, 0, len(records), 1, 4096)
    master += b"\0" * (32 - len(master))

    header = b"Bud1" + struct.pack(">III", 0x2000, 0x800, 0x2000)
    header += bytes.fromhex("0000040a") + b"\0" * 12

    addresses = [0x2000 | 11, 0x40 | 5, 0x1000 | 12]
    bookkeeping = struct.pack(">II", len(addresses), 0)
    bookkeeping += struct.pack(">%dI" % len(addresses), *addresses)
    bookkeeping += b"\0" * (4 * (256 - len(addresses)))
    bookkeeping += struct.pack(">I", 1) + bytes([4]) + b"DSDB" + struct.pack(">I", 1)
    # Buddy free lists for the allocations above, one list per power of two.
    free = {5: [0x20, 0x60], 7: [0x80], 8: [0x100], 9: [0x200], 10: [0x400],
            11: [0x800, 0x2800], 12: [0x3000]}
    for power in range(14, 31):
        free[power] = [1 << power]
    for power in range(32):
        offsets = free.get(power, [])
        bookkeeping += struct.pack(">I", len(offsets))
        bookkeeping += struct.pack(">%dI" % len(offsets), *offsets)
    if len(bookkeeping) > 2048:
        raise SystemExit("bookkeeping block overflow")
    bookkeeping += b"\0" * (2048 - len(bookkeeping))

    image = bytearray(b"\0" * (4 + 0x2800))
    image[0:4] = b"\0\0\0\1"
    image[4:4 + 32] = header
    image[4 + 0x40:4 + 0x40 + 32] = master
    image[4 + 0x1000:4 + 0x2000] = node
    image[4 + 0x2000:4 + 0x2800] = bookkeeping
    return bytes(image)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--volume", required=True)
    parser.add_argument("--background", required=True, help="path relative to the volume root")
    parser.add_argument("--window", required=True, help="X,Y,W,H in screen points")
    parser.add_argument("--icon-size", type=float, default=128)
    parser.add_argument("--text-size", type=float, default=13)
    parser.add_argument("--item", action="append", default=[], help="NAME=X,Y icon center")
    args = parser.parse_args()

    x, y, w, h = (int(v) for v in args.window.split(","))
    window = plistlib.dumps({
        "ContainerShowSidebar": False,
        "PreviewPaneVisibility": False,
        "ShowPathbar": False,
        "ShowSidebar": False,
        "ShowStatusBar": False,
        "ShowTabView": False,
        "ShowToolbar": False,
        "SidebarWidth": 0,
        "WindowBounds": "{{%d, %d}, {%d, %d}}" % (x, y, w, h),
    }, fmt=plistlib.FMT_BINARY)

    view = plistlib.dumps({
        "arrangeBy": "none",
        "backgroundColorBlue": 1.0,
        "backgroundColorGreen": 1.0,
        "backgroundColorRed": 1.0,
        "backgroundImageAlias": alias_record(args.volume, args.background),
        "backgroundType": 2,
        "gridOffsetX": 0.0,
        "gridOffsetY": 0.0,
        "gridSpacing": 100.0,
        "iconSize": args.icon_size,
        "labelOnBottom": True,
        "scrollPositionX": 0.0,
        "scrollPositionY": 0.0,
        "showIconPreview": True,
        "showItemInfo": False,
        "textSize": args.text_size,
        "viewOptionsVersion": 1,
    }, fmt=plistlib.FMT_BINARY)

    entries = [
        (".", b"bwsp", b"blob", blob(window)),
        (".", b"icvp", b"blob", blob(view)),
        (".", b"vSrn", b"long", struct.pack(">I", 1)),
    ]
    for item in args.item:
        name, position = item.split("=")
        ix, iy = (int(v) for v in position.split(","))
        if not os.path.lexists(os.path.join(args.volume, name)):
            raise SystemExit("no item named %r on the volume" % name)
        entries.append((name, b"Iloc", b"blob", blob(struct.pack(">II", ix, iy) + b"\xff\xff\xff\xff\xff\xff\0\0")))

    # Records are keyed by (name, struct id); Finder expects them sorted.
    entries.sort(key=lambda entry: (entry[0].lower(), entry[1]))
    store = build_store([record(*entry) for entry in entries])
    with open(os.path.join(args.volume, ".DS_Store"), "wb") as handle:
        handle.write(store)


if __name__ == "__main__":
    main()
