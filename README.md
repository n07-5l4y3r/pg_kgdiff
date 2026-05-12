# pg_kgdiff

PostgreSQL extension for compact binary delta patches using the `KGDIFF1` patch format.

`pg_kgdiff` provides SQL-callable binary diff and patch functions for `bytea` values. It is designed for storing compact version deltas inside PostgreSQL while keeping patch application simple and deterministic.

The extension uses:

- PostgreSQL `plpython3u` as the SQL function envelope
- a compiled Cython module for the binary diff / patch engine
- a compact sectioned patch format with per-section compression
- `bytea` input and output throughout

## Patch Format

`pg_kgdiff` stores patches as `KGDIFF1` objects.

A patch contains:

```text
KGDIFF1 header
compressed control section
compressed diff section
compressed extra section
````

Each section may be stored raw or compressed independently.

Current section codecs:

```text
0      raw / uncompressed
1..9   zlib compression level
```

The format is optimized for diff patches where the control and diff sections often contain long runs of repeated or zero bytes, which compress significantly better than directly compressing the target file.

## Functions

### `kg_diff(from_data bytea, to_data bytea) -> bytea`

Creates a `KGDIFF1` patch from `from_data` to `to_data`.

```sql
SELECT kg_diff('hello world'::bytea, 'hello brave new world'::bytea);
```

### `kg_patch(from_data bytea, patch_data bytea) -> bytea`

Applies a single patch to `from_data`.

```sql
WITH p AS (
  SELECT kg_diff(
    'hello world'::bytea,
    'hello brave new world'::bytea
  ) AS patch
)
SELECT convert_from(
  kg_patch('hello world'::bytea, patch),
  'UTF8'
) AS result
FROM p;
```

Result:

```text
hello brave new world
```

### `kg_patch(from_data bytea, patches bytea[]) -> bytea`

Applies an ordered chain of patches to `from_data`.

```sql
WITH patches AS (
  SELECT
    kg_diff('a'::bytea, 'ab'::bytea) AS p1,
    kg_diff('ab'::bytea, 'abc'::bytea) AS p2
)
SELECT convert_from(
  kg_patch('a'::bytea, ARRAY[p1, p2]),
  'UTF8'
) AS result
FROM patches;
```

Result:

```text
abc
```

### `kg_info(patch_data bytea) -> jsonb`

Returns metadata about a `KGDIFF1` patch.

```sql
WITH p AS (
  SELECT kg_diff(
    'hello world'::bytea,
    'hello brave new world'::bytea
  ) AS patch
)
SELECT kg_info(patch)
FROM p;
```

Example output:

```json
{
  "magic_hex": "4b47444946463100",
  "magic_ascii": "KGDIFF1",
  "old_size": 11,
  "new_size": 21,
  "patch_size": 87,
  "raw_equiv_size": 93,
  "block_count": 1,
  "control_codec": 9,
  "control_payload_size": 18,
  "control_raw_size": 24,
  "diff_codec": 0,
  "diff_payload_size": 6,
  "diff_raw_size": 6,
  "extra_codec": 0,
  "extra_payload_size": 15,
  "extra_raw_size": 15,
  "control_offset": 48,
  "diff_offset": 66,
  "extra_offset": 72,
  "end_offset": 87
}
```

### `kg_selftest() -> boolean`

Runs the built-in extension self-test.

```sql
SELECT kg_selftest();
```

Expected result:

```text
t
```

## Installation

The extension requires `plpython3u`.

```sql
CREATE EXTENSION plpython3u;
CREATE EXTENSION pg_kgdiff;
```

## Example: Store Version History as Patches

```sql
CREATE TEMP TABLE kgdiff_test_versions (
  version_id integer PRIMARY KEY,
  payload bytea NOT NULL,
  patch_from_previous bytea
);

INSERT INTO kgdiff_test_versions(version_id, payload, patch_from_previous)
VALUES
  (1, 'alpha'::bytea, NULL),
  (
    2,
    'alpha beta'::bytea,
    kg_diff('alpha'::bytea, 'alpha beta'::bytea)
  ),
  (
    3,
    'alpha beta gamma'::bytea,
    kg_diff('alpha beta'::bytea, 'alpha beta gamma'::bytea)
  );
```

Reconstruct version 3 from version 1 and the patch chain:

```sql
WITH chain AS (
  SELECT array_agg(patch_from_previous ORDER BY version_id) FILTER (
    WHERE patch_from_previous IS NOT NULL
  ) AS patches
  FROM kgdiff_test_versions
),
base AS (
  SELECT payload AS base_payload
  FROM kgdiff_test_versions
  WHERE version_id = 1
),
expected AS (
  SELECT payload AS expected_payload
  FROM kgdiff_test_versions
  WHERE version_id = 3
)
SELECT
  kg_patch(base_payload, patches) = expected_payload AS passed,
  convert_from(kg_patch(base_payload, patches), 'UTF8') AS result
FROM base, chain, expected;
```

Expected result:

```text
passed | result
-------+------------------
t      | alpha beta gamma
```

## Smoke Test

```sql
SELECT kg_selftest();

SELECT encode(
  kg_diff('hello world'::bytea, 'hello brave new world'::bytea),
  'hex'
) AS patch_hex;

WITH p AS (
  SELECT kg_diff(
    'hello world'::bytea,
    'hello brave new world'::bytea
  ) AS patch
)
SELECT convert_from(
  kg_patch('hello world'::bytea, patch),
  'UTF8'
) AS result
FROM p;
```

Expected result:

```text
kg_selftest
-----------
t

result
-----------------------
hello brave new world
```

## Docker Build Integration

Example image tag:

```dockerfile
# syntax=docker/dockerfile:1.7

ARG RUST_VERSION=1.88.0
ARG CARGO_PGRX_VERSION=0.16.0

ARG PG_JSONSCHEMA_TAG=v0.3.4
ARG PG_JSONSCHEMA_COMMIT=cbe74b570d38aa0c4d42914e7a118bcb3adaee7a

ARG PG_RFC8785_TAG=v0.1.0
ARG PG_RFC8785_COMMIT=99cb8adc26b0dea33dbfa6a7c901c1fa6db5906d

ARG PG_KGDIFF_TAG=v0.1.0
ARG PG_KGDIFF_COMMIT=4f2a97a05b884485034e5097af96df7b49d26444

# ---------- shared Rust/pgrx toolchain ----------
FROM timescale/timescaledb-ha:pg18.0-all-oss-builder@sha256:a499180acfa15f317ecb9e2357391373661f3b9988f5760c82516cc762b6b642 AS pgrx-toolchain

ARG RUST_VERSION
ARG CARGO_PGRX_VERSION

USER root

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      git \
      clang \
      pkg-config \
      build-essential \
 && rm -rf /var/lib/apt/lists/*

ENV CARGO_HOME=/usr/local/cargo
ENV RUSTUP_HOME=/usr/local/rustup
ENV PATH=/usr/local/cargo/bin:$PATH

RUN curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs \
 | sh -s -- -y --profile minimal --default-toolchain "${RUST_VERSION}"

RUN cargo install --locked cargo-pgrx --version "${CARGO_PGRX_VERSION}" \
 && cargo pgrx init --pg18 "$(which pg_config)"

# ---------- build pg_jsonschema ----------
FROM pgrx-toolchain AS build-pg-jsonschema

ARG PG_JSONSCHEMA_TAG
ARG PG_JSONSCHEMA_COMMIT

WORKDIR /build

RUN git clone https://github.com/supabase/pg_jsonschema.git \
 && cd pg_jsonschema \
 && git checkout "tags/${PG_JSONSCHEMA_TAG}" \
 && test "$(git rev-parse HEAD)" = "${PG_JSONSCHEMA_COMMIT}"

WORKDIR /build/pg_jsonschema

RUN cargo pgrx install --release --pg-config "$(which pg_config)"

# ---------- build pg_rfc8785 ----------
FROM pgrx-toolchain AS build-pg-rfc8785

ARG PG_RFC8785_TAG
ARG PG_RFC8785_COMMIT

WORKDIR /build

RUN git clone https://github.com/n07-5l4y3r/pg_rfc8785.git \
 && cd pg_rfc8785 \
 && git checkout "tags/${PG_RFC8785_TAG}" \
 && test "$(git rev-parse HEAD)" = "${PG_RFC8785_COMMIT}"

WORKDIR /build/pg_rfc8785

RUN cargo pgrx install --release --pg-config "$(which pg_config)"

# ---------- build pg_kgdiff ----------
FROM timescale/timescaledb-ha:pg18.0-ts2.23.0-all-oss@sha256:3490cfabb3c885ed63de7253e18d228fe6ec7a9efc56477fecf1f0d55932a575 AS build-pg-kgdiff

ARG PG_KGDIFF_TAG
ARG PG_KGDIFF_COMMIT

USER root

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates \
      git \
      build-essential \
      python3-dev \
      python3-pip \
      python3-setuptools \
      python3-wheel \
 && rm -rf /var/lib/apt/lists/*

RUN python3 -m pip install --no-cache-dir Cython

WORKDIR /build

RUN git clone https://github.com/n07-5l4y3r/pg_kgdiff.git \
 && cd pg_kgdiff \
 && git checkout "tags/${PG_KGDIFF_TAG}" \
 && test "$(git rev-parse HEAD)" = "${PG_KGDIFF_COMMIT}"

WORKDIR /build/pg_kgdiff

RUN python3 setup.py build_ext --inplace

RUN python3 - <<'PY'
import pg_kgdiff1
assert pg_kgdiff1.selftest() is True
print("pg_kgdiff selftest passed")
PY

RUN mkdir -p /artifact/python /artifact/extension \
 && cp /build/pg_kgdiff/kgdiff1*.so /artifact/python/ \
 && cp /build/pg_kgdiff/pg_kgdiff1.py /artifact/python/ \
 && cp /build/pg_kgdiff/pg_kgdiff.control /artifact/extension/ \
 && cp /build/pg_kgdiff/pg_kgdiff--*.sql /artifact/extension/

# ---------- runtime ----------
FROM timescale/timescaledb-ha:pg18.0-ts2.23.0-all-oss@sha256:3490cfabb3c885ed63de7253e18d228fe6ec7a9efc56477fecf1f0d55932a575

USER root

COPY --from=build-pg-jsonschema /usr/lib/postgresql/18/lib/pg_jsonschema.so /usr/lib/postgresql/18/lib/
COPY --from=build-pg-jsonschema /usr/share/postgresql/18/extension/pg_jsonschema* /usr/share/postgresql/18/extension/

COPY --from=build-pg-rfc8785 /usr/lib/postgresql/18/lib/pg_rfc8785.so /usr/lib/postgresql/18/lib/
COPY --from=build-pg-rfc8785 /usr/share/postgresql/18/extension/pg_rfc8785* /usr/share/postgresql/18/extension/

COPY --from=build-pg-kgdiff /artifact/python/kgdiff1*.so /usr/local/lib/python3.10/dist-packages/
COPY --from=build-pg-kgdiff /artifact/python/pg_kgdiff1.py /usr/local/lib/python3.10/dist-packages/
COPY --from=build-pg-kgdiff /artifact/extension/pg_kgdiff* /usr/share/postgresql/18/extension/

USER postgres
```
```bash
sudo docker build --progress=plain \
  -t timescaledb-ha-pg18-jsonschema-rfc8785-kgdiff:pg-18.0_ts-2.23.0_pg_jsonschema-0.3.4_pg_rfc8785-0.1.0_pg_kgdiff-0.1.0 \
  .
```

The build stage compiles the Cython module against the same Python runtime used by `plpython3u` in the final PostgreSQL image.

Runtime artifacts:

```text
/usr/local/lib/python3.10/dist-packages/kgdiff1*.so
/usr/local/lib/python3.10/dist-packages/pg_kgdiff1.py
/usr/share/postgresql/18/extension/pg_kgdiff.control
/usr/share/postgresql/18/extension/pg_kgdiff--*.sql
```

## Notes

`pg_kgdiff` is intended to store and exchange compressed `KGDIFF1` patches only. Raw internal patch sections are implementation details and are not intended as the PostgreSQL storage format.

Patch chains must be applied in order. Each patch must have been produced from the exact previous version in the chain.

## Repository Description

PostgreSQL extension for compact `bytea` delta patches using a Cython-powered `KGDIFF1` binary diff format.
