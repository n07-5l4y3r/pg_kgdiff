# main.py
import pyximport

pyximport.install(language_level=3, inplace=True)

import kgdiff1


SIGN_BIT = 1 << 63
VALUE_MASK = SIGN_BIT - 1

KGDIFF_MAGIC = b"KGDIFF1\x00"

KGDIFF_HEADER_SIZE = 48
KGDIFF_CONTROL_SIZE = 24

KGDIFF_CODEC_RAW = 0
KGDIFF_CODEC_ZLIB_MIN = 1
KGDIFF_CODEC_ZLIB_MAX = 9

MAX_DUMP_BYTES = 768


def read_u63be(data: bytes, offset: int) -> int:
    if offset + 8 > len(data):
        raise ValueError("unexpected EOF while reading u63be")

    raw = int.from_bytes(data[offset:offset + 8], "big")

    if raw & SIGN_BIT:
        raise ValueError("sign bit set in u63be")

    return raw


def read_i63be(data: bytes, offset: int) -> int:
    if offset + 8 > len(data):
        raise ValueError("unexpected EOF while reading i63be")

    raw = int.from_bytes(data[offset:offset + 8], "big")
    magnitude = raw & VALUE_MASK
    negative = bool(raw & SIGN_BIT)

    if negative and magnitude == 0:
        raise ValueError("negative zero in i63be")

    return -magnitude if negative else magnitude


def read_section_desc(data: bytes, offset: int):
    if offset + 8 > len(data):
        raise ValueError("unexpected EOF while reading section descriptor")

    codec = data[offset]

    if codec & 0x80:
        raise ValueError("section codec reserved bit set")

    if data[offset + 1] & 0x80:
        raise ValueError("section size reserved bit set")

    payload_size = (
        ((data[offset + 1] & 0x7F) << 48)
        | (data[offset + 2] << 40)
        | (data[offset + 3] << 32)
        | (data[offset + 4] << 24)
        | (data[offset + 5] << 16)
        | (data[offset + 6] << 8)
        | data[offset + 7]
    )

    return codec, payload_size


def codec_name(codec: int) -> str:
    if codec == KGDIFF_CODEC_RAW:
        return "raw"

    if KGDIFF_CODEC_ZLIB_MIN <= codec <= KGDIFF_CODEC_ZLIB_MAX:
        return f"zlib{codec}"

    return f"unknown({codec})"


def ascii_view(data: bytes) -> str:
    return "".join(chr(b) if 32 <= b <= 126 else "." for b in data)


def dump_hex_rows(
    label: str,
    data: bytes,
    row_size: int = 24,
    max_bytes: int = MAX_DUMP_BYTES,
):
    print(label)

    shown = data[:max_bytes]

    for index in range(0, len(shown), row_size):
        row = shown[index:index + row_size]
        row_index = index // row_size
        print(f"  {row_index:02d}: {row.hex(' '):<71} |{ascii_view(row)}|")

    if len(data) > max_bytes:
        print(f"  ... truncated, shown {max_bytes} of {len(data)} bytes")


def ratio_text(a: int, b: int) -> str:
    if b == 0:
        return "n/a"
    return f"{a / b:.3f}"


def delta_text(a: int, b: int) -> str:
    return f"{a - b:+d}"


def read_header(patch: bytes):
    if len(patch) < KGDIFF_HEADER_SIZE:
        raise ValueError("patch shorter than KGDIFF1 header")

    if patch[:8] != KGDIFF_MAGIC:
        raise ValueError(f"bad KGDIFF magic: {patch[:8]!r}")

    old_size = read_u63be(patch, 8)
    new_size = read_u63be(patch, 16)

    control_codec, control_size = read_section_desc(patch, 24)
    diff_codec, diff_size = read_section_desc(patch, 32)
    extra_codec, extra_size = read_section_desc(patch, 40)

    control_offset = KGDIFF_HEADER_SIZE
    diff_offset = control_offset + control_size
    extra_offset = diff_offset + diff_size
    end_offset = extra_offset + extra_size

    if end_offset != len(patch):
        raise ValueError(
            f"KGDIFF section size mismatch: expected={end_offset}, actual={len(patch)}"
        )

    return {
        "old_size": old_size,
        "new_size": new_size,
        "control_codec": control_codec,
        "control_size": control_size,
        "diff_codec": diff_codec,
        "diff_size": diff_size,
        "extra_codec": extra_codec,
        "extra_size": extra_size,
        "control_offset": control_offset,
        "diff_offset": diff_offset,
        "extra_offset": extra_offset,
        "end_offset": end_offset,
    }


def patch_sections(patch: bytes):
    header = read_header(patch)

    control = patch[header["control_offset"]:header["diff_offset"]]
    diff = patch[header["diff_offset"]:header["extra_offset"]]
    extra = patch[header["extra_offset"]:header["end_offset"]]

    return header, control, diff, extra


def parse_raw_blocks(raw_patch: bytes):
    raw_header, control_raw, diff_raw, extra_raw = patch_sections(raw_patch)

    if raw_header["control_codec"] != KGDIFF_CODEC_RAW:
        raise ValueError("raw patch control section is not raw")

    if raw_header["diff_codec"] != KGDIFF_CODEC_RAW:
        raise ValueError("raw patch diff section is not raw")

    if raw_header["extra_codec"] != KGDIFF_CODEC_RAW:
        raise ValueError("raw patch extra section is not raw")

    if len(control_raw) % KGDIFF_CONTROL_SIZE != 0:
        raise ValueError("control section size is not divisible by 24")

    control_pos = 0
    diff_pos = 0
    extra_pos = 0
    new_pos = 0
    blocks = []

    block_count = len(control_raw) // KGDIFF_CONTROL_SIZE

    for block_index in range(block_count):
        control_offset = control_pos

        diff_len = read_u63be(control_raw, control_pos)
        extra_len = read_u63be(control_raw, control_pos + 8)
        seek_delta = read_i63be(control_raw, control_pos + 16)

        control_pos += KGDIFF_CONTROL_SIZE

        if diff_len > raw_header["new_size"] - new_pos:
            raise ValueError("diff_len exceeds remaining output")

        if extra_len > raw_header["new_size"] - new_pos - diff_len:
            raise ValueError("extra_len exceeds remaining output")

        if diff_pos + diff_len > len(diff_raw):
            raise ValueError("diff block exceeds diff section")

        if extra_pos + extra_len > len(extra_raw):
            raise ValueError("extra block exceeds extra section")

        diff_data = diff_raw[diff_pos:diff_pos + diff_len]
        extra_data = extra_raw[extra_pos:extra_pos + extra_len]

        diff_pos += diff_len
        extra_pos += extra_len
        new_pos += diff_len + extra_len

        blocks.append(
            {
                "index": block_index,
                "control_offset": control_offset,
                "diff_len": diff_len,
                "extra_len": extra_len,
                "seek_delta": seek_delta,
                "diff_data": diff_data,
                "extra_data": extra_data,
            }
        )

    if diff_pos != len(diff_raw):
        raise ValueError("diff section was not consumed exactly")

    if extra_pos != len(extra_raw):
        raise ValueError("extra section was not consumed exactly")

    if new_pos != raw_header["new_size"]:
        raise ValueError(
            f"decoded new size mismatch: decoded={new_pos}, header={raw_header['new_size']}"
        )

    raw_header["block_count"] = block_count
    raw_header["blocks"] = blocks
    raw_header["control_raw"] = control_raw
    raw_header["diff_raw"] = diff_raw
    raw_header["extra_raw"] = extra_raw

    return raw_header


def print_size_summary(old: bytes, new_expected: bytes, patch: bytes, raw_patch: bytes):
    old_size = len(old)
    new_size = len(new_expected)
    patch_size = len(patch)
    raw_size = len(raw_patch)

    print("size summary:")
    print(f"  old_size:              {old_size}")
    print(f"  new_size:              {new_size}")
    print(f"  kgdiff_size:           {patch_size}")
    print(f"  raw_equiv_size:        {raw_size}")
    print(f"  saved_vs_raw:          {delta_text(patch_size, raw_size)}")
    print(f"  kgdiff/raw_equiv:      {ratio_text(patch_size, raw_size)}")
    print(f"  kgdiff/old:            {ratio_text(patch_size, old_size)}")
    print(f"  kgdiff/new:            {ratio_text(patch_size, new_size)}")
    print(f"  kgdiff-new:            {delta_text(patch_size, new_size)}")


def print_header_summary(patch: bytes, raw_patch: bytes):
    header, control_payload, diff_payload, extra_payload = patch_sections(patch)
    raw_info = parse_raw_blocks(raw_patch)

    print()
    print("header summary:")
    print(f"  magic:                 {patch[:8]!r}")
    print(f"  old_size:              {header['old_size']}")
    print(f"  new_size:              {header['new_size']}")
    print(f"  block_count:           {raw_info['block_count']}")

    print()
    print("section summary:")
    print(
        f"  control:               "
        f"{len(raw_info['control_raw'])} -> {len(control_payload)} "
        f"({codec_name(header['control_codec'])})"
    )
    print(
        f"  diff:                  "
        f"{len(raw_info['diff_raw'])} -> {len(diff_payload)} "
        f"({codec_name(header['diff_codec'])})"
    )
    print(
        f"  extra:                 "
        f"{len(raw_info['extra_raw'])} -> {len(extra_payload)} "
        f"({codec_name(header['extra_codec'])})"
    )

    print()
    print("offsets:")
    print(f"  control_offset:        {header['control_offset']}")
    print(f"  diff_offset:           {header['diff_offset']}")
    print(f"  extra_offset:          {header['extra_offset']}")
    print(f"  end_offset:            {header['end_offset']}")

    return header, raw_info


def dump_payload_sections(patch: bytes):
    header, control_payload, diff_payload, extra_payload = patch_sections(patch)

    print()
    dump_hex_rows("KGDIFF header, 48 bytes:", patch[:KGDIFF_HEADER_SIZE])

    print()
    dump_hex_rows(
        f"stored control payload ({codec_name(header['control_codec'])}):",
        control_payload,
    )

    print()
    dump_hex_rows(
        f"stored diff payload ({codec_name(header['diff_codec'])}):",
        diff_payload,
    )

    print()
    dump_hex_rows(
        f"stored extra payload ({codec_name(header['extra_codec'])}):",
        extra_payload,
    )


def dump_decoded_sections(raw_info):
    print()
    dump_hex_rows("decoded control table:", raw_info["control_raw"])

    print()
    dump_hex_rows("decoded diff data:", raw_info["diff_raw"])

    print()
    dump_hex_rows("decoded extra data:", raw_info["extra_raw"])


def dump_blocks(raw_info):
    print()
    print("decoded blocks:")

    for block in raw_info["blocks"]:
        print()
        print(f"block {block['index']}:")
        print(f"  control_offset: {block['control_offset']}")
        print(f"  diff_len:       {block['diff_len']}")
        print(f"  extra_len:      {block['extra_len']}")
        print(f"  seek_delta:     {block['seek_delta']}")

        dump_hex_rows("  diff:", block["diff_data"])
        dump_hex_rows("  extra:", block["extra_data"])


def assert_header_matches_input(raw_info, old: bytes, new_expected: bytes, label: str):
    if raw_info["old_size"] != len(old):
        raise AssertionError(
            f"{label}: old_size header mismatch: "
            f"header={raw_info['old_size']}, actual={len(old)}"
        )

    if raw_info["new_size"] != len(new_expected):
        raise AssertionError(
            f"{label}: new_size header mismatch: "
            f"header={raw_info['new_size']}, actual={len(new_expected)}"
        )


def assert_fragment_not_in_extra(raw_info, fragment: bytes, label: str):
    for block in raw_info["blocks"]:
        if fragment in block["extra_data"]:
            raise AssertionError(
                f"{label}: fragment appears literally in decoded extra data "
                f"in block {block['index']}"
            )


def assert_fragment_may_be_in_extra(raw_info, fragment: bytes, label: str):
    found = any(fragment in block["extra_data"] for block in raw_info["blocks"])

    if not found:
        raise AssertionError(
            f"{label}: expected fragment to appear literally in decoded extra data"
        )


def assert_has_zero_diff_run(raw_info, minimum_length: int, label: str):
    needle = b"\x00" * minimum_length

    for block in raw_info["blocks"]:
        if needle in block["diff_data"]:
            return

    raise AssertionError(
        f"{label}: expected at least {minimum_length} zero diff bytes"
    )


def run_case(
    label: str,
    old: bytes,
    new_expected: bytes,
    fragments_not_in_extra=(),
    fragments_may_be_in_extra=(),
    expected_zero_diff_run=0,
    dump=True,
):
    print()
    print("=" * 96)
    print(label)
    print("=" * 96)

    patch = kgdiff1.diff(old, new_expected)
    raw_patch = kgdiff1.unpack_raw(patch)
    repacked_patch = kgdiff1.pack(raw_patch)

    assert patch[:8] == KGDIFF_MAGIC, f"{label}: diff did not return KGDIFF1"
    assert raw_patch[:8] == KGDIFF_MAGIC, f"{label}: unpack_raw did not return KGDIFF1"
    assert repacked_patch[:8] == KGDIFF_MAGIC, f"{label}: pack did not return KGDIFF1"

    assert kgdiff1.patch(old, patch) == new_expected, f"{label}: patch failed"
    assert kgdiff1.patch_raw(old, raw_patch) == new_expected, f"{label}: patch_raw failed"
    assert kgdiff1.patch(old, repacked_patch) == new_expected, f"{label}: repacked patch failed"

    print_size_summary(old, new_expected, patch, raw_patch)

    _, raw_info = print_header_summary(patch, raw_patch)

    assert_header_matches_input(raw_info, old, new_expected, label)

    for fragment in fragments_not_in_extra:
        assert_fragment_not_in_extra(raw_info, fragment, label)

    for fragment in fragments_may_be_in_extra:
        assert_fragment_may_be_in_extra(raw_info, fragment, label)

    if expected_zero_diff_run:
        assert_has_zero_diff_run(raw_info, expected_zero_diff_run, label)

    if dump:
        dump_payload_sections(patch)
        dump_decoded_sections(raw_info)
        dump_blocks(raw_info)

    return patch, raw_info


def run_file_case(label: str, old_path: str, new_path: str):
    with open(old_path, "rb") as f:
        old = f.read()

    with open(new_path, "rb") as f:
        new_expected = f.read()

    return run_case(
        label=label,
        old=old,
        new_expected=new_expected,
        dump=False,
    )


def main():
    kgdiff1.selftest()

    run_case(
        label="01 short match may remain literal extra",
        old=b"hello world",
        new_expected=b"hello brave new world",
        fragments_may_be_in_extra=(b"world",),
    )

    fragment_24 = b"ABCDEFGHIJKLMNOPQRSTUVWX"
    assert len(fragment_24) == 24

    run_case(
        label="02 exact 24-byte reusable fragment must not be extra",
        old=b"old-prefix--" + fragment_24 + b"--old-suffix",
        new_expected=b"new-prefix--" + fragment_24 + b"--new-suffix",
        fragments_not_in_extra=(fragment_24,),
        expected_zero_diff_run=24,
    )

    fragment_32 = b"abcdefghijklmnopqrstuvwxyz012345"
    assert len(fragment_32) == 32

    run_case(
        label="03 32-byte reusable fragment must not be extra",
        old=b"AAA-" + fragment_32 + b"-BBB",
        new_expected=b"CCC-" + fragment_32 + b"-DDD",
        fragments_not_in_extra=(fragment_32,),
        expected_zero_diff_run=32,
    )

    fragment_48 = (
        b"0123456789ABCDEF"
        b"0123456789ABCDEF"
        b"0123456789ABCDEF"
    )
    assert len(fragment_48) == 48

    run_case(
        label="04 shifted 48-byte reusable fragment must not be extra",
        old=b"header:" + fragment_48 + b":footer",
        new_expected=b"INSERT-A:" + fragment_48 + b":INSERT-B",
        fragments_not_in_extra=(fragment_48,),
        expected_zero_diff_run=48,
    )

    fragment_64 = bytes((65 + (i % 26) for i in range(64)))
    assert len(fragment_64) == 64

    run_case(
        label="05 mixed literals around 64-byte reusable fragment",
        old=b"OLD0" + fragment_64 + b"OLD1",
        new_expected=b"x" + fragment_64 + b"y",
        fragments_not_in_extra=(fragment_64,),
        expected_zero_diff_run=64,
    )

    print()
    print("=" * 96)
    print("all tests passed")
    print("=" * 96)


if __name__ == "__main__":
    main()
