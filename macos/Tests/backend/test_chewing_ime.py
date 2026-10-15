"""Tests of the chewing input method of the Python backend (python/).

libchewing is replaced by a fake, so no library has to be built.

Usage: test_chewing_ime.py <PIME python dir>

Written with assistance from Claude Code (Claude Opus 5.5).
"""

import os
import sys
import tempfile
import types
import unittest

ChewingTextService = None


class FakeChewingContext:
    """Stands in for libchewing.ChewingContext."""

    fail = False

    def __init__(self, **kwargs):
        if FakeChewingContext.fail:
            raise OSError("libchewing cannot create a context")
        self.lang_mode = 1
        self.shape_mode = 0

    def get_ChiEngMode(self):
        return self.lang_mode

    def set_ChiEngMode(self, mode):
        self.lang_mode = mode

    def get_ShapeMode(self):
        return self.shape_mode

    def set_ShapeMode(self, mode):
        self.shape_mode = mode

    def __getattr__(self, name):
        return lambda *args: 0


def key_request(method, char):
    return {"method": method, "seqNum": 0, "charCode": ord(char), "keyCode": ord(char.upper()),
            "repeatCount": 1, "scanCode": 0, "isExtended": False, "keyStates": [0] * 256}


class ChewingTextServiceTest(unittest.TestCase):
    def setUp(self):
        FakeChewingContext.fail = False
        client = types.SimpleNamespace(isWindows8Above=True, isMetroApp=False, isUiLess=False, isConsole=False)
        self.service = ChewingTextService(client)

    def test_keys_go_to_the_app_until_libchewing_starts(self):
        FakeChewingContext.fail = True
        reply = self.service.handleRequest({"method": "onActivate", "isKeyboardOpen": True, "seqNum": 0})
        self.assertTrue(reply["success"])
        self.assertIsNone(self.service.chewingContext)
        # Swallowing the key would make typing silently do nothing.
        self.assertIs(self.service.handleRequest(key_request("filterKeyDown", "v"))["return"], False)

        # Retried on the next key.
        FakeChewingContext.fail = False
        reply = self.service.handleRequest(key_request("filterKeyDown", "v"))
        self.assertIs(reply["return"], True)
        self.assertIsNotNone(self.service.chewingContext)
        self.assertIn("changeButton", reply)

    def test_no_retry_after_deactivation(self):
        FakeChewingContext.fail = True
        self.service.handleRequest({"method": "onActivate", "isKeyboardOpen": True, "seqNum": 0})
        self.service.handleRequest({"method": "onDeactivate", "seqNum": 0})
        FakeChewingContext.fail = False
        self.assertIs(self.service.handleRequest(key_request("filterKeyDown", "v"))["return"], False)
        self.assertIsNone(self.service.chewingContext)


def main():
    global ChewingTextService
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    # Keep chewing's settings away from the user's.
    home = tempfile.TemporaryDirectory()
    os.environ["HOME"] = home.name
    sys.path.insert(0, os.path.abspath(sys.argv[1]))
    fake = types.ModuleType("libchewing")
    fake.ChewingContext = FakeChewingContext
    fake.CHEWING_DATA_DIR = home.name
    fake.CHINESE_MODE, fake.ENGLISH_MODE, fake.FULLSHAPE_MODE, fake.HALFSHAPE_MODE = 1, 0, 1, 0
    sys.modules["libchewing"] = fake
    from input_methods.chewing.chewing_ime import ChewingTextService
    unittest.main(argv=sys.argv[:1] + sys.argv[2:])


if __name__ == "__main__":
    main()
