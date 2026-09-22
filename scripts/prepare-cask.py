#!/usr/bin/env python3
"""Prepare a local cask from final release bytes; never publish or install it."""

import argparse
import hashlib
import re
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True)
    parser.add_argument("--dmg", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    if not re.fullmatch(r"(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)", args.version):
        parser.error("version must be stable semantic version X.Y.Z")
    if not args.dmg.is_file() or args.dmg.stat().st_size == 0:
        parser.error("DMG must be an existing nonempty file")
    digest = hashlib.sha256()
    with args.dmg.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    cask = '''cask "panoptos" do
  version "VERSION"
  sha256 "SHA256"

  url "https://github.com/RUverse/panoptos/releases/download/v#{version}/Panoptos.dmg"
  name "Panoptos"
  desc "Window manager with persistent monitor sections and window switching"
  homepage "https://panoptos.ruverse.ai/"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on macos: :sonoma

  app "Panoptos.app"
end
'''.replace("VERSION", args.version).replace("SHA256", digest.hexdigest())
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(cask)
    print(f"Prepared {args.output} (SHA-256 {digest.hexdigest()})")
    print("Local draft only. Publish after the signed/notarized GitHub asset is public")
    print("and its downloaded bytes match this digest. Normal uninstall preserves settings.")


if __name__ == "__main__":
    main()
