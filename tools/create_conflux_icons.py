"""Compatibility entry point; the approved application name is now Faculae."""

import argparse

from create_facula_icons import EXPORT, approved_images, install_icons, write_iconset


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--install", action="store_true")
    options = parser.parse_args()
    destination = install_icons() if options.install else write_iconset(EXPORT)
    print(f"Faculae approved light/dark icon set: {destination}")
