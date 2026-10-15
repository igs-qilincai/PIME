"""Tests of the libchewing patches in macos/patches/libchewing.

PIME opens one libchewing context per input client, all in the same backend
process and on the same user phrase database. These tests check that no
context leaves the database locked for the others.

Usage: test_userphrase_db.py <libchewing.dylib> <data dir>

Written with assistance from Claude Code (Claude Opus 5.5).
"""

import ctypes
import os
import sqlite3
import sys
import tempfile
import unittest

LIB_PATH = None
DATA_DIR = None


class Chewing:
    """A minimal ctypes binding of the libchewing calls used here."""

    def __init__(self, lib_path):
        self.lib = lib = ctypes.CDLL(lib_path)
        lib.chewing_new2.restype = ctypes.c_void_p
        lib.chewing_new2.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_void_p]
        for name in ("delete", "handle_Enter", "handle_Home", "handle_Down"):
            getattr(lib, "chewing_" + name).argtypes = [ctypes.c_void_p]
        for name in ("handle_Default", "set_maxChiSymbolLen"):
            getattr(lib, "chewing_" + name).argtypes = [ctypes.c_void_p, ctypes.c_int]
        lib.chewing_userphrase_add.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p]

    def new(self, data_dir, user_path):
        ctx = self.lib.chewing_new2(data_dir.encode(), user_path.encode(), None, None)
        if ctx:
            self.lib.chewing_set_maxChiSymbolLen(ctx, 50)
        return ctx

    def type(self, ctx, keys):
        """Types keys of the default (Dachen) layout, or "<Name>" for other keys."""
        for key in keys.split():
            if key.startswith("<"):
                getattr(self.lib, "chewing_handle_" + key[1:-1])(ctx)
            else:
                for ch in key:
                    self.lib.chewing_handle_Default(ctx, ord(ch))


class UserPhraseDatabaseTest(unittest.TestCase):
    def setUp(self):
        self.chewing = Chewing(LIB_PATH)
        self.tmp = tempfile.TemporaryDirectory()
        self.user_path = os.path.join(self.tmp.name, "chewing.sqlite3")
        self.contexts = []

    def tearDown(self):
        for ctx in self.contexts:
            self.chewing.lib.chewing_delete(ctx)
        self.tmp.cleanup()

    def new_context(self):
        ctx = self.chewing.new(DATA_DIR, self.user_path)
        if ctx:
            self.contexts.append(ctx)
        return ctx

    def assert_database_unlocked(self):
        con = sqlite3.connect(self.user_path, timeout=0, isolation_level=None)
        try:
            con.execute("BEGIN EXCLUSIVE")
            con.execute("ROLLBACK")
        except sqlite3.OperationalError as e:
            self.fail("the user phrase database is locked: %s" % e)
        finally:
            con.close()

    def test_choosing_a_user_phrase_releases_the_database(self):
        first = self.new_context()
        second = self.new_context()
        self.assertTrue(first and second)
        # ㄋㄧˇ ㄨˋ: auto-learn stores 你 and 勿, then add 你勿, which is not in
        # the dictionary.
        self.chewing.type(first, "su3j4 <Enter>")
        self.assertEqual(self.chewing.lib.chewing_userphrase_add(
            first, "你勿".encode(), "ㄋㄧˇ ㄨˋ".encode()), 1)

        # Choosing 你勿 makes FindInterval() stop at the first row of the
        # user phrase query of 你 or 勿.
        self.chewing.type(second, "su3j4 <Home> <Down> 1")
        self.assert_database_unlocked()

        # Auto-learning in another context has to commit, or new contexts
        # cannot be created.
        self.chewing.type(first, "cl3 <Enter>")
        self.assert_database_unlocked()
        self.assertTrue(self.new_context(), "chewing_new2() failed")

    def test_failed_auto_learn_commit_is_rolled_back(self):
        ctx = self.new_context()
        self.assertTrue(ctx)
        self.chewing.type(ctx, "su3j4 <Enter>")

        # Another reader makes the commit of the next auto-learn fail.
        reader = sqlite3.connect(self.user_path)
        rows = reader.execute("SELECT phrase FROM userphrase_v1")
        self.assertIsNotNone(rows.fetchone())
        self.chewing.type(ctx, "cl3 <Enter>")
        reader.close()

        self.assert_database_unlocked()
        self.assertTrue(self.new_context(), "chewing_new2() failed")


def main():
    global LIB_PATH, DATA_DIR
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    LIB_PATH, DATA_DIR = sys.argv[1], sys.argv[2]
    unittest.main(argv=sys.argv[:1] + sys.argv[3:])


if __name__ == "__main__":
    main()
