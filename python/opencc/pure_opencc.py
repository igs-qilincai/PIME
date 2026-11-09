# python3
# Pure Python implementation of the OpenCC converter, for platforms where
# opencc.dll cannot be loaded (e.g. macOS).
#
# It reads the same JSON configs and .ocd dictionaries in this directory as
# the bundled OpenCC 1.0.4 library and follows the same algorithm, so the
# output is the same as on Windows:
#
# 1. Segmentation ("mmseg"): split the text into the longest phrases found in
#    the segmentation dictionary, and runs of text without such phrases.
# 2. Each step of the conversion chain converts every segment on its own:
#    at each position, the longest key of the step's dictionary is replaced
#    by its first value, and characters without a key are kept.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# Written with assistance from Claude Code (Claude Opus 5.5).

import functools
import json
import os
import struct

_OCD_HEADER = b"OPENCCDARTS1"
# The .ocd files were written by a 32-bit build of OpenCC, so every size_t
# in them is 4 bytes.
_SIZE_T = struct.Struct("<I")


@functools.lru_cache(maxsize=None)
def load_ocd(path):
    """Return the lexicon of a .ocd dictionary as a {key: [values]} dict.

    A .ocd file holds the header, a darts double array, which the C++ code
    uses for lookups and is skipped here, and the serialized lexicon:
    the number of entries, the NUL-terminated keys, the NUL-terminated
    values, and for each entry its number of values, the offset of its key
    and the offsets of its values.

    The result is cached and shared, so callers must not modify it.
    """
    with open(path, "rb") as f:
        data = f.read()
    if not data.startswith(_OCD_HEADER):
        raise ValueError("not an OpenCC .ocd file: " + path)
    try:
        pos = len(_OCD_HEADER)

        def read_size():
            nonlocal pos
            value, = _SIZE_T.unpack_from(data, pos)
            pos += _SIZE_T.size
            return value

        def read_bytes(length):
            nonlocal pos
            if pos + length > len(data):
                raise ValueError("truncated")
            chunk = data[pos:pos + length]
            pos += length
            return chunk

        def string_at(buf, offset):
            return buf[offset:buf.index(b"\0", offset)].decode("utf-8")

        darts_size = read_size()
        read_bytes(darts_size)
        num_entries = read_size()
        keys = read_bytes(read_size())
        values = read_bytes(read_size())
        lexicon = {}
        for _ in range(num_entries):
            num_values = read_size()
            key = string_at(keys, read_size())
            lexicon[key] = [string_at(values, read_size()) for _ in range(num_values)]
    except (struct.error, ValueError) as e:  # ValueError includes UnicodeDecodeError
        raise ValueError("corrupt OpenCC .ocd file: {}: {}".format(path, e)) from e
    if pos != len(data):
        raise ValueError("unexpected data at the end of OpenCC .ocd file: " + path)
    return lexicon


class _Dict:
    """One .ocd dictionary."""

    def __init__(self, path):
        self.lexicon = load_ocd(path)
        self.max_key_length = max(map(len, self.lexicon), default=0)

    def match_prefix(self, text, start):
        """Return (length, first value) of the longest key at text[start:],
        or None if no key matches."""
        for length in range(min(self.max_key_length, len(text) - start), 0, -1):
            values = self.lexicon.get(text[start:start + length])
            if values is not None:
                return length, values[0]
        return None


class _DictGroup:
    """Dictionaries tried in order."""

    def __init__(self, dicts):
        self.dicts = dicts

    def match_prefix(self, text, start):
        # Like OpenCC, take the match of the first dictionary that has one,
        # even if a later dictionary has a longer match.
        for d in self.dicts:
            match = d.match_prefix(text, start)
            if match is not None:
                return match
        return None


def _load_dict(config, config_dir):
    dict_type = config.get("type")
    if dict_type == "ocd":
        return _Dict(os.path.join(config_dir, config["file"]))
    if dict_type == "group":
        return _DictGroup([_load_dict(d, config_dir) for d in config["dicts"]])
    raise ValueError("unsupported OpenCC dictionary type: {!r}".format(dict_type))


class OpenCC:
    def __init__(self, configName):
        """Load an OpenCC JSON config, e.g. OPENCC_DEFAULT_CONFIG_TRAD_TO_SIMP.

        A relative name is looked up in the directory of this module.
        """
        config_dir = os.path.dirname(os.path.abspath(__file__))
        if not os.path.isabs(configName):
            configName = os.path.join(config_dir, configName)
        else:
            config_dir = os.path.dirname(configName)
        with open(configName, encoding="utf-8") as f:
            config = json.load(f)
        segmentation = config["segmentation"]
        if segmentation.get("type") != "mmseg":
            raise ValueError("unsupported OpenCC segmentation type: {!r}".format(
                segmentation.get("type")))
        self._segmentation_dict = _load_dict(segmentation["dict"], config_dir)
        self._conversion_chain = [_load_dict(conversion["dict"], config_dir)
                                  for conversion in config["conversion_chain"]]

    def _segment(self, text):
        segments = []
        unmatched_start = 0
        pos = 0
        while pos < len(text):
            match = self._segmentation_dict.match_prefix(text, pos)
            if match is None:
                pos += 1
                continue
            if unmatched_start < pos:
                segments.append(text[unmatched_start:pos])
            length = match[0]
            segments.append(text[pos:pos + length])
            pos += length
            unmatched_start = pos
        if unmatched_start < pos:
            segments.append(text[unmatched_start:pos])
        return segments

    @staticmethod
    def _convert_segment(conversion_dict, segment):
        result = []
        pos = 0
        while pos < len(segment):
            match = conversion_dict.match_prefix(segment, pos)
            if match is None:
                result.append(segment[pos])
                pos += 1
            else:
                length, value = match
                result.append(value)
                pos += length
        return "".join(result)

    def convert(self, from_str):
        segments = self._segment(from_str)
        for conversion_dict in self._conversion_chain:
            segments = [self._convert_segment(conversion_dict, segment) for segment in segments]
        return "".join(segments)
