# kgdiff1.pyx
#
# Cython port of bsdiff/bspatch using the branded KGDIFF1\0 format.
#
# KGDIFF1 patch format, 48-byte header:
#   magic            8 bytes                          b"KGDIFF1\0"
#   old_size         u63be                            [(1 + 63) = 64]
#   new_size         u63be                            [(1 + 63) = 64]
#   control_section  codec u7be + payload_size u55be  [(1 + 7) + (1 + 55) = 64]
#   diff_section     codec u7be + payload_size u55be  [(1 + 7) + (1 + 55) = 64]
#   extra_section    codec u7be + payload_size u55be  [(1 + 7) + (1 + 55) = 64]
#
# Payload:
#   control_table payload:
#       decoded/raw form is repeated 24-byte records:
#           diff_len       8 bytes: u63be
#           extra_len      8 bytes: u63be
#           old_seek_delta 8 bytes: i63be signed magnitude
#
#   diff_table payload:
#       decoded/raw form is all diff blocks concatenated
#
#   extra_table payload:
#       decoded/raw form is all extra blocks concatenated
#
# Section codec:
#   0 = raw/uncompressed
#   1..9 = zlib compression level 1..9
#
# Notes:
#   - zlib compression/decompression intentionally uses Python's zlib module.
#   - No stdint cimport. Integer aliases are C base types.
#   - Assumes target platform has 8-bit unsigned char and 64-bit long long.
#   - validate_platform() additionally checks little-endian and two's complement.

from libc.stdlib cimport malloc, realloc, free

import zlib


ctypedef unsigned char u8
ctypedef unsigned long long u64
ctypedef long long i64
ctypedef int i32


cdef u64 OFF_SIGN_BIT = (<u64>1) << 63
cdef u64 OFF_VALUE_MAX = ((<u64>1) << 63) - 1

cdef u8 OFF_SIGN_BYTE = <u8>0x80
cdef u8 OFF_VALUE_BYTE = <u8>0x7F

cdef i64 OFF_I64_MIN = <i64>((<u64>1) << 63)
cdef i64 OFF_I64_MAX = <i64>(((<u64>1) << 63) - 1)

cdef int OFF_OK = 0
cdef int OFF_ERR_NULL = -1
cdef int OFF_ERR_RANGE = -2
cdef int OFF_ERR_NEG_ZERO = -3
cdef int OFF_ERR_SIGN_BIT = -4

cdef int KGDIFF_OK = 0
cdef int KGDIFF_ERR_NULL = -100
cdef int KGDIFF_ERR_RANGE = -101
cdef int KGDIFF_ERR_ALLOC = -102
cdef int KGDIFF_ERR_FORMAT = -103
cdef int KGDIFF_ERR_BOUNDS = -104
cdef int KGDIFF_ERR_PLATFORM = -105
cdef int KGDIFF_ERR_CODEC = -106

cdef u8 KGDIFF_HEADER_SIZE = 48
cdef u8 KGDIFF_CONTROL_SIZE = 24

cdef u8 KGDIFF_CODEC_RAW = <u8>0
cdef u8 KGDIFF_CODEC_ZLIB_MIN = <u8>1
cdef u8 KGDIFF_CODEC_ZLIB_MAX = <u8>9
cdef u8 KGDIFF_CODEC_ZLIB_DEFAULT = <u8>9

cdef u64 KGDIFF_SECTION_SIZE_MAX = ((<u64>1) << 55) - 1


cdef struct KGDiffHeader:
    u64 old_size
    u64 new_size
    u8 control_codec
    u8 control_size[7]
    u8 diff_codec
    u8 diff_size[7]
    u8 extra_codec
    u8 extra_size[7]


cdef int raw_memcmp(const u8* a, const u8* b, i64 n) noexcept:
    cdef i64 i

    for i in range(n):
        if a[i] < b[i]:
            return -1
        if a[i] > b[i]:
            return 1

    return 0


cdef i64 min_i64(i64 a, i64 b) noexcept:
    if a < b:
        return a
    return b


cdef int off_validate_platform_c() noexcept:
    cdef unsigned int endian_probe
    cdef u8* endian_bytes
    cdef i64 minus_one_i64
    cdef u64 minus_one_bits
    cdef u64 min_bits
    cdef i64 min_i64_value

    if sizeof(u8) != 1:
        return KGDIFF_ERR_PLATFORM
    if sizeof(u64) != 8:
        return KGDIFF_ERR_PLATFORM
    if sizeof(i64) != 8:
        return KGDIFF_ERR_PLATFORM

    endian_probe = 0x01020304
    endian_bytes = <u8*>(&endian_probe)

    if endian_bytes[0] != 0x04:
        return KGDIFF_ERR_PLATFORM
    if endian_bytes[1] != 0x03:
        return KGDIFF_ERR_PLATFORM
    if endian_bytes[2] != 0x02:
        return KGDIFF_ERR_PLATFORM
    if endian_bytes[3] != 0x01:
        return KGDIFF_ERR_PLATFORM

    minus_one_i64 = -1
    minus_one_bits = <u64>minus_one_i64

    if minus_one_bits != (((<u64>1) << 63) | (((<u64>1) << 63) - 1)):
        return KGDIFF_ERR_PLATFORM

    min_bits = (<u64>1) << 63
    min_i64_value = <i64>min_bits

    if min_i64_value != OFF_I64_MIN:
        return KGDIFF_ERR_PLATFORM

    return KGDIFF_OK


cdef int off_magtout(const u64* const in_value, u8* const out) noexcept:
    if in_value == NULL or out == NULL:
        return OFF_ERR_NULL

    if in_value[0] > OFF_VALUE_MAX:
        return OFF_ERR_RANGE

    out[0] = <u8>((in_value[0] >> 56) & OFF_VALUE_BYTE)
    out[1] = <u8>((in_value[0] >> 48) & 0xFF)
    out[2] = <u8>((in_value[0] >> 40) & 0xFF)
    out[3] = <u8>((in_value[0] >> 32) & 0xFF)
    out[4] = <u8>((in_value[0] >> 24) & 0xFF)
    out[5] = <u8>((in_value[0] >> 16) & 0xFF)
    out[6] = <u8>((in_value[0] >>  8) & 0xFF)
    out[7] = <u8>((in_value[0] >>  0) & 0xFF)

    return OFF_OK


cdef int off_magtin(const u8* const in_bytes, u64* const out_value) noexcept:
    if in_bytes == NULL or out_value == NULL:
        return OFF_ERR_NULL

    out_value[0] = (
        (<u64>(in_bytes[0] & OFF_VALUE_BYTE) << 56) |
        (<u64>(in_bytes[1])                  << 48) |
        (<u64>(in_bytes[2])                  << 40) |
        (<u64>(in_bytes[3])                  << 32) |
        (<u64>(in_bytes[4])                  << 24) |
        (<u64>(in_bytes[5])                  << 16) |
        (<u64>(in_bytes[6])                  <<  8) |
        (<u64>(in_bytes[7])                  <<  0)
    )

    return OFF_OK


cdef int uofftout(const u64* const in_value, u8* const out) noexcept:
    return off_magtout(in_value, out)


cdef int uofftin(const u8* const in_bytes, u64* const out_value) noexcept:
    cdef int retval

    if in_bytes == NULL or out_value == NULL:
        return OFF_ERR_NULL

    if (in_bytes[0] & OFF_SIGN_BYTE) != 0:
        return OFF_ERR_SIGN_BIT

    retval = off_magtin(in_bytes, out_value)
    if retval != OFF_OK:
        return retval

    return OFF_OK


cdef int offtout(const i64* const in_value, u8* const out) noexcept:
    cdef u64 magnitude
    cdef u8 sign_bit
    cdef int retval

    if in_value == NULL or out == NULL:
        return OFF_ERR_NULL

    if in_value[0] < 0:
        if in_value[0] == OFF_I64_MIN:
            return OFF_ERR_RANGE

        magnitude = <u64>(-(in_value[0]))
        sign_bit = OFF_SIGN_BYTE
    else:
        magnitude = <u64>in_value[0]
        sign_bit = <u8>0

    retval = off_magtout(&magnitude, out)
    if retval != OFF_OK:
        return retval

    out[0] = <u8>(out[0] | sign_bit)
    return OFF_OK


cdef int offtin(const u8* const in_bytes, i64* const out_value) noexcept:
    cdef u64 magnitude
    cdef int is_negative
    cdef int retval

    if in_bytes == NULL or out_value == NULL:
        return OFF_ERR_NULL

    is_negative = ((in_bytes[0] & OFF_SIGN_BYTE) != 0)

    retval = off_magtin(in_bytes, &magnitude)
    if retval != OFF_OK:
        return retval

    if is_negative:
        if magnitude == 0:
            return OFF_ERR_NEG_ZERO

        out_value[0] = -(<i64>magnitude)
    else:
        out_value[0] = <i64>magnitude

    return OFF_OK


cdef int kgdiff_write_magic(u8* out) noexcept:
    if out == NULL:
        return KGDIFF_ERR_NULL

    out[0] = <u8>ord('K')
    out[1] = <u8>ord('G')
    out[2] = <u8>ord('D')
    out[3] = <u8>ord('I')
    out[4] = <u8>ord('F')
    out[5] = <u8>ord('F')
    out[6] = <u8>ord('1')
    out[7] = <u8>0

    return KGDIFF_OK


cdef int kgdiff_check_magic(const u8* in_bytes) noexcept:
    if in_bytes == NULL:
        return KGDIFF_ERR_NULL

    if in_bytes[0] != <u8>ord('K'):
        return KGDIFF_ERR_FORMAT
    if in_bytes[1] != <u8>ord('G'):
        return KGDIFF_ERR_FORMAT
    if in_bytes[2] != <u8>ord('D'):
        return KGDIFF_ERR_FORMAT
    if in_bytes[3] != <u8>ord('I'):
        return KGDIFF_ERR_FORMAT
    if in_bytes[4] != <u8>ord('F'):
        return KGDIFF_ERR_FORMAT
    if in_bytes[5] != <u8>ord('F'):
        return KGDIFF_ERR_FORMAT
    if in_bytes[6] != <u8>ord('1'):
        return KGDIFF_ERR_FORMAT
    if in_bytes[7] != <u8>0:
        return KGDIFF_ERR_FORMAT

    return KGDIFF_OK

cdef int kgdiff_write_section_desc(u8 codec, u64 size, u8* codec_out, u8* size_out) noexcept:
    if codec_out == NULL or size_out == NULL:
        return KGDIFF_ERR_NULL

    if (codec & <u8>0x80) != 0:
        return KGDIFF_ERR_CODEC

    if size > KGDIFF_SECTION_SIZE_MAX:
        return KGDIFF_ERR_RANGE

    codec_out[0] = codec
    size_out[0] = <u8>((size >> 48) & 0x7F)
    size_out[1] = <u8>((size >> 40) & 0xFF)
    size_out[2] = <u8>((size >> 32) & 0xFF)
    size_out[3] = <u8>((size >> 24) & 0xFF)
    size_out[4] = <u8>((size >> 16) & 0xFF)
    size_out[5] = <u8>((size >>  8) & 0xFF)
    size_out[6] = <u8>((size >>  0) & 0xFF)

    return KGDIFF_OK


cdef int kgdiff_read_section_desc(u8 codec_in, const u8* size_in, u8* codec, u64* size) noexcept:
    if size_in == NULL or codec == NULL or size == NULL:
        return KGDIFF_ERR_NULL

    if (codec_in & <u8>0x80) != 0:
        return KGDIFF_ERR_CODEC

    if (size_in[0] & <u8>0x80) != 0:
        return KGDIFF_ERR_RANGE

    codec[0] = codec_in

    size[0] = (
        (<u64>(size_in[0] & 0x7F) << 48) |
        (<u64>(size_in[1])        << 40) |
        (<u64>(size_in[2])        << 32) |
        (<u64>(size_in[3])        << 24) |
        (<u64>(size_in[4])        << 16) |
        (<u64>(size_in[5])        <<  8) |
        (<u64>(size_in[6])        <<  0)
    )

    return KGDIFF_OK


cdef int kgdiff_header_set_section(u8 codec, u64 size, u8* codec_out, u8* size_out) noexcept:
    return kgdiff_write_section_desc(codec, size, codec_out, size_out)


cdef int kgdiff_header_get_section(u8 codec_in, const u8* size_in, u8* codec, u64* size) noexcept:
    return kgdiff_read_section_desc(codec_in, size_in, codec, size)


cdef int kgdiff_write_header_struct(u8* out, const KGDiffHeader* header) noexcept:
    cdef int retval
    cdef int i

    if out == NULL or header == NULL:
        return KGDIFF_ERR_NULL

    retval = kgdiff_write_magic(out)
    if retval != KGDIFF_OK:
        return retval

    retval = uofftout(&header.old_size, out + 8)
    if retval != OFF_OK:
        return KGDIFF_ERR_RANGE

    retval = uofftout(&header.new_size, out + 16)
    if retval != OFF_OK:
        return KGDIFF_ERR_RANGE

    out[24] = header.control_codec
    for i in range(7):
        out[25 + i] = header.control_size[i]

    out[32] = header.diff_codec
    for i in range(7):
        out[33 + i] = header.diff_size[i]

    out[40] = header.extra_codec
    for i in range(7):
        out[41 + i] = header.extra_size[i]

    return KGDIFF_OK


cdef int kgdiff_read_header_struct(const u8* in_bytes, KGDiffHeader* header) noexcept:
    cdef int retval
    cdef int i

    if in_bytes == NULL or header == NULL:
        return KGDIFF_ERR_NULL

    retval = kgdiff_check_magic(in_bytes)
    if retval != KGDIFF_OK:
        return retval

    retval = uofftin(in_bytes + 8, &header.old_size)
    if retval != OFF_OK:
        return KGDIFF_ERR_FORMAT

    retval = uofftin(in_bytes + 16, &header.new_size)
    if retval != OFF_OK:
        return KGDIFF_ERR_FORMAT

    if (in_bytes[24] & <u8>0x80) != 0:
        return KGDIFF_ERR_CODEC
    if (in_bytes[25] & <u8>0x80) != 0:
        return KGDIFF_ERR_RANGE

    header.control_codec = in_bytes[24]
    for i in range(7):
        header.control_size[i] = in_bytes[25 + i]

    if (in_bytes[32] & <u8>0x80) != 0:
        return KGDIFF_ERR_CODEC
    if (in_bytes[33] & <u8>0x80) != 0:
        return KGDIFF_ERR_RANGE

    header.diff_codec = in_bytes[32]
    for i in range(7):
        header.diff_size[i] = in_bytes[33 + i]

    if (in_bytes[40] & <u8>0x80) != 0:
        return KGDIFF_ERR_CODEC
    if (in_bytes[41] & <u8>0x80) != 0:
        return KGDIFF_ERR_RANGE

    header.extra_codec = in_bytes[40]
    for i in range(7):
        header.extra_size[i] = in_bytes[41 + i]

    return KGDIFF_OK


cdef int kgdiff_make_header_struct(KGDiffHeader* header,
                                   u64 old_size,
                                   u64 new_size,
                                   u8 control_codec,
                                   u64 control_payload_size,
                                   u8 diff_codec,
                                   u64 diff_payload_size,
                                   u8 extra_codec,
                                   u64 extra_payload_size) noexcept:
    cdef int retval

    if header == NULL:
        return KGDIFF_ERR_NULL

    header.old_size = old_size
    header.new_size = new_size

    retval = kgdiff_header_set_section(control_codec, control_payload_size, &header.control_codec, header.control_size)
    if retval != KGDIFF_OK:
        return retval

    retval = kgdiff_header_set_section(diff_codec, diff_payload_size, &header.diff_codec, header.diff_size)
    if retval != KGDIFF_OK:
        return retval

    retval = kgdiff_header_set_section(extra_codec, extra_payload_size, &header.extra_codec, header.extra_size)
    if retval != KGDIFF_OK:
        return retval

    return KGDIFF_OK


cdef int kgdiff_header_get_sizes(const KGDiffHeader* header,
                                 u8* control_codec,
                                 u64* control_size,
                                 u8* diff_codec,
                                 u64* diff_size,
                                 u8* extra_codec,
                                 u64* extra_size) noexcept:
    cdef int retval

    if (
        header == NULL or
        control_codec == NULL or
        control_size == NULL or
        diff_codec == NULL or
        diff_size == NULL or
        extra_codec == NULL or
        extra_size == NULL
    ):
        return KGDIFF_ERR_NULL

    retval = kgdiff_header_get_section(header.control_codec, header.control_size, control_codec, control_size)
    if retval != KGDIFF_OK:
        return retval

    retval = kgdiff_header_get_section(header.diff_codec, header.diff_size, diff_codec, diff_size)
    if retval != KGDIFF_OK:
        return retval

    retval = kgdiff_header_get_section(header.extra_codec, header.extra_size, extra_codec, extra_size)
    if retval != KGDIFF_OK:
        return retval

    return KGDIFF_OK


cdef int kgdiff_write_control(u8* out, u64 diff_len, u64 extra_len, i64 old_seek_delta) noexcept:
    cdef int retval

    if out == NULL:
        return KGDIFF_ERR_NULL

    retval = uofftout(&diff_len, out + 0)
    if retval != OFF_OK:
        return KGDIFF_ERR_RANGE

    retval = uofftout(&extra_len, out + 8)
    if retval != OFF_OK:
        return KGDIFF_ERR_RANGE

    retval = offtout(&old_seek_delta, out + 16)
    if retval != OFF_OK:
        return KGDIFF_ERR_RANGE

    return KGDIFF_OK


cdef int kgdiff_read_control(const u8* in_bytes, u64* diff_len, u64* extra_len, i64* old_seek_delta) noexcept:
    cdef int retval

    if in_bytes == NULL or diff_len == NULL or extra_len == NULL or old_seek_delta == NULL:
        return KGDIFF_ERR_NULL

    retval = uofftin(in_bytes + 0, diff_len)
    if retval != OFF_OK:
        return KGDIFF_ERR_FORMAT

    retval = uofftin(in_bytes + 8, extra_len)
    if retval != OFF_OK:
        return KGDIFF_ERR_FORMAT

    retval = offtin(in_bytes + 16, old_seek_delta)
    if retval != OFF_OK:
        return KGDIFF_ERR_FORMAT

    return KGDIFF_OK


cdef struct PatchWriter:
    u8* data
    u64 size
    u64 capacity


cdef int writer_init(PatchWriter* writer, u64 initial_capacity) noexcept:
    if writer == NULL:
        return KGDIFF_ERR_NULL

    writer.data = NULL
    writer.size = 0
    writer.capacity = 0

    if initial_capacity == 0:
        initial_capacity = 1

    writer.data = <u8*>malloc(initial_capacity)
    if writer.data == NULL:
        return KGDIFF_ERR_ALLOC

    writer.capacity = initial_capacity
    return KGDIFF_OK


cdef void writer_destroy(PatchWriter* writer) noexcept:
    if writer != NULL:
        if writer.data != NULL:
            free(writer.data)

        writer.data = NULL
        writer.size = 0
        writer.capacity = 0


cdef int writer_reserve(PatchWriter* writer, u64 extra) noexcept:
    cdef u64 required
    cdef u64 new_capacity
    cdef void* new_data

    if writer == NULL:
        return KGDIFF_ERR_NULL

    if extra > OFF_VALUE_MAX - writer.size:
        return KGDIFF_ERR_RANGE

    required = writer.size + extra

    if required <= writer.capacity:
        return KGDIFF_OK

    new_capacity = writer.capacity

    if new_capacity == 0:
        new_capacity = 1

    while new_capacity < required:
        if new_capacity > OFF_VALUE_MAX // 2:
            new_capacity = required
            break

        new_capacity *= 2

    new_data = realloc(writer.data, new_capacity)
    if new_data == NULL:
        return KGDIFF_ERR_ALLOC

    writer.data = <u8*>new_data
    writer.capacity = new_capacity

    return KGDIFF_OK


cdef int writer_write(PatchWriter* writer, const u8* data, u64 length) noexcept:
    cdef u64 i
    cdef int retval

    if writer == NULL:
        return KGDIFF_ERR_NULL

    if length != 0 and data == NULL:
        return KGDIFF_ERR_NULL

    retval = writer_reserve(writer, length)
    if retval != KGDIFF_OK:
        return retval

    for i in range(length):
        writer.data[writer.size + i] = data[i]

    writer.size += length

    return KGDIFF_OK


cdef bytes writer_to_bytes(PatchWriter* writer):
    if writer == NULL or writer.data == NULL:
        return b""

    return (<char*>writer.data)[:writer.size]


cdef void split(i64* I, i64* V, i64 start, i64 length, i64 h) noexcept:
    cdef i64 i, j, k, x, tmp, jj, kk

    if length < 16:
        k = start

        while k < start + length:
            j = 1
            x = V[I[k] + h]
            i = 1

            while k + i < start + length:
                if V[I[k + i] + h] < x:
                    x = V[I[k + i] + h]
                    j = 0

                if V[I[k + i] + h] == x:
                    tmp = I[k + j]
                    I[k + j] = I[k + i]
                    I[k + i] = tmp
                    j += 1

                i += 1

            for i in range(j):
                V[I[k + i]] = k + j - 1

            if j == 1:
                I[k] = -1

            k += j

        return

    x = V[I[start + length // 2] + h]
    jj = 0
    kk = 0

    for i in range(start, start + length):
        if V[I[i] + h] < x:
            jj += 1

        if V[I[i] + h] == x:
            kk += 1

    jj += start
    kk += jj

    i = start
    j = 0
    k = 0

    while i < jj:
        if V[I[i] + h] < x:
            i += 1
        elif V[I[i] + h] == x:
            tmp = I[i]
            I[i] = I[jj + j]
            I[jj + j] = tmp
            j += 1
        else:
            tmp = I[i]
            I[i] = I[kk + k]
            I[kk + k] = tmp
            k += 1

    while jj + j < kk:
        if V[I[jj + j] + h] == x:
            j += 1
        else:
            tmp = I[jj + j]
            I[jj + j] = I[kk + k]
            I[kk + k] = tmp
            k += 1

    if jj > start:
        split(I, V, start, jj - start, h)

    for i in range(kk - jj):
        V[I[jj + i]] = kk - 1

    if jj == kk - 1:
        I[jj] = -1

    if start + length > kk:
        split(I, V, kk, start + length - kk, h)


cdef void qsufsort(i64* I, i64* V, const u8* old_data, i64 old_size) noexcept:
    cdef i64 buckets[256]
    cdef i64 i, h, length

    for i in range(256):
        buckets[i] = 0

    for i in range(old_size):
        buckets[old_data[i]] += 1

    for i in range(1, 256):
        buckets[i] += buckets[i - 1]

    for i in range(255, 0, -1):
        buckets[i] = buckets[i - 1]

    buckets[0] = 0

    for i in range(old_size):
        buckets[old_data[i]] += 1
        I[buckets[old_data[i]]] = i

    I[0] = old_size

    for i in range(old_size):
        V[i] = buckets[old_data[i]]

    V[old_size] = 0

    for i in range(1, 256):
        if buckets[i] == buckets[i - 1] + 1:
            I[buckets[i]] = -1

    I[0] = -1

    h = 1

    while I[0] != -(old_size + 1):
        length = 0
        i = 0

        while i < old_size + 1:
            if I[i] < 0:
                length -= I[i]
                i -= I[i]
            else:
                if length != 0:
                    I[i - length] = -length

                length = V[I[i]] + 1 - i
                split(I, V, i, length, h)
                i += length
                length = 0

        if length != 0:
            I[i - length] = -length

        h += h

    for i in range(old_size + 1):
        I[V[i]] = i


cdef i64 matchlen(const u8* old_data, i64 old_size, const u8* new_data, i64 new_size) noexcept:
    cdef i64 i

    i = 0

    while i < old_size and i < new_size:
        if old_data[i] != new_data[i]:
            break

        i += 1

    return i


cdef i64 search(const i64* I,
                const u8* old_data,
                i64 old_size,
                const u8* new_data,
                i64 new_size,
                i64 st,
                i64 en,
                i64* pos) noexcept:
    cdef i64 x, y
    cdef i64 cmp_len

    if en - st < 2:
        x = matchlen(old_data + I[st], old_size - I[st], new_data, new_size)
        y = matchlen(old_data + I[en], old_size - I[en], new_data, new_size)

        if x > y:
            pos[0] = I[st]
            return x

        pos[0] = I[en]
        return y

    x = st + (en - st) // 2
    cmp_len = min_i64(old_size - I[x], new_size)

    if raw_memcmp(old_data + I[x], new_data, cmp_len) < 0:
        return search(I, old_data, old_size, new_data, new_size, x, en, pos)

    return search(I, old_data, old_size, new_data, new_size, st, x, pos)


cdef int bsdiff_internal(const u8* old_data,
                         i64 old_size,
                         const u8* new_data,
                         i64 new_size,
                         i64* I,
                         u8* buffer,
                         PatchWriter* control_writer,
                         PatchWriter* diff_writer,
                         PatchWriter* extra_writer) noexcept:
    cdef i64* V
    cdef i64 scan, pos, length
    cdef i64 lastscan, lastpos, lastoffset
    cdef i64 oldscore, scsc
    cdef i64 s, Sf, lenf, Sb, lenb
    cdef i64 overlap, Ss, lens
    cdef i64 i
    cdef i64 old_index
    cdef u8 ctrl[24]
    cdef u64 diff_len_u
    cdef u64 extra_len_u
    cdef i64 extra_len_i
    cdef i64 old_seek_delta
    cdef int retval
    cdef i64 KGDIFF_CONTROL_SIZE_LOCAL = 24
    cdef i64 KGDIFF_MIN_REUSE_MATCH = 24

    if control_writer == NULL or diff_writer == NULL or extra_writer == NULL:
        return KGDIFF_ERR_NULL

    V = <i64*>malloc((<u64>old_size + 1) * sizeof(i64))
    if V == NULL:
        return KGDIFF_ERR_ALLOC

    qsufsort(I, V, old_data, old_size)
    free(V)
    V = NULL

    scan = 0
    length = 0
    pos = 0
    lastscan = 0
    lastpos = 0
    lastoffset = 0

    while scan < new_size:
        oldscore = 0
        scan += length
        scsc = scan

        while scan < new_size:
            length = search(
                I,
                old_data,
                old_size,
                new_data + scan,
                new_size - scan,
                0,
                old_size,
                &pos
            )

            while scsc < scan + length:
                old_index = scsc + lastoffset

                if (
                    (old_index >= 0) and
                    (old_index < old_size) and
                    (old_data[old_index] == new_data[scsc])
                ):
                    oldscore += 1

                scsc += 1

            if length > oldscore + KGDIFF_CONTROL_SIZE_LOCAL:
                break

            if (length >= KGDIFF_MIN_REUSE_MATCH) and (length > oldscore):
                break

            old_index = scan + lastoffset

            if (
                (old_index >= 0) and
                (old_index < old_size) and
                (old_data[old_index] == new_data[scan])
            ):
                oldscore -= 1

            scan += 1

        if (length != oldscore) or (scan == new_size):
            s = 0
            Sf = 0
            lenf = 0
            i = 0

            while (lastscan + i < scan) and (lastpos + i < old_size):
                if old_data[lastpos + i] == new_data[lastscan + i]:
                    s += 1

                i += 1

                if s * 2 - i > Sf * 2 - lenf:
                    Sf = s
                    lenf = i

            lenb = 0

            if scan < new_size:
                s = 0
                Sb = 0
                i = 1

                while (scan >= lastscan + i) and (pos >= i):
                    if old_data[pos - i] == new_data[scan - i]:
                        s += 1

                    if s * 2 - i > Sb * 2 - lenb:
                        Sb = s
                        lenb = i

                    i += 1

            if lastscan + lenf > scan - lenb:
                overlap = (lastscan + lenf) - (scan - lenb)
                s = 0
                Ss = 0
                lens = 0

                for i in range(overlap):
                    if new_data[lastscan + lenf - overlap + i] == old_data[lastpos + lenf - overlap + i]:
                        s += 1

                    if new_data[scan - lenb + i] == old_data[pos - lenb + i]:
                        s -= 1

                    if s > Ss:
                        Ss = s
                        lens = i + 1

                lenf += lens - overlap
                lenb -= lens

            diff_len_u = <u64>lenf
            extra_len_i = (scan - lenb) - (lastscan + lenf)

            if extra_len_i < 0:
                return KGDIFF_ERR_RANGE

            extra_len_u = <u64>extra_len_i
            old_seek_delta = (pos - lenb) - (lastpos + lenf)

            retval = kgdiff_write_control(ctrl, diff_len_u, extra_len_u, old_seek_delta)
            if retval != KGDIFF_OK:
                return retval

            retval = writer_write(control_writer, ctrl, KGDIFF_CONTROL_SIZE)
            if retval != KGDIFF_OK:
                return retval

            for i in range(lenf):
                buffer[i] = <u8>(new_data[lastscan + i] - old_data[lastpos + i])

            retval = writer_write(diff_writer, buffer, <u64>lenf)
            if retval != KGDIFF_OK:
                return retval

            for i in range(extra_len_i):
                buffer[i] = new_data[lastscan + lenf + i]

            retval = writer_write(extra_writer, buffer, <u64>extra_len_i)
            if retval != KGDIFF_OK:
                return retval

            lastscan = scan - lenb
            lastpos = pos - lenb
            lastoffset = pos - scan

    return KGDIFF_OK


cdef int kgdiff_raw_c(const u8* old_data,
                      u64 old_size_u,
                      const u8* new_data,
                      u64 new_size_u,
                      PatchWriter* writer) noexcept:
    cdef i64 old_size
    cdef i64 new_size
    cdef i64* I
    cdef u8* buffer
    cdef u8 header_bytes[48]
    cdef KGDiffHeader header
    cdef int retval
    cdef u64 total_size
    cdef PatchWriter control_writer
    cdef PatchWriter diff_writer
    cdef PatchWriter extra_writer

    if writer == NULL:
        return KGDIFF_ERR_NULL

    if old_size_u > OFF_VALUE_MAX or new_size_u > OFF_VALUE_MAX:
        return KGDIFF_ERR_RANGE

    old_size = <i64>old_size_u
    new_size = <i64>new_size_u

    I = NULL
    buffer = NULL

    control_writer.data = NULL
    control_writer.size = 0
    control_writer.capacity = 0
    diff_writer.data = NULL
    diff_writer.size = 0
    diff_writer.capacity = 0
    extra_writer.data = NULL
    extra_writer.size = 0
    extra_writer.capacity = 0

    I = <i64*>malloc((old_size_u + 1) * sizeof(i64))
    if I == NULL:
        return KGDIFF_ERR_ALLOC

    buffer = <u8*>malloc(new_size_u + 1)
    if buffer == NULL:
        free(I)
        return KGDIFF_ERR_ALLOC

    retval = writer_init(&control_writer, 1024)
    if retval != KGDIFF_OK:
        free(buffer)
        free(I)
        return retval

    retval = writer_init(&diff_writer, new_size_u + 1)
    if retval != KGDIFF_OK:
        writer_destroy(&control_writer)
        free(buffer)
        free(I)
        return retval

    retval = writer_init(&extra_writer, 1024)
    if retval != KGDIFF_OK:
        writer_destroy(&diff_writer)
        writer_destroy(&control_writer)
        free(buffer)
        free(I)
        return retval

    retval = bsdiff_internal(
        old_data,
        old_size,
        new_data,
        new_size,
        I,
        buffer,
        &control_writer,
        &diff_writer,
        &extra_writer
    )
    if retval != KGDIFF_OK:
        writer_destroy(&extra_writer)
        writer_destroy(&diff_writer)
        writer_destroy(&control_writer)
        free(buffer)
        free(I)
        return retval

    retval = kgdiff_make_header_struct(
        &header,
        old_size_u,
        new_size_u,
        KGDIFF_CODEC_RAW,
        control_writer.size,
        KGDIFF_CODEC_RAW,
        diff_writer.size,
        KGDIFF_CODEC_RAW,
        extra_writer.size
    )
    if retval != KGDIFF_OK:
        writer_destroy(&extra_writer)
        writer_destroy(&diff_writer)
        writer_destroy(&control_writer)
        free(buffer)
        free(I)
        return retval

    retval = kgdiff_write_header_struct(header_bytes, &header)
    if retval != KGDIFF_OK:
        writer_destroy(&extra_writer)
        writer_destroy(&diff_writer)
        writer_destroy(&control_writer)
        free(buffer)
        free(I)
        return retval

    if control_writer.size > OFF_VALUE_MAX - KGDIFF_HEADER_SIZE:
        retval = KGDIFF_ERR_RANGE
    elif diff_writer.size > OFF_VALUE_MAX - KGDIFF_HEADER_SIZE - control_writer.size:
        retval = KGDIFF_ERR_RANGE
    elif extra_writer.size > OFF_VALUE_MAX - KGDIFF_HEADER_SIZE - control_writer.size - diff_writer.size:
        retval = KGDIFF_ERR_RANGE
    else:
        total_size = KGDIFF_HEADER_SIZE + control_writer.size + diff_writer.size + extra_writer.size
        retval = writer_init(writer, total_size)

    if retval != KGDIFF_OK:
        writer_destroy(&extra_writer)
        writer_destroy(&diff_writer)
        writer_destroy(&control_writer)
        free(buffer)
        free(I)
        return retval

    retval = writer_write(writer, header_bytes, KGDIFF_HEADER_SIZE)
    if retval == KGDIFF_OK:
        retval = writer_write(writer, control_writer.data, control_writer.size)
    if retval == KGDIFF_OK:
        retval = writer_write(writer, diff_writer.data, diff_writer.size)
    if retval == KGDIFF_OK:
        retval = writer_write(writer, extra_writer.data, extra_writer.size)

    writer_destroy(&extra_writer)
    writer_destroy(&diff_writer)
    writer_destroy(&control_writer)
    free(buffer)
    free(I)

    return retval


cdef int kgdiff_patch_raw_c(const u8* old_data,
                            u64 old_size_actual,
                            const u8* patch_data,
                            u64 patch_size,
                            u8** new_out,
                            u64* new_size_out) noexcept:
    cdef KGDiffHeader header
    cdef u8 control_codec
    cdef u8 diff_codec
    cdef u8 extra_codec
    cdef u64 control_table_size
    cdef u64 diff_data_size
    cdef u64 extra_data_size
    cdef u64 control_pos
    cdef u64 control_end
    cdef u64 diff_pos
    cdef u64 diff_end
    cdef u64 extra_pos
    cdef u64 extra_end
    cdef u64 new_pos
    cdef u64 diff_len = 0
    cdef u64 extra_len = 0
    cdef i64 old_seek_delta = 0
    cdef i64 old_pos
    cdef i64 old_index
    cdef u64 i
    cdef u8* new_data
    cdef int retval

    if patch_data == NULL or new_out == NULL or new_size_out == NULL:
        return KGDIFF_ERR_NULL

    if patch_size < KGDIFF_HEADER_SIZE:
        return KGDIFF_ERR_FORMAT

    retval = kgdiff_read_header_struct(patch_data, &header)
    if retval != KGDIFF_OK:
        return retval

    retval = kgdiff_header_get_sizes(
        &header,
        &control_codec,
        &control_table_size,
        &diff_codec,
        &diff_data_size,
        &extra_codec,
        &extra_data_size
    )
    if retval != KGDIFF_OK:
        return retval

    if control_codec != KGDIFF_CODEC_RAW:
        return KGDIFF_ERR_CODEC
    if diff_codec != KGDIFF_CODEC_RAW:
        return KGDIFF_ERR_CODEC
    if extra_codec != KGDIFF_CODEC_RAW:
        return KGDIFF_ERR_CODEC

    if header.old_size != old_size_actual:
        return KGDIFF_ERR_FORMAT

    if control_table_size % KGDIFF_CONTROL_SIZE != 0:
        return KGDIFF_ERR_FORMAT

    if control_table_size > patch_size - KGDIFF_HEADER_SIZE:
        return KGDIFF_ERR_FORMAT

    control_pos = KGDIFF_HEADER_SIZE
    control_end = control_pos + control_table_size

    if diff_data_size > patch_size - control_end:
        return KGDIFF_ERR_FORMAT

    diff_pos = control_end
    diff_end = diff_pos + diff_data_size

    if extra_data_size > patch_size - diff_end:
        return KGDIFF_ERR_FORMAT

    extra_pos = diff_end
    extra_end = extra_pos + extra_data_size

    if extra_end != patch_size:
        return KGDIFF_ERR_FORMAT

    if header.new_size == OFF_VALUE_MAX:
        return KGDIFF_ERR_RANGE

    new_data = <u8*>malloc(header.new_size + 1)
    if new_data == NULL:
        return KGDIFF_ERR_ALLOC

    old_pos = 0
    new_pos = 0

    while control_pos < control_end:
        retval = kgdiff_read_control(patch_data + control_pos, &diff_len, &extra_len, &old_seek_delta)
        if retval != KGDIFF_OK:
            free(new_data)
            return retval

        control_pos += KGDIFF_CONTROL_SIZE

        if diff_len > header.new_size - new_pos:
            free(new_data)
            return KGDIFF_ERR_BOUNDS

        if diff_len > diff_end - diff_pos:
            free(new_data)
            return KGDIFF_ERR_FORMAT

        for i in range(diff_len):
            new_data[new_pos + i] = patch_data[diff_pos + i]

        diff_pos += diff_len

        for i in range(diff_len):
            old_index = old_pos + <i64>i

            if old_index >= 0 and (<u64>old_index) < old_size_actual:
                new_data[new_pos + i] = <u8>(new_data[new_pos + i] + old_data[old_index])

        new_pos += diff_len
        old_pos += <i64>diff_len

        if extra_len > header.new_size - new_pos:
            free(new_data)
            return KGDIFF_ERR_BOUNDS

        if extra_len > extra_end - extra_pos:
            free(new_data)
            return KGDIFF_ERR_FORMAT

        for i in range(extra_len):
            new_data[new_pos + i] = patch_data[extra_pos + i]

        extra_pos += extra_len
        new_pos += extra_len
        old_pos += old_seek_delta

    if new_pos != header.new_size:
        free(new_data)
        return KGDIFF_ERR_FORMAT

    if diff_pos != diff_end:
        free(new_data)
        return KGDIFF_ERR_FORMAT

    if extra_pos != extra_end:
        free(new_data)
        return KGDIFF_ERR_FORMAT

    new_out[0] = new_data
    new_size_out[0] = header.new_size

    return KGDIFF_OK


cdef str error_name(int code):
    if code == KGDIFF_OK:
        return "KGDIFF_OK"
    if code == KGDIFF_ERR_NULL:
        return "KGDIFF_ERR_NULL"
    if code == KGDIFF_ERR_RANGE:
        return "KGDIFF_ERR_RANGE"
    if code == KGDIFF_ERR_ALLOC:
        return "KGDIFF_ERR_ALLOC"
    if code == KGDIFF_ERR_FORMAT:
        return "KGDIFF_ERR_FORMAT"
    if code == KGDIFF_ERR_BOUNDS:
        return "KGDIFF_ERR_BOUNDS"
    if code == KGDIFF_ERR_PLATFORM:
        return "KGDIFF_ERR_PLATFORM"
    if code == KGDIFF_ERR_CODEC:
        return "KGDIFF_ERR_CODEC"
    if code == OFF_ERR_NULL:
        return "OFF_ERR_NULL"
    if code == OFF_ERR_RANGE:
        return "OFF_ERR_RANGE"
    if code == OFF_ERR_NEG_ZERO:
        return "OFF_ERR_NEG_ZERO"
    if code == OFF_ERR_SIGN_BIT:
        return "OFF_ERR_SIGN_BIT"

    return "KGDIFF_ERR_UNKNOWN"


cdef void raise_error(int code):
    if code == KGDIFF_OK or code == OFF_OK:
        return

    raise ValueError(error_name(code))


cdef bytes _kgdiff_raw_from_bytes(bytes old_data, bytes new_data):
    cdef const u8[:] old_view = old_data
    cdef const u8[:] new_view = new_data
    cdef const u8* old_ptr
    cdef const u8* new_ptr
    cdef u8 dummy_old = 0
    cdef u8 dummy_new = 0
    cdef u64 old_size = <u64>len(old_data)
    cdef u64 new_size = <u64>len(new_data)
    cdef PatchWriter writer
    cdef int retval
    cdef bytes result

    if old_size > 0:
        old_ptr = &old_view[0]
    else:
        old_ptr = &dummy_old

    if new_size > 0:
        new_ptr = &new_view[0]
    else:
        new_ptr = &dummy_new

    writer.data = NULL
    writer.size = 0
    writer.capacity = 0

    retval = kgdiff_raw_c(old_ptr, old_size, new_ptr, new_size, &writer)
    if retval != KGDIFF_OK:
        writer_destroy(&writer)
        raise_error(retval)

    result = writer_to_bytes(&writer)
    writer_destroy(&writer)

    return result


cdef bytes _kgpatch_raw_from_bytes(bytes old_data, bytes patch_data):
    cdef const u8[:] old_view = old_data
    cdef const u8[:] patch_view = patch_data
    cdef const u8* old_ptr
    cdef const u8* patch_ptr
    cdef u8 dummy_old = 0
    cdef u8 dummy_patch = 0
    cdef u64 old_size = <u64>len(old_data)
    cdef u64 patch_size = <u64>len(patch_data)
    cdef u8* new_ptr = NULL
    cdef u64 new_size = 0
    cdef int retval
    cdef bytes result

    if old_size > 0:
        old_ptr = &old_view[0]
    else:
        old_ptr = &dummy_old

    if patch_size > 0:
        patch_ptr = &patch_view[0]
    else:
        patch_ptr = &dummy_patch

    retval = kgdiff_patch_raw_c(old_ptr, old_size, patch_ptr, patch_size, &new_ptr, &new_size)

    if retval != KGDIFF_OK:
        if new_ptr != NULL:
            free(new_ptr)

        raise_error(retval)

    result = (<char*>new_ptr)[:new_size]
    free(new_ptr)

    return result


cdef object _compress_section_py(bytes raw_section):
    cdef bytes compressed

    compressed = zlib.compress(raw_section, KGDIFF_CODEC_ZLIB_DEFAULT)

    if len(compressed) < len(raw_section):
        return KGDIFF_CODEC_ZLIB_DEFAULT, compressed

    return KGDIFF_CODEC_RAW, raw_section


cdef bytes _decompress_section_py(u8 codec, bytes payload):
    if codec == KGDIFF_CODEC_RAW:
        return payload

    if codec >= KGDIFF_CODEC_ZLIB_MIN and codec <= KGDIFF_CODEC_ZLIB_MAX:
        return zlib.decompress(payload)

    raise ValueError(error_name(KGDIFF_ERR_CODEC))


cdef bytes _kgdiff_pack_sections_py(bytes raw_patch):
    cdef const u8[:] raw_view = raw_patch
    cdef const u8* raw_ptr
    cdef KGDiffHeader raw_header
    cdef u8 control_codec_raw
    cdef u8 diff_codec_raw
    cdef u8 extra_codec_raw
    cdef u64 control_size
    cdef u64 diff_size
    cdef u64 extra_size
    cdef u64 control_offset
    cdef u64 diff_offset
    cdef u64 extra_offset
    cdef u64 end_offset
    cdef int retval
    cdef KGDiffHeader packed_header
    cdef u8 packed_header_bytes[48]
    cdef bytes control_raw
    cdef bytes diff_raw
    cdef bytes extra_raw
    cdef object packed
    cdef u8 control_codec
    cdef u8 diff_codec
    cdef u8 extra_codec
    cdef bytes control_payload
    cdef bytes diff_payload
    cdef bytes extra_payload

    if len(raw_patch) < KGDIFF_HEADER_SIZE:
        raise_error(KGDIFF_ERR_FORMAT)

    raw_ptr = &raw_view[0]

    retval = kgdiff_read_header_struct(raw_ptr, &raw_header)
    if retval != KGDIFF_OK:
        raise_error(retval)

    retval = kgdiff_header_get_sizes(
        &raw_header,
        &control_codec_raw,
        &control_size,
        &diff_codec_raw,
        &diff_size,
        &extra_codec_raw,
        &extra_size
    )
    if retval != KGDIFF_OK:
        raise_error(retval)

    if control_codec_raw != KGDIFF_CODEC_RAW:
        raise_error(KGDIFF_ERR_CODEC)
    if diff_codec_raw != KGDIFF_CODEC_RAW:
        raise_error(KGDIFF_ERR_CODEC)
    if extra_codec_raw != KGDIFF_CODEC_RAW:
        raise_error(KGDIFF_ERR_CODEC)

    control_offset = KGDIFF_HEADER_SIZE
    diff_offset = control_offset + control_size
    extra_offset = diff_offset + diff_size
    end_offset = extra_offset + extra_size

    if end_offset != <u64>len(raw_patch):
        raise_error(KGDIFF_ERR_FORMAT)

    control_raw = raw_patch[control_offset:diff_offset]
    diff_raw = raw_patch[diff_offset:extra_offset]
    extra_raw = raw_patch[extra_offset:end_offset]

    packed = _compress_section_py(control_raw)
    control_codec = <u8>packed[0]
    control_payload = packed[1]

    packed = _compress_section_py(diff_raw)
    diff_codec = <u8>packed[0]
    diff_payload = packed[1]

    packed = _compress_section_py(extra_raw)
    extra_codec = <u8>packed[0]
    extra_payload = packed[1]

    retval = kgdiff_make_header_struct(
        &packed_header,
        raw_header.old_size,
        raw_header.new_size,
        control_codec,
        <u64>len(control_payload),
        diff_codec,
        <u64>len(diff_payload),
        extra_codec,
        <u64>len(extra_payload)
    )
    if retval != KGDIFF_OK:
        raise_error(retval)

    retval = kgdiff_write_header_struct(packed_header_bytes, &packed_header)
    if retval != KGDIFF_OK:
        raise_error(retval)

    return (<char*>packed_header_bytes)[:KGDIFF_HEADER_SIZE] + control_payload + diff_payload + extra_payload


cdef bytes _kgdiff_unpack_to_raw_py(bytes patch_data):
    cdef const u8[:] patch_view = patch_data
    cdef const u8* patch_ptr
    cdef KGDiffHeader header
    cdef KGDiffHeader raw_header
    cdef u8 control_codec
    cdef u8 diff_codec
    cdef u8 extra_codec
    cdef u64 control_payload_size
    cdef u64 diff_payload_size
    cdef u64 extra_payload_size
    cdef u64 control_offset
    cdef u64 diff_offset
    cdef u64 extra_offset
    cdef u64 end_offset
    cdef int retval
    cdef bytes control_payload
    cdef bytes diff_payload
    cdef bytes extra_payload
    cdef bytes control_raw
    cdef bytes diff_raw
    cdef bytes extra_raw
    cdef u8 raw_header_bytes[48]

    if len(patch_data) < KGDIFF_HEADER_SIZE:
        raise_error(KGDIFF_ERR_FORMAT)

    patch_ptr = &patch_view[0]

    retval = kgdiff_read_header_struct(patch_ptr, &header)
    if retval != KGDIFF_OK:
        raise_error(retval)

    retval = kgdiff_header_get_sizes(
        &header,
        &control_codec,
        &control_payload_size,
        &diff_codec,
        &diff_payload_size,
        &extra_codec,
        &extra_payload_size
    )
    if retval != KGDIFF_OK:
        raise_error(retval)

    control_offset = KGDIFF_HEADER_SIZE
    diff_offset = control_offset + control_payload_size
    extra_offset = diff_offset + diff_payload_size
    end_offset = extra_offset + extra_payload_size

    if end_offset != <u64>len(patch_data):
        raise_error(KGDIFF_ERR_FORMAT)

    control_payload = patch_data[control_offset:diff_offset]
    diff_payload = patch_data[diff_offset:extra_offset]
    extra_payload = patch_data[extra_offset:end_offset]

    control_raw = _decompress_section_py(control_codec, control_payload)
    diff_raw = _decompress_section_py(diff_codec, diff_payload)
    extra_raw = _decompress_section_py(extra_codec, extra_payload)

    if len(control_raw) % KGDIFF_CONTROL_SIZE != 0:
        raise_error(KGDIFF_ERR_FORMAT)

    retval = kgdiff_make_header_struct(
        &raw_header,
        header.old_size,
        header.new_size,
        KGDIFF_CODEC_RAW,
        <u64>len(control_raw),
        KGDIFF_CODEC_RAW,
        <u64>len(diff_raw),
        KGDIFF_CODEC_RAW,
        <u64>len(extra_raw)
    )
    if retval != KGDIFF_OK:
        raise_error(retval)

    retval = kgdiff_write_header_struct(raw_header_bytes, &raw_header)
    if retval != KGDIFF_OK:
        raise_error(retval)

    return (<char*>raw_header_bytes)[:KGDIFF_HEADER_SIZE] + control_raw + diff_raw + extra_raw


def validate_platform():
    cdef int retval = off_validate_platform_c()

    if retval != KGDIFF_OK:
        raise RuntimeError("unsupported platform")

    return True


def diff_raw(bytes old_data, bytes new_data):
    return _kgdiff_raw_from_bytes(old_data, new_data)

def pack(bytes raw_patch):
    return _kgdiff_pack_sections_py(raw_patch)

def diff(bytes old_data, bytes new_data):
    cdef bytes raw_patch

    raw_patch = diff_raw(old_data, new_data)

    return pack(raw_patch)

def unpack_raw(bytes patch_data):
    return _kgdiff_unpack_to_raw_py(patch_data)

def patch_raw(bytes old_data, bytes raw_patch):
    return _kgpatch_raw_from_bytes(old_data, raw_patch)

def patch(bytes old_data, bytes patch_data):
    cdef bytes raw_patch

    raw_patch = unpack_raw(patch_data)

    return patch_raw(old_data, raw_patch)

def patch_chain(bytes old_data, patches):
    cdef bytes current
    cdef object patch_data

    current = old_data

    for patch_data in patches:
        current = patch(current, bytes(patch_data))

    return current

def is_kgdiff(bytes patch_data):
    try:
        info(patch_data)
        return True
    except Exception:
        return False

def info(bytes patch_data):
    cdef const u8[:] patch_view = patch_data
    cdef const u8* patch_ptr
    cdef KGDiffHeader header
    cdef KGDiffHeader raw_header
    cdef u8 control_codec
    cdef u8 diff_codec
    cdef u8 extra_codec
    cdef u64 control_payload_size
    cdef u64 diff_payload_size
    cdef u64 extra_payload_size
    cdef u64 control_offset
    cdef u64 diff_offset
    cdef u64 extra_offset
    cdef u64 end_offset
    cdef int retval
    cdef bytes raw_patch
    cdef const u8[:] raw_view
    cdef const u8* raw_ptr
    cdef u8 raw_control_codec
    cdef u8 raw_diff_codec
    cdef u8 raw_extra_codec
    cdef u64 raw_control_size
    cdef u64 raw_diff_size
    cdef u64 raw_extra_size

    if len(patch_data) < KGDIFF_HEADER_SIZE:
        raise_error(KGDIFF_ERR_FORMAT)

    patch_ptr = &patch_view[0]

    retval = kgdiff_read_header_struct(patch_ptr, &header)
    if retval != KGDIFF_OK:
        raise_error(retval)

    retval = kgdiff_header_get_sizes(
        &header,
        &control_codec,
        &control_payload_size,
        &diff_codec,
        &diff_payload_size,
        &extra_codec,
        &extra_payload_size
    )
    if retval != KGDIFF_OK:
        raise_error(retval)

    control_offset = KGDIFF_HEADER_SIZE
    diff_offset = control_offset + control_payload_size
    extra_offset = diff_offset + diff_payload_size
    end_offset = extra_offset + extra_payload_size

    if end_offset != <u64>len(patch_data):
        raise_error(KGDIFF_ERR_FORMAT)

    raw_patch = unpack_raw(patch_data)

    raw_view = raw_patch
    raw_ptr = &raw_view[0]

    retval = kgdiff_read_header_struct(raw_ptr, &raw_header)
    if retval != KGDIFF_OK:
        raise_error(retval)

    retval = kgdiff_header_get_sizes(
        &raw_header,
        &raw_control_codec,
        &raw_control_size,
        &raw_diff_codec,
        &raw_diff_size,
        &raw_extra_codec,
        &raw_extra_size
    )
    if retval != KGDIFF_OK:
        raise_error(retval)

    if raw_control_codec != KGDIFF_CODEC_RAW:
        raise_error(KGDIFF_ERR_CODEC)
    if raw_diff_codec != KGDIFF_CODEC_RAW:
        raise_error(KGDIFF_ERR_CODEC)
    if raw_extra_codec != KGDIFF_CODEC_RAW:
        raise_error(KGDIFF_ERR_CODEC)

    if raw_control_size % KGDIFF_CONTROL_SIZE != 0:
        raise_error(KGDIFF_ERR_FORMAT)

    return {
        "magic": b"KGDIFF1\x00",
        "old_size": raw_header.old_size,
        "new_size": raw_header.new_size,
        "patch_size": len(patch_data),
        "raw_equiv_size": len(raw_patch),
        "block_count": raw_control_size // KGDIFF_CONTROL_SIZE,

        "control_codec": control_codec,
        "control_payload_size": control_payload_size,
        "control_raw_size": raw_control_size,

        "diff_codec": diff_codec,
        "diff_payload_size": diff_payload_size,
        "diff_raw_size": raw_diff_size,

        "extra_codec": extra_codec,
        "extra_payload_size": extra_payload_size,
        "extra_raw_size": raw_extra_size,

        "control_offset": control_offset,
        "diff_offset": diff_offset,
        "extra_offset": extra_offset,
        "end_offset": end_offset,
    }

def selftest():
    cdef bytes old_data
    cdef bytes new_data
    cdef bytes patch_data
    cdef bytes raw_patch
    cdef bytes result
    cdef bytes p1
    cdef bytes p2

    validate_platform()

    for old_data, new_data in [
        (b"", b""),
        (b"", b"abc"),
        (b"abc", b""),
        (b"abc", b"abc"),
        (b"abc", b"abXc"),
        (b"hello world", b"hello brave new world"),
        (bytes(range(64)), bytes(range(1, 65))),
        (b"aaaaabbbbbccccc", b"aaaXXbbbbbYYYYcccccZ"),
    ]:
        patch_data = diff(old_data, new_data)

        assert patch_data[:8] == b"KGDIFF1\0"
        assert len(patch_data) >= 48

        raw_patch = unpack_raw(patch_data)
        assert raw_patch[:8] == b"KGDIFF1\0"
        assert len(raw_patch) >= 48

        result = patch(old_data, patch_data)
        assert result == new_data

        result = patch_raw(old_data, raw_patch)
        assert result == new_data

    p1 = diff(b"a", b"ab")
    p2 = diff(b"ab", b"abc")
    result = patch_chain(b"a", [p1, p2])
    assert result == b"abc"

    return True

