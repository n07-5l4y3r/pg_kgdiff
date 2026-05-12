# pg_kgdiff1.py

import kgdiff1

def _as_bytes(value, name: str) -> bytes:
    if value is None:
        raise ValueError(f"{name} must not be NULL")

    if isinstance(value, bytes):
        return value

    if isinstance(value, bytearray):
        return bytes(value)

    if isinstance(value, memoryview):
        return value.tobytes()

    try:
        return bytes(value)
    except Exception as exc:
        raise TypeError(f"{name} must be bytea/bytes-compatible") from exc


def _validate_patch(patch: bytes) -> None:
    # Uses Cython parser/decompressor/format validation.
    kgdiff1.info(patch)


def kg_diff(from_data, to_data) -> bytes:
    old = _as_bytes(from_data, "from_data")
    new = _as_bytes(to_data, "to_data")
    patch = kgdiff1.diff(old, new)

    _validate_patch(patch)

    return patch


def kg_patch(from_data, patch_data) -> bytes:
    old = _as_bytes(from_data, "from_data")
    patch = _as_bytes(patch_data, "patch_data")

    _validate_patch(patch)

    return kgdiff1.patch(old, patch)


def kg_patch_chain(from_data, patches) -> bytes:
    current = _as_bytes(from_data, "from_data")

    if patches is None:
        raise ValueError("patches must not be NULL")

    for index, patch_data in enumerate(patches):
        patch = _as_bytes(patch_data, f"patches[{index}]")
        _validate_patch(patch)
        current = kgdiff1.patch(current, patch)

    return current


def kg_info(patch_data) -> dict:
    patch = _as_bytes(patch_data, "patch_data")
    info = dict(kgdiff1.info(patch))

    magic = info.get("magic")
    if isinstance(magic, bytes):
        info["magic_hex"] = magic.hex()
        info["magic_ascii"] = magic.rstrip(b"\x00").decode("ascii", errors="replace")
        del info["magic"]

    return info


def selftest() -> bool:
    kgdiff1.selftest()

    old = b"hello world"
    new = b"hello brave new world"

    patch = kg_diff(old, new)
    assert kg_patch(old, patch) == new

    p1 = kg_diff(b"a", b"ab")
    p2 = kg_diff(b"ab", b"abc")
    assert kg_patch_chain(b"a", [p1, p2]) == b"abc"

    info = kg_info(patch)
    assert info["old_size"] == len(old)
    assert info["new_size"] == len(new)
    assert info["patch_size"] == len(patch)

    return True
