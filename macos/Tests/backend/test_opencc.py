"""Tests of the pure Python OpenCC converter (python/opencc/pure_opencc.py).

Usage: test_opencc.py <PIME python dir>

Written with assistance from Claude Code (Claude Opus 5.5).
"""

import json
import os
import struct
import sys
import tempfile
import unittest

opencc = None
pure_opencc = None


def write_ocd(path, lexicon):
    """Write {key: [values]} in the .ocd format of 32-bit OpenCC 1.0.x.

    The darts double array is left empty since the reader skips it.
    """
    keys, values, entries = b"", b"", []
    for key, key_values in lexicon.items():
        entry = [len(key_values), len(keys)]
        keys += key.encode("utf-8") + b"\0"
        for value in key_values:
            entry.append(len(values))
            values += value.encode("utf-8") + b"\0"
        entries.append(entry)
    size = struct.Struct("<I").pack
    with open(path, "wb") as f:
        f.write(b"OPENCCDARTS1" + size(0) + size(len(lexicon)))
        f.write(size(len(keys)) + keys + size(len(values)) + values)
        for entry in entries:
            f.write(b"".join(size(n) for n in entry))


class LoadOcdTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def test_bundled_dictionary(self):
        lexicon = pure_opencc.load_ocd(os.path.join(os.path.dirname(opencc.__file__), "TSCharacters.ocd"))
        self.assertEqual(len(lexicon), 4189)
        self.assertEqual(lexicon["乾"], ["干", "乾"])
        self.assertEqual(lexicon["㑮"], ["𫝈"])  # outside the BMP

    def test_round_trip(self):
        path = os.path.join(self.tmp.name, "test.ocd")
        lexicon = {"甲": ["乙", "丙"], "丁戊": ["己"]}
        write_ocd(path, lexicon)
        self.assertEqual(pure_opencc.load_ocd(path), lexicon)

    def test_rejects_other_files(self):
        path = os.path.join(self.tmp.name, "bad.ocd")
        with open(path, "wb") as f:
            f.write(b"OPENCCMARISA" + b"\0" * 16)
        with self.assertRaisesRegex(ValueError, "not an OpenCC"):
            pure_opencc.load_ocd(path)

    def test_rejects_truncated_files(self):
        path = os.path.join(self.tmp.name, "truncated.ocd")
        write_ocd(path, {"甲": ["乙"]})
        with open(path, "r+b") as f:
            f.truncate(os.path.getsize(path) - 2)
        with self.assertRaisesRegex(ValueError, "corrupt"):
            pure_opencc.load_ocd(path)


class BundledConfigTest(unittest.TestCase):
    def test_package_uses_pure_python_without_library(self):
        self.assertIs(opencc.OpenCC, pure_opencc.OpenCC)

    def test_traditional_to_simplified(self):
        converter = opencc.OpenCC(opencc.OPENCC_DEFAULT_CONFIG_TRAD_TO_SIMP)
        self.assertEqual(converter.convert("臺灣國語"), "台湾国语")
        # The phrase keeps 乾, while the character alone becomes 干.
        self.assertEqual(converter.convert("乾坤大挪移，乾淨"), "乾坤大挪移，干净")
        self.assertEqual(converter.convert("一目瞭然"), "一目了然")
        self.assertEqual(converter.convert("㑮"), "𫝈")
        self.assertEqual(converter.convert("PIME 2.0, ok!"), "PIME 2.0, ok!")
        self.assertEqual(converter.convert(""), "")

    def test_simplified_to_traditional(self):
        converter = opencc.OpenCC(opencc.OPENCC_DEFAULT_CONFIG_SIMP_TO_TRAD)
        self.assertEqual(converter.convert("头发"), "頭髮")
        self.assertEqual(converter.convert("发现"), "發現")

    def test_conversion_chain(self):
        converter = opencc.OpenCC("tw2sp.json")
        self.assertEqual(converter.convert("軟體和滑鼠"), "软件和鼠标")


class AlgorithmTest(unittest.TestCase):
    """Rules of OpenCC that the bundled data does not show clearly."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def make_converter(self, segmentation, conversion_chain, dicts):
        for name, lexicon in dicts.items():
            write_ocd(os.path.join(self.tmp.name, name), lexicon)
        config = os.path.join(self.tmp.name, "test.json")
        with open(config, "w", encoding="utf-8") as f:
            json.dump({"segmentation": {"type": "mmseg", "dict": segmentation},
                       "conversion_chain": [{"dict": d} for d in conversion_chain]}, f)
        return opencc.OpenCC(config)

    @staticmethod
    def ocd(name):
        return {"type": "ocd", "file": name}

    def test_matches_do_not_cross_segments(self):
        converter = self.make_converter(self.ocd("seg.ocd"), [self.ocd("conv.ocd")], {
            "seg.ocd": {"甲乙": ["甲乙"]},
            "conv.ocd": {"乙丙": ["X"], "丙": ["Y"]},
        })
        # 甲乙 is one segment, so 乙丙 cannot match.
        self.assertEqual(converter.convert("甲乙丙"), "甲乙Y")
        self.assertEqual(converter.convert("乙丙"), "X")

    def test_first_dictionary_of_a_group_wins(self):
        group = {"type": "group", "dicts": [self.ocd("short.ocd"), self.ocd("long.ocd")]}
        converter = self.make_converter(self.ocd("seg.ocd"), [group], {
            "seg.ocd": {},
            "short.ocd": {"甲": ["X"]},
            "long.ocd": {"甲乙": ["Y"], "乙": ["Z"]},
        })
        self.assertEqual(converter.convert("甲乙"), "XZ")

    def test_longest_key_wins_within_a_dictionary(self):
        converter = self.make_converter(self.ocd("seg.ocd"), [self.ocd("conv.ocd")], {
            "seg.ocd": {},
            "conv.ocd": {"甲": ["X"], "甲乙": ["Y", "W"]},
        })
        self.assertEqual(converter.convert("甲乙甲"), "YX")

    def test_steps_of_the_chain_run_in_order(self):
        converter = self.make_converter(self.ocd("seg.ocd"),
                                        [self.ocd("first.ocd"), self.ocd("second.ocd")], {
            "seg.ocd": {},
            "first.ocd": {"甲": ["乙"]},
            "second.ocd": {"乙": ["丙"]},
        })
        self.assertEqual(converter.convert("甲"), "丙")

    def test_unsupported_dictionary_type(self):
        with self.assertRaisesRegex(ValueError, "unsupported OpenCC dictionary type"):
            self.make_converter({"type": "text", "file": "seg.txt"}, [], {})


def main():
    global opencc, pure_opencc
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    sys.path.insert(0, os.path.abspath(sys.argv[1]))
    import opencc
    from opencc import pure_opencc
    unittest.main(argv=sys.argv[:1] + sys.argv[2:])


if __name__ == "__main__":
    main()
