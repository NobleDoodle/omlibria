#!/usr/bin/env python3
"""Source checks for the QML.

Qt 6.12 adds a QtQuick type named Color, which shadows the qs.Commons Color
singleton: a bare `Color.foreground` evaluates to undefined and Omlibria draws
in black. The QML reaches the singleton through the module alias instead.

    python3 tests/test_qml.py
"""
import os
import re
import unittest

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
BARE_COLOR = re.compile(r"(^|[^A-Za-z0-9_.])Color\.")


def qml_files():
    for name in sorted(os.listdir(ROOT)):
        if name.endswith(".qml"):
            yield os.path.join(ROOT, name)


class CommonsColorAlias(unittest.TestCase):
    def test_no_bare_color(self):
        for path in qml_files():
            with open(path, encoding="utf-8") as f:
                source = f.read()
            bare = [line for line in source.splitlines() if BARE_COLOR.search(line)]
            self.assertEqual(bare, [], f"{os.path.basename(path)} uses a bare Color.")
            if "Commons.Color." in source:
                self.assertRegex(source, re.compile(r"^import qs\.Commons as Commons$", re.M),
                                 f"{os.path.basename(path)} lacks the Commons alias")


if __name__ == "__main__":
    unittest.main()
