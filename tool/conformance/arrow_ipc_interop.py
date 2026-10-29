#!/usr/bin/env python3
"""Independent PyArrow oracle for dartaframes_arrow IPC interoperability.

The script has three commands:

``generate``
    Build small deterministic Arrow IPC fixtures with official PyArrow and
    write, per fixture, ``<family>/<name>.arrow`` (IPC file),
    ``<family>/<name>.arrows`` (IPC stream), ``<family>/<name>.json``
    (expectation summary) and a top-level ``manifest.json``.

``check``
    Regenerate into a temporary directory and require byte-identical output
    against the committed fixtures (determinism / staleness gate).

``verify``
    Read IPC files written by *another* implementation (the Dart writer)
    with PyArrow, run full validation and compare schema, metadata, batch row
    counts and canonical values against the committed expectations.  This is
    the interoperability direction Dart -> PyArrow.  ``--self-test`` verifies
    the committed fixtures themselves, which sanity checks the oracle.

Expectation value encoding (identical for every fixture, see ``encode``):

* null -> ``null``; bool -> JSON bool
* int8..int32, uint8..uint32, date32, time32 -> JSON number
* int64, uint64, date64, time64, timestamp, duration -> decimal string
* float16/32/64 -> raw IEEE bit pattern as ``"0x...``" hex string
  (preserves NaN payloads and negative zero)
* decimal32..256 -> unscaled integer as decimal string
* utf8 / large_utf8 / utf8_view -> JSON string
* binary / large_binary / binary_view / fixed_size_binary -> lowercase hex
* list / large_list / fixed_size_list / list_view / large_list_view -> array
* struct -> object keyed by child field name
* map -> array of ``[key, value]`` pairs
* dictionary -> logical (decoded) value; physical indices and dictionary
  values are additionally recorded under ``columns[i].dictionary``
* sparse/dense union -> ``{"type_code": n, "value": v}``
* run-end encoded -> logical (expanded) value
* month_day_nano interval -> ``[months, days, "nanoseconds"]``
* extension -> storage value (extension identity lives in field metadata)

Extension types are always handled *unregistered*, i.e. as their storage type
plus ``ARROW:extension:name`` / ``ARROW:extension:metadata`` field metadata,
so that the comparison is byte-faithful and independent of PyArrow's
extension registry.

Usage (with an isolated PyArrow environment)::

    P=.venv/bin/python  # venv with tool/conformance/requirements.txt
    $P tool/conformance/arrow_ipc_interop.py generate
    $P tool/conformance/arrow_ipc_interop.py check
    $P tool/conformance/arrow_ipc_interop.py verify --self-test
    $P tool/conformance/arrow_ipc_interop.py verify --output build/arrow_ipc_dart --require-all
"""

from __future__ import annotations

import argparse
import decimal
import filecmp
import json
import sys
import tempfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable

try:
    import pyarrow as pa
    import pyarrow.ipc as ipc
except ImportError:  # pragma: no cover - environment guard
    sys.stderr.write(
        "pyarrow is required. Use an isolated environment, e.g.\n"
        "  python3 -m venv .venv && "
        ".venv/bin/pip install -r tool/conformance/requirements.txt\n"
    )
    raise SystemExit(2)

ROOT = Path(__file__).resolve().parent.parent.parent
DEFAULT_FIXTURES = ROOT / "test" / "conformance" / "fixtures" / "arrow_ipc"
FORMAT_VERSION = 1
FORMATS = {"file": ".arrow", "stream": ".arrows"}

_KNOWN_EXTENSIONS = (
    "arrow.uuid",
    "arrow.json",
    "arrow.bool8",
    "arrow.fixed_shape_tensor",
    "arrow.opaque",
)


def unregister_extensions() -> None:
    """Treat every extension as storage + field metadata (byte faithful)."""
    for name in _KNOWN_EXTENSIONS:
        try:
            pa.unregister_extension_type(name)
        except (KeyError, ValueError, pa.ArrowException):
            pass


class InteropError(Exception):
    pass


# --------------------------------------------------------------------------
# Schema / type descriptors
# --------------------------------------------------------------------------


def _meta(md: dict[bytes, bytes] | None) -> dict[str, str] | None:
    if not md:
        return None
    out: dict[str, str] = {}
    for k, v in sorted(md.items()):
        key = k.decode("utf-8")
        try:
            out[key] = v.decode("utf-8")
        except UnicodeDecodeError:
            out[key] = "hex:" + v.hex()
    return out


def describe_field(f: pa.Field) -> dict[str, Any]:
    d: dict[str, Any] = {
        "name": f.name,
        "nullable": f.nullable,
        "type": describe_type(f.type),
    }
    md = _meta(f.metadata)
    if md:
        d["metadata"] = md
    return d


_SIMPLE = {
    pa.null(): "null",
    pa.bool_(): "bool",
    pa.int8(): "int8",
    pa.int16(): "int16",
    pa.int32(): "int32",
    pa.int64(): "int64",
    pa.uint8(): "uint8",
    pa.uint16(): "uint16",
    pa.uint32(): "uint32",
    pa.uint64(): "uint64",
    pa.float16(): "float16",
    pa.float32(): "float32",
    pa.float64(): "float64",
    pa.string(): "utf8",
    pa.large_string(): "large_utf8",
    pa.string_view(): "utf8_view",
    pa.binary(): "binary",
    pa.large_binary(): "large_binary",
    pa.binary_view(): "binary_view",
    pa.date32(): "date32",
    pa.date64(): "date64",
    pa.month_day_nano_interval(): "interval_month_day_nano",
}


def describe_type(t: pa.DataType) -> dict[str, Any]:
    if t in _SIMPLE:
        return {"id": _SIMPLE[t]}
    if isinstance(t, pa.ExtensionType):  # only if a caller registered one
        raise InteropError(f"registered extension type leaked: {t}")
    if pa.types.is_fixed_size_binary(t) and not pa.types.is_decimal(t):
        return {"id": "fixed_size_binary", "byte_width": t.byte_width}
    if pa.types.is_decimal(t):
        return {
            "id": f"decimal{t.bit_width}",
            "precision": t.precision,
            "scale": t.scale,
        }
    if pa.types.is_time32(t) or pa.types.is_time64(t):
        return {"id": f"time{t.bit_width}", "unit": t.unit}
    if pa.types.is_timestamp(t):
        return {"id": "timestamp", "unit": t.unit, "timezone": t.tz}
    if pa.types.is_duration(t):
        return {"id": "duration", "unit": t.unit}
    if pa.types.is_dictionary(t):
        return {
            "id": "dictionary",
            "index": describe_type(t.index_type),
            "value": describe_type(t.value_type),
            "ordered": t.ordered,
        }
    if pa.types.is_map(t):
        return {
            "id": "map",
            "keys_sorted": t.keys_sorted,
            "children": [describe_field(t.field(i)) for i in range(t.num_fields)],
        }
    if pa.types.is_fixed_size_list(t):
        return {
            "id": "fixed_size_list",
            "list_size": t.list_size,
            "children": [describe_field(t.value_field)],
        }
    for pred, name in (
        (pa.types.is_large_list_view, "large_list_view"),
        (pa.types.is_list_view, "list_view"),
        (pa.types.is_large_list, "large_list"),
        (pa.types.is_list, "list"),
    ):
        if pred(t):
            return {"id": name, "children": [describe_field(t.value_field)]}
    if pa.types.is_struct(t):
        return {
            "id": "struct",
            "children": [describe_field(t.field(i)) for i in range(t.num_fields)],
        }
    if pa.types.is_union(t):
        return {
            "id": f"{t.mode}_union",
            "type_codes": list(t.type_codes),
            "children": [describe_field(t.field(i)) for i in range(t.num_fields)],
        }
    if pa.types.is_run_end_encoded(t):
        return {
            "id": "run_end_encoded",
            "children": [
                describe_field(pa.field("run_ends", t.run_end_type, False)),
                describe_field(pa.field("values", t.value_type, True)),
            ],
        }
    raise InteropError(f"unsupported type in oracle: {t}")


def describe_schema(s: pa.Schema) -> dict[str, Any]:
    d: dict[str, Any] = {"fields": [describe_field(f) for f in s]}
    md = _meta(s.metadata)
    if md:
        d["metadata"] = md
    return d


# --------------------------------------------------------------------------
# Canonical value encoding
# --------------------------------------------------------------------------

_FLOAT_VIEW = {16: pa.uint16(), 32: pa.uint32(), 64: pa.uint64()}
_HEX_WIDTH = {16: 4, 32: 8, 64: 16}


def _nulls(arr: pa.Array) -> list[bool]:
    if arr.null_count == 0 and not pa.types.is_null(arr.type):
        return [False] * len(arr)
    return arr.is_null().to_pylist()


def _unscaled(d: decimal.Decimal, scale: int) -> str:
    with decimal.localcontext() as ctx:
        ctx.prec = 200
        v = d.scaleb(scale)
        if v != v.to_integral_value():
            raise InteropError(f"non-integral unscaled decimal {d} scale {scale}")
        return str(int(v))


def encode(arr: pa.Array) -> list[Any]:
    """Return canonical JSON values (one per logical row) for ``arr``."""
    t = arr.type
    n = len(arr)
    if pa.types.is_null(t):
        return [None] * n
    if pa.types.is_dictionary(t):
        dvals = encode(arr.dictionary)
        return [None if i is None else dvals[i] for i in arr.indices.to_pylist()]
    if pa.types.is_run_end_encoded(t):
        ends = arr.run_ends.to_pylist()
        vals = encode(arr.values)
        out = []
        run = 0
        for i in range(n):
            j = arr.offset + i
            while ends[run] <= j:
                run += 1
            out.append(vals[run])
        return out
    if pa.types.is_union(t):
        codes = arr.type_codes.to_pylist()
        code_to_child = {c: k for k, c in enumerate(t.type_codes)}
        children = [encode(arr.field(k)) for k in range(t.num_fields)]
        offsets = arr.offsets.to_pylist() if t.mode == "dense" else None
        out = []
        for i, code in enumerate(codes):
            k = code_to_child[code]
            idx = offsets[i] if offsets is not None else i
            out.append({"type_code": code, "value": children[k][idx]})
        return out
    nulls = _nulls(arr)
    if pa.types.is_floating(t):
        bits = arr.view(_FLOAT_VIEW[t.bit_width]).to_pylist()
        w = _HEX_WIDTH[t.bit_width]
        return [None if b is None else f"0x{b:0{w}x}" for b in bits]
    if pa.types.is_boolean(t):
        return arr.to_pylist()
    if pa.types.is_integer(t):
        vals = arr.to_pylist()
        if t.bit_width == 64:
            return [None if v is None else str(v) for v in vals]
        return vals
    if pa.types.is_decimal(t):
        return [None if v is None else _unscaled(v, t.scale) for v in arr.to_pylist()]
    if pa.types.is_date32(t) or pa.types.is_time32(t):
        return arr.view(pa.int32()).to_pylist()
    if (
        pa.types.is_date64(t)
        or pa.types.is_time64(t)
        or pa.types.is_timestamp(t)
        or pa.types.is_duration(t)
    ):
        return [None if v is None else str(v) for v in arr.view(pa.int64()).to_pylist()]
    if pa.types.is_interval(t):
        return [
            None if v is None else [v.months, v.days, str(v.nanoseconds)]
            for v in arr.to_pylist()
        ]
    if pa.types.is_string(t) or pa.types.is_large_string(t) or pa.types.is_string_view(t):
        return arr.to_pylist()
    if (
        pa.types.is_binary(t)
        or pa.types.is_large_binary(t)
        or pa.types.is_binary_view(t)
        or pa.types.is_fixed_size_binary(t)
    ):
        return [None if v is None else v.hex() for v in arr.to_pylist()]
    if pa.types.is_struct(t):
        names = [t.field(i).name for i in range(t.num_fields)]
        cols = [encode(arr.field(i)) for i in range(t.num_fields)]
        return [
            None if nulls[r] else {names[c]: cols[c][r] for c in range(len(names))}
            for r in range(n)
        ]
    if pa.types.is_fixed_size_list(t):
        vals = encode(arr.values)
        size = t.list_size
        base = arr.offset
        return [
            None if nulls[r] else vals[(base + r) * size : (base + r + 1) * size]
            for r in range(n)
        ]
    if pa.types.is_list_view(t) or pa.types.is_large_list_view(t):
        vals = encode(arr.values)
        offs = arr.offsets.to_pylist()
        sizes = arr.sizes.to_pylist()
        return [
            None if nulls[r] else vals[offs[r] : offs[r] + sizes[r]] for r in range(n)
        ]
    if pa.types.is_map(t):
        entries = encode(arr.values)
        kname = t.key_field.name
        iname = t.item_field.name
        offs = arr.offsets.to_pylist()
        return [
            None
            if nulls[r]
            else [[e[kname], e[iname]] for e in entries[offs[r] : offs[r + 1]]]
            for r in range(n)
        ]
    if pa.types.is_list(t) or pa.types.is_large_list(t):
        vals = encode(arr.values)
        offs = arr.offsets.to_pylist()
        return [None if nulls[r] else vals[offs[r] : offs[r + 1]] for r in range(n)]
    raise InteropError(f"cannot encode type {t}")


def _dictionary_detail(chunks: list[pa.Array]) -> list[dict[str, Any]] | None:
    if not chunks or not pa.types.is_dictionary(chunks[0].type):
        return None
    return [
        {"indices": encode(c.indices), "values": encode(c.dictionary)} for c in chunks
    ]


def summarize(batches: list[pa.RecordBatch], schema: pa.Schema) -> dict[str, Any]:
    cols = []
    for i, f in enumerate(schema):
        chunks = [b.column(i) for b in batches]
        values: list[Any] = []
        for c in chunks:
            values.extend(encode(c))
        col: dict[str, Any] = {
            "name": f.name,
            "null_count": sum(c.null_count for c in chunks),
            "values": values,
        }
        detail = _dictionary_detail(chunks)
        if detail is not None:
            col["dictionary"] = detail
        cols.append(col)
    return {
        "schema": describe_schema(schema),
        "num_rows": sum(b.num_rows for b in batches),
        "batch_row_counts": [b.num_rows for b in batches],
        "columns": cols,
    }


# --------------------------------------------------------------------------
# Fixture catalogue
# --------------------------------------------------------------------------


@dataclass
class Fixture:
    family: str
    name: str
    description: str
    schema: pa.Schema
    batches: list[pa.RecordBatch]
    formats: tuple[str, ...] = ("file", "stream")
    write_options: dict[str, Any] = field(default_factory=dict)
    optional: bool = False
    notes: str | None = None

    @property
    def key(self) -> str:
        return f"{self.family}/{self.name}"


def _f16(bits: list[int | None]) -> pa.Array:
    return pa.array(bits, pa.uint16()).view(pa.float16())


def _f32(bits: list[int | None]) -> pa.Array:
    return pa.array(bits, pa.uint32()).view(pa.float32())


def _f64(bits: list[int | None]) -> pa.Array:
    return pa.array(bits, pa.uint64()).view(pa.float64())


def _one(
    family: str,
    name: str,
    description: str,
    columns: dict[str, pa.Array],
    **kw: Any,
) -> Fixture:
    batch = pa.record_batch(list(columns.values()), list(columns.keys()))
    return Fixture(family, name, description, batch.schema, [batch], **kw)


def _ext_field(name: str, storage: pa.DataType, ext: str, meta: bytes = b"") -> pa.Field:
    return pa.field(
        name,
        storage,
        metadata={b"ARROW:extension:name": ext.encode(), b"ARROW:extension:metadata": meta},
    )


def primitive_fixtures() -> list[Fixture]:
    out = []
    ints = {}
    for signed, widths in ((True, (8, 16, 32, 64)), (False, (8, 16, 32, 64))):
        for w in widths:
            t = getattr(pa, f"{'int' if signed else 'uint'}{w}")()
            lo = -(2 ** (w - 1)) if signed else 0
            hi = 2 ** (w - 1) - 1 if signed else 2**w - 1
            ints[str(t)] = pa.array([lo, hi, 0, None, 1 if signed else hi - 1, -1 if signed else 1], t)
    out.append(_one("primitive", "integers", "int8..uint64 extrema, zero and null", ints))
    out.append(
        _one(
            "primitive",
            "floats",
            "float16/32/64 raw bits: +0, -0, inf, -inf, quiet NaN, payload NaN, "
            "negative NaN, subnormal, max, null",
            {
                "f16": _f16([0x0000, 0x8000, 0x7C00, 0xFC00, 0x7E00, 0x7D01, 0xFE00, 0x0001, 0x7BFF, None]),
                "f32": _f32([0, 0x80000000, 0x7F800000, 0xFF800000, 0x7FC00000, 0x7FA00001, 0xFFC00000, 1, 0x7F7FFFFF, None]),
                "f64": _f64([0, 1 << 63, 0x7FF0000000000000, 0xFFF0000000000000, 0x7FF8000000000000, 0x7FF4000000000001, 0xFFF8000000000000, 1, 0x7FEFFFFFFFFFFFFF, None]),
            },
        )
    )
    out.append(
        _one(
            "primitive",
            "booleans",
            "booleans spanning several validity/value bytes",
            {
                "b": pa.array([True, False, None, True, True, False, None, False, True, True, None, False, True, False, False, True, None, True, True]),
                "all_true": pa.array([True] * 19),
            },
        )
    )
    out.append(
        _one(
            "primitive",
            "nulls",
            "Null type column and all-null typed columns",
            {
                "null": pa.nulls(5),
                "i32_all_null": pa.array([None] * 5, pa.int32()),
                "utf8_all_null": pa.array([None] * 5, pa.string()),
            },
        )
    )
    return out


def binary_fixtures() -> list[Fixture]:
    texts = ["", "ascii", None, "héllo wörld", "日本語テキスト", "emoji 😀👍🏽", "e\u0301 combining", "nul\x00inside", "a much longer string beyond twelve bytes"]
    blobs = [b"", b"\x00\x01\xff", None, bytes(range(32)), b"short", b"0123456789abcdefXYZ"]
    out = [
        _one(
            "binary",
            "strings",
            "utf8/large_utf8 with Unicode, empty, embedded NUL and null",
            {
                "utf8": pa.array(texts, pa.string()),
                "large_utf8": pa.array(texts, pa.large_string()),
            },
        ),
        _one(
            "binary",
            "string_view",
            "utf8_view with inline (<=12 bytes) and out-of-line strings",
            {"utf8_view": pa.array(texts, pa.string_view())},
        ),
        _one(
            "binary",
            "binaries",
            "binary/large_binary",
            {
                "binary": pa.array(blobs, pa.binary()),
                "large_binary": pa.array(blobs, pa.large_binary()),
            },
        ),
        _one(
            "binary",
            "binary_view",
            "binary_view with inline and out-of-line values",
            {"binary_view": pa.array(blobs, pa.binary_view())},
        ),
        _one(
            "binary",
            "fixed_size_binary",
            "fixed_size_binary(3) with null",
            {"fsb3": pa.array([b"abc", None, b"\x00\x00\x00", b"\xff\xfe\xfd", b"xyz", b"123"], pa.binary(3))},
        ),
        _one(
            "binary",
            "sliced_strings",
            "utf8 array sliced before writing (non-zero offset normalisation)",
            {"utf8": pa.array(texts, pa.string()).slice(2, 5)},
        ),
    ]
    return out


def temporal_fixtures() -> list[Fixture]:
    i64 = [-(2**63) + 1, 2**63 - 1, 0, None, -1, 1_700_000_000_123]
    cols: dict[str, pa.Array] = {
        "date32": pa.array([-719162, 2932896, 0, None, -1, 19000], pa.int32()).view(pa.date32()),
        "date64": pa.array([-62135596800000, 253402214400000, 0, None, -86400000, 1641600000000], pa.int64()).view(pa.date64()),
        "time32_s": pa.array([0, 86399, None, 1, 43200, 3600], pa.time32("s")),
        "time32_ms": pa.array([0, 86399999, None, 1, 43200000, 3600000], pa.time32("ms")),
        "time64_us": pa.array([0, 86399999999, None, 1, 43200000000, 3600000000], pa.time64("us")),
        "time64_ns": pa.array([0, 86399999999999, None, 1, 43200000000000, 3600000000000], pa.time64("ns")),
    }
    for unit in ("s", "ms", "us", "ns"):
        cols[f"ts_{unit}"] = pa.array(i64, pa.int64()).view(pa.timestamp(unit))
    cols["ts_ms_utc"] = pa.array(i64, pa.int64()).view(pa.timestamp("ms", "UTC"))
    cols["ts_us_ny"] = pa.array(i64, pa.int64()).view(pa.timestamp("us", "America/New_York"))
    cols["ts_ns_offset"] = pa.array(i64, pa.int64()).view(pa.timestamp("ns", "+01:00"))
    for unit in ("s", "ms", "us", "ns"):
        cols[f"duration_{unit}"] = pa.array(i64, pa.int64()).view(pa.duration(unit))
    out = [_one("temporal", "temporals", "date/time/timestamp(+tz)/duration extrema and nulls", cols)]
    out.append(
        _one(
            "temporal",
            "interval_month_day_nano",
            "month_day_nano interval extrema and null",
            {
                "mdn": pa.array(
                    [
                        pa.MonthDayNano([0, 0, 0]),
                        pa.MonthDayNano([-(2**31), -(2**31), -(2**63)]),
                        pa.MonthDayNano([2**31 - 1, 2**31 - 1, 2**63 - 1]),
                        None,
                        pa.MonthDayNano([1, -2, 3]),
                    ],
                    pa.month_day_nano_interval(),
                )
            },
            notes="year_month and day_time intervals are not constructible in PyArrow",
        )
    )
    return out


def decimal_fixtures() -> list[Fixture]:
    D = decimal.Decimal

    def dec(values: list[str | None], t: pa.DataType) -> pa.Array:
        return pa.array([None if v is None else D(v) for v in values], t)

    def full(p: int, s: int) -> str:
        digits = "9" * p
        return digits if s == 0 else digits[: p - s] + "." + digits[p - s :] if p > s else "0." + digits

    cols = {
        "d32_9_2": dec([full(9, 2), "-" + full(9, 2), "0", None, "1.50", "-0.01"], pa.decimal32(9, 2)),
        "d64_18_4": dec([full(18, 4), "-" + full(18, 4), "0", None, "1.5000", "-0.0001"], pa.decimal64(18, 4)),
        "d128_38_10": dec([full(38, 10), "-" + full(38, 10), "0", None, "12345.6789", "-0.0000000001"], pa.decimal128(38, 10)),
        "d128_5_0": dec(["99999", "-99999", "0", None, "1", "-1"], pa.decimal128(5, 0)),
        "d256_76_20": dec([full(76, 20), "-" + full(76, 20), "0", None, "3.14159265358979323846", "-1"], pa.decimal256(76, 20)),
    }
    out = [
        _one("decimal", f"{key.split('_')[0].replace('d', 'decimal')}_{key.split('_', 1)[1]}", f"{arr.type} precision extrema, zero, null", {key: arr})
        for key, arr in cols.items()
    ]
    out.append(
        _one(
            "decimal",
            "negative_scale",
            "decimal128 with negative scale",
            {"d128_5_m2": pa.array([D("9999900"), D("-100"), None], pa.decimal128(5, -2))},
        )
    )
    return out


def nested_fixtures() -> list[Fixture]:
    lst = [[1, 2, None], [], None, [4], [5, 6, 7, 8]]
    point = pa.struct([pa.field("x", pa.int32()), pa.field("label", pa.string())])
    structs = pa.StructArray.from_arrays(
        [pa.array([1, None, 3, 4, 5], pa.int32()), pa.array(["a", "b", None, "d", "é"])],
        fields=list(point),
        mask=pa.array([False, False, False, True, False]),
    )
    out = [
        _one(
            "nested",
            "lists",
            "list/large_list/fixed_size_list of int32 with null rows and null items",
            {
                "list": pa.array(lst, pa.list_(pa.int32())),
                "large_list": pa.array(lst, pa.large_list(pa.int32())),
                "fixed_list": pa.array([[1, 2], [None, 4], None, [7, 8], [9, 10]], pa.list_(pa.int32(), 2)),
                "list_utf8": pa.array([["a", None], None, [], ["日本"], ["x", "y", "z"]], pa.list_(pa.string())),
            },
        ),
        _one(
            "nested",
            "nested_lists",
            "list<list<int64>> and list<struct>",
            {
                "list_list": pa.array([[[1], [2, 3]], [None, []], None, [[None]], []], pa.list_(pa.list_(pa.int64()))),
                "list_struct": pa.array(
                    [[{"x": 1, "label": "a"}], [], None, [{"x": None, "label": None}, None], [{"x": 2, "label": "b"}]],
                    pa.list_(point),
                ),
            },
        ),
        _one(
            "nested",
            "structs",
            "struct with null rows/children and nested struct",
            {
                "point": structs,
                "outer": pa.array(
                    [{"inner": {"v": 1.5}, "flag": True}, None, {"inner": None, "flag": False}, {"inner": {"v": None}, "flag": None}, {"inner": {"v": -0.0}, "flag": True}],
                    pa.struct([pa.field("inner", pa.struct([pa.field("v", pa.float64())])), pa.field("flag", pa.bool_())]),
                ),
            },
        ),
        _one(
            "nested",
            "maps",
            "map<utf8,int64> with null rows, empty maps and null values",
            {
                "map": pa.array([[("a", 1), ("b", None)], None, [], [("c", 3)], [("é", -1), ("z", 26)]], pa.map_(pa.string(), pa.int64())),
                "map_sorted": pa.array(
                    [[(1, "one"), (2, "two")], [], None, [(3, None)], [(4, "four")]],
                    pa.map_(pa.int32(), pa.string(), keys_sorted=True),
                ),
            },
        ),
        _one(
            "nested",
            "list_views",
            "list_view/large_list_view with out-of-order and overlapping offsets",
            {
                "list_view": pa.ListViewArray.from_arrays(
                    pa.array([3, 0, 1, 0, 2], pa.int32()),
                    pa.array([1, 2, 2, 0, 2], pa.int32()),
                    pa.array([10, 11, None, 13]),
                    mask=pa.array([False, False, False, True, False]),
                ),
                "large_list_view": pa.LargeListViewArray.from_arrays(
                    pa.array([0, 0, 1, 2, 0], pa.int64()),
                    pa.array([1, 3, 1, 0, 2], pa.int64()),
                    pa.array(["p", "q", "r"]),
                ),
            },
        ),
        _one(
            "nested",
            "sliced_list",
            "list sliced before writing (non-zero offsets normalisation)",
            {"list": pa.array(lst, pa.list_(pa.int32())).slice(1, 3)},
        ),
    ]
    return out


def dictionary_fixtures() -> list[Fixture]:
    def dict_arr(idx: list[int | None], values: pa.Array, index_type: pa.DataType, ordered: bool = False) -> pa.Array:
        return pa.DictionaryArray.from_arrays(pa.array(idx, index_type), values, ordered=ordered)

    words = pa.array(["red", "green", "blue", "日本"])
    out = [
        _one(
            "dictionary",
            "dictionaries",
            "dictionary<utf8> with int8/int16/int32/int64/uint8 indices, nulls, ordered flag",
            {
                "d_i8": dict_arr([0, 1, None, 3, 0, 2], words, pa.int8()),
                "d_i16": dict_arr([3, 3, 2, 1, None, 0], words, pa.int16()),
                "d_i32_ordered": dict_arr([1, 0, 2, None, 1, 3], words, pa.int32(), ordered=True),
                "d_i64_int": dict_arr([0, 0, 1, 1, None, 0], pa.array([100, -7], pa.int64()), pa.int64()),
                "d_u8": dict_arr([2, None, 1, 0, 0, 1], pa.array([b"\x00", b"\xff", b""], pa.binary()), pa.uint8()),
            },
        ),
        _one(
            "dictionary",
            "nested_dictionary",
            "dictionary columns nested inside list and struct",
            {
                "list_dict": pa.ListArray.from_arrays(pa.array([0, 2, 2, 5], pa.int32()), dict_arr([0, 1, None, 2, 0], words, pa.int32())),
                "struct_dict": pa.StructArray.from_arrays([dict_arr([3, 2, 1], words, pa.int16())], names=["color"]),
            },
        ),
    ]
    # Multi-batch with identical dictionary: valid in both formats.
    schema = pa.schema([pa.field("d", pa.dictionary(pa.int32(), pa.string()))])
    b1 = pa.record_batch([dict_arr([0, 1], words, pa.int32())], schema=schema)
    b2 = pa.record_batch([dict_arr([2, None, 3], words, pa.int32())], schema=schema)
    out.append(Fixture("dictionary", "shared_across_batches", "two batches sharing one dictionary", schema, [b1, b2]))
    # Replacement dictionary: stream only (file format forbids replacement).
    r1 = pa.record_batch([dict_arr([0, 1], pa.array(["a", "b"]), pa.int32())], schema=schema)
    r2 = pa.record_batch([dict_arr([1, 0, None], pa.array(["c", "d"]), pa.int32())], schema=schema)
    out.append(
        Fixture(
            "dictionary",
            "replacement",
            "stream with dictionary replacement between batches",
            schema,
            [r1, r2],
            formats=("stream",),
        )
    )
    d1 = pa.record_batch([dict_arr([0, 1], pa.array(["a", "b"]), pa.int32())], schema=schema)
    d2 = pa.record_batch([dict_arr([2, 0, None], pa.array(["a", "b", "c"]), pa.int32())], schema=schema)
    out.append(
        Fixture(
            "dictionary",
            "delta",
            "stream with delta dictionary batch (isDelta=true)",
            schema,
            [d1, d2],
            formats=("stream",),
            write_options={"emit_dictionary_deltas": True},
        )
    )
    return out


def union_fixtures() -> list[Fixture]:
    sparse = pa.UnionArray.from_sparse(
        pa.array([5, 7, 5, 7, 5], pa.int8()),
        [pa.array([1, 2, None, 4, 5], pa.int64()), pa.array(["a", "b", "c", None, "e"])],
        ["i", "s"],
        [5, 7],
    )
    dense = pa.UnionArray.from_dense(
        pa.array([0, 1, 0, 2, 1], pa.int8()),
        pa.array([0, 0, 1, 0, 1], pa.int32()),
        [pa.array([1.5, None], pa.float64()), pa.array(["x", "y"]), pa.array([True], pa.bool_())],
        ["f", "s", "b"],
    )
    return [
        _one("union", "sparse", "sparse union with custom type codes [5, 7]", {"sparse": sparse}),
        _one("union", "dense", "dense union with default type codes", {"dense": dense}),
    ]


def ree_fixtures() -> list[Fixture]:
    cols = {
        "ree16_i32": pa.RunEndEncodedArray.from_arrays(pa.array([2, 3, 6], pa.int16()), pa.array([7, None, -1], pa.int32())),
        "ree32_utf8": pa.RunEndEncodedArray.from_arrays(pa.array([1, 4, 6], pa.int32()), pa.array(["a", None, "日本"])),
        "ree64_f64": pa.RunEndEncodedArray.from_arrays(pa.array([6], pa.int64()), pa.array([0.25], pa.float64())),
    }
    return [
        _one("ree", key, f"run-end encoded {arr.type} with null runs", {key: arr})
        for key, arr in cols.items()
    ]


def extension_fixtures() -> list[Fixture]:
    schema = pa.schema(
        [
            _ext_field("json", pa.string(), "arrow.json"),
            _ext_field("bool8", pa.int8(), "arrow.bool8"),
            _ext_field("custom", pa.int32(), "dartaframes.test.custom", b'{"unit":"m"}'),
        ]
    )
    batch = pa.record_batch(
        [
            pa.array(['{"a":1}', "[]", None]),
            pa.array([1, 0, None], pa.int8()),
            pa.array([1, None, -1], pa.int32()),
        ],
        schema=schema,
    )
    raw_schema = pa.schema([_ext_field("raw", pa.int32(), "dartaframes.test.raw", b"\x00\xff\xfe binary")])
    raw = pa.record_batch([pa.array([1, None], pa.int32())], schema=raw_schema)
    uuid_schema = pa.schema([_ext_field("uuid", pa.binary(16), "arrow.uuid")])
    uuid = pa.record_batch([pa.array([bytes(range(16)), None, b"\xff" * 16], pa.binary(16))], schema=uuid_schema)
    dictionary = pa.DictionaryArray.from_arrays(
        pa.array([0, None, 1, 0], pa.int8()), pa.array(['red', 'blue'])
    )
    dictionary_schema = pa.schema([
        _ext_field('encoded', dictionary.type, 'dartaframes.test.dictionary', b'{"kind":"label"}')
    ])
    dictionary_batch = pa.record_batch([dictionary], schema=dictionary_schema)
    return [
        Fixture('extension', 'dictionary', 'extension annotation over dictionary storage', dictionary_schema, [dictionary_batch]),
        Fixture("extension", "extensions", "canonical (json/bool8) and custom extension metadata", schema, [batch]),
        Fixture("extension", "uuid", "arrow.uuid over fixed_size_binary(16)", uuid_schema, [uuid]),
        Fixture(
            "extension",
            "binary_metadata",
            "extension metadata value that is not valid UTF-8",
            raw_schema,
            [raw],
            notes="Arrow metadata values are bytes; expectation renders them as hex:<bytes>",
        ),
    ]


def metadata_fixtures() -> list[Fixture]:
    schema = pa.schema(
        [
            pa.field("required", pa.int32(), nullable=False, metadata={"role": "id", "ünïcode": "välue"}),
            pa.field("nested", pa.struct([pa.field("child", pa.string(), nullable=False, metadata={"k": "v"})]), metadata={"level": "1"}),
            pa.field("名前", pa.string()),
            pa.field("", pa.int8()),
        ],
        metadata={"origin": "pyarrow-oracle", "empty": "", "json": '{"a": [1, 2]}'},
    )
    batch = pa.record_batch(
        [
            pa.array([1, 2, 3], pa.int32()),
            pa.array([{"child": "a"}, None, {"child": "c"}], schema.field("nested").type),
            pa.array(["x", None, "z"]),
            pa.array([1, 2, None], pa.int8()),
        ],
        schema=schema,
    )
    return [Fixture("metadata", "metadata", "schema/field metadata, non-nullable fields, Unicode and empty names", schema, [batch])]


def structure_fixtures() -> list[Fixture]:
    schema = pa.schema([pa.field("i", pa.int64()), pa.field("s", pa.string())])
    batches = [
        pa.record_batch([pa.array([1, 2, 3], pa.int64()), pa.array(["a", None, "c"])], schema=schema),
        pa.record_batch([pa.array([], pa.int64()), pa.array([], pa.string())], schema=schema),
        pa.record_batch([pa.array([None, 5], pa.int64()), pa.array(["é", ""])], schema=schema),
    ]
    zero_col = pa.record_batch({"tmp": pa.array([1, 2, 3])}).select([])
    big = pa.record_batch(
        [pa.array(range(1000), pa.int32()), pa.array([None if i % 7 == 0 else f"row{i}" for i in range(1000)])],
        ["n", "s"],
    )
    return [
        Fixture("structure", "multi_batch", "three batches including an empty middle batch", schema, batches),
        Fixture("structure", "no_batches", "schema only, zero record batches", schema, []),
        Fixture("structure", "zero_rows", "a single zero-row batch", schema, [batches[1]]),
        Fixture(
            "structure",
            "zero_columns",
            "zero columns with three rows",
            zero_col.schema,
            [zero_col],
            notes="Dart may currently reject empty schemas; positive row count must round-trip",
        ),
        Fixture("structure", "thousand_rows", "1000 rows (multi-byte bitmaps, larger buffers)", big.schema, [big]),
    ]


def compression_fixtures() -> list[Fixture]:
    out = []
    for codec in ("lz4", "zstd"):
        batch = pa.record_batch(
            [pa.array([i % 5 for i in range(64)], pa.int32()), pa.array([None if i % 3 == 0 else "x" * (i % 4) for i in range(64)])],
            ["n", "s"],
        )
        out.append(
            Fixture(
                "compression",
                codec,
                f"body compression {codec}",
                batch.schema,
                [batch],
                write_options={"compression": codec},
                optional=True,
            )
        )
    return out


FAMILIES: dict[str, Callable[[], list[Fixture]]] = {
    "primitive": primitive_fixtures,
    "binary": binary_fixtures,
    "temporal": temporal_fixtures,
    "decimal": decimal_fixtures,
    "nested": nested_fixtures,
    "dictionary": dictionary_fixtures,
    "union": union_fixtures,
    "ree": ree_fixtures,
    "extension": extension_fixtures,
    "metadata": metadata_fixtures,
    "structure": structure_fixtures,
    "compression": compression_fixtures,
}


def all_fixtures(only: set[str] | None = None) -> list[Fixture]:
    unregister_extensions()
    out: list[Fixture] = []
    for fam, build in FAMILIES.items():
        if only and fam not in only:
            continue
        out.extend(build())
    return out


# --------------------------------------------------------------------------
# IPC helpers
# --------------------------------------------------------------------------


def write_ipc(fx: Fixture, fmt: str) -> bytes:
    opts = ipc.IpcWriteOptions(**fx.write_options)
    sink = pa.BufferOutputStream()
    opener = ipc.new_file if fmt == "file" else ipc.new_stream
    with opener(sink, fx.schema, options=opts) as w:
        for b in fx.batches:
            w.write_batch(b)
    return sink.getvalue().to_pybytes()


def read_ipc(data: bytes, fmt: str) -> tuple[pa.Schema, list[pa.RecordBatch]]:
    buf = pa.py_buffer(data)
    if fmt == "file":
        r = ipc.open_file(buf)
        batches = [r.get_batch(i) for i in range(r.num_record_batches)]
        schema = r.schema
    else:
        r = ipc.open_stream(buf)
        batches = list(r)
        schema = r.schema
    for b in batches:
        b.validate(full=True)
    return schema, batches


def _dump_json(obj: Any) -> str:
    return json.dumps(obj, ensure_ascii=False, indent=1, sort_keys=False) + "\n"


# --------------------------------------------------------------------------
# Commands
# --------------------------------------------------------------------------


def generate(out_dir: Path, only: set[str] | None = None) -> list[str]:
    fixtures = all_fixtures(only)
    manifest: dict[str, Any] = {
        "format_version": FORMAT_VERSION,
        "generator": "tool/conformance/arrow_ipc_interop.py",
        "pyarrow_version": pa.__version__,
        "value_encoding": "see tool/conformance/arrow_ipc_interop.py module docstring",
        "fixtures": [],
    }
    written = []
    for fx in fixtures:
        fam_dir = out_dir / fx.family
        fam_dir.mkdir(parents=True, exist_ok=True)
        files = {}
        summary = None
        for fmt in fx.formats:
            data = write_ipc(fx, fmt)
            path = fam_dir / f"{fx.name}{FORMATS[fmt]}"
            path.write_bytes(data)
            written.append(str(path.relative_to(out_dir)))
            files[fmt] = path.name
            schema, batches = read_ipc(data, fmt)
            s = summarize(batches, schema)
            if summary is None:
                summary = s
            elif s != summary:
                raise InteropError(f"{fx.key}: file/stream readback disagree")
        assert summary is not None
        if summary != summarize(fx.batches, fx.schema):
            raise InteropError(f"{fx.key}: PyArrow readback differs from source")
        expectation = {
            "family": fx.family,
            "name": fx.name,
            "description": fx.description,
            "files": files,
            "write_options": fx.write_options,
            "optional": fx.optional,
            **({"notes": fx.notes} if fx.notes else {}),
            **summary,
        }
        exp_path = fam_dir / f"{fx.name}.json"
        exp_path.write_text(_dump_json(expectation), encoding="utf-8")
        written.append(str(exp_path.relative_to(out_dir)))
        manifest["fixtures"].append(
            {
                "family": fx.family,
                "name": fx.name,
                "formats": list(fx.formats),
                "expectation": f"{fx.family}/{fx.name}.json",
                "optional": fx.optional,
            }
        )
    if not only:
        (out_dir / "manifest.json").write_text(_dump_json(manifest), encoding="utf-8")
        written.append("manifest.json")
    return written


def check(fixtures_dir: Path) -> list[str]:
    problems = []
    with tempfile.TemporaryDirectory() as tmp:
        tmp_dir = Path(tmp)
        for rel in generate(tmp_dir):
            committed = fixtures_dir / rel
            if not committed.exists():
                problems.append(f"missing committed fixture: {rel}")
            elif not filecmp.cmp(committed, tmp_dir / rel, shallow=False):
                problems.append(f"stale fixture (regenerate): {rel}")
        expected = {p.relative_to(tmp_dir) for p in tmp_dir.rglob("*") if p.is_file()}
        for p in fixtures_dir.rglob("*"):
            if p.is_file() and p.relative_to(fixtures_dir) not in expected and p.name != "README.md":
                problems.append(f"unexpected file: {p.relative_to(fixtures_dir)}")
    return problems


def _diff(path: str, a: Any, b: Any, out: list[str], limit: int = 20) -> None:
    if len(out) >= limit:
        return
    if isinstance(a, dict) and isinstance(b, dict):
        for k in sorted(set(a) | set(b), key=str):
            if k not in a:
                out.append(f"{path}.{k}: unexpected {json.dumps(b[k], ensure_ascii=False)[:120]}")
            elif k not in b:
                out.append(f"{path}.{k}: missing (expected {json.dumps(a[k], ensure_ascii=False)[:120]})")
            else:
                _diff(f"{path}.{k}", a[k], b[k], out, limit)
    elif isinstance(a, list) and isinstance(b, list):
        if len(a) != len(b):
            out.append(f"{path}: length {len(b)} != expected {len(a)}")
        for i, (x, y) in enumerate(zip(a, b)):
            _diff(f"{path}[{i}]", x, y, out, limit)
    elif a != b or type(a) is not type(b):
        out.append(
            f"{path}: got {json.dumps(b, ensure_ascii=False)[:120]} expected {json.dumps(a, ensure_ascii=False)[:120]}"
        )


_COMPARED = ("schema", "num_rows", "batch_row_counts", "columns")


def verify_file(expectation: dict[str, Any], data: bytes, fmt: str, strict_batches: bool) -> list[str]:
    try:
        schema, batches = read_ipc(data, fmt)
        got = summarize(batches, schema)
    except Exception as e:  # noqa: BLE001 - report any reader failure
        return [f"PyArrow failed to read/validate: {type(e).__name__}: {e}"]
    exp = {k: expectation[k] for k in _COMPARED}
    if not strict_batches:
        exp.pop("batch_row_counts")
        got.pop("batch_row_counts")
        for col in exp["columns"]:
            col.pop("dictionary", None)
        for col in got["columns"]:
            col.pop("dictionary", None)
    out: list[str] = []
    _diff("", exp, {k: got[k] for k in exp}, out)
    return out


def verify(
    fixtures_dir: Path,
    output_dir: Path,
    require_all: bool,
    only: set[str] | None,
    strict_batches: bool,
) -> dict[str, Any]:
    unregister_extensions()
    manifest = json.loads((fixtures_dir / "manifest.json").read_text(encoding="utf-8"))
    results: dict[str, Any] = {"passed": [], "failed": {}, "missing": [], "extra": []}
    known = set()
    for entry in manifest["fixtures"]:
        if only and entry["family"] not in only:
            continue
        expectation = json.loads((fixtures_dir / entry["expectation"]).read_text(encoding="utf-8"))
        for fmt in entry["formats"]:
            rel = f"{entry['family']}/{entry['name']}{FORMATS[fmt]}"
            known.add(rel)
            path = output_dir / rel
            if not path.exists():
                if not entry.get("optional"):
                    results["missing"].append(rel)
                continue
            problems = verify_file(expectation, path.read_bytes(), fmt, strict_batches)
            if problems:
                results["failed"][rel] = problems
            else:
                results["passed"].append(rel)
    for p in sorted(output_dir.rglob("*")):
        rel = str(p.relative_to(output_dir))
        if p.is_file() and p.suffix in (".arrow", ".arrows") and rel not in known:
            results["extra"].append(rel)
    results["ok"] = not results["failed"] and not (require_all and results["missing"])
    return results


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    g = sub.add_parser("generate", help="write committed fixtures")
    g.add_argument("--out", type=Path, default=DEFAULT_FIXTURES)
    c = sub.add_parser("check", help="require committed fixtures to be up to date")
    c.add_argument("--fixtures", type=Path, default=DEFAULT_FIXTURES)
    v = sub.add_parser("verify", help="verify IPC files written by another implementation")
    v.add_argument("--fixtures", type=Path, default=DEFAULT_FIXTURES)
    grp = v.add_mutually_exclusive_group(required=True)
    grp.add_argument("--output", type=Path, help="directory mirroring <family>/<name>.arrow|.arrows")
    grp.add_argument("--self-test", action="store_true", help="verify committed fixtures (oracle sanity)")
    v.add_argument("--require-all", action="store_true", help="fail when a non-optional fixture is missing")
    v.add_argument("--only", action="append", help="restrict to family (repeatable)")
    v.add_argument(
        "--loose-batches",
        action="store_true",
        help="ignore batch boundaries and physical dictionary layout (logical values only)",
    )
    v.add_argument("--json", action="store_true", help="print machine-readable report")
    args = parser.parse_args(argv)

    if args.command == "generate":
        if any(args.out.glob("*/*")):
            for p in args.out.rglob("*"):
                if p.is_file() and p.suffix in (".arrow", ".arrows", ".json"):
                    p.unlink()
        written = generate(args.out)
        print(f"wrote {len(written)} files to {args.out} with pyarrow {pa.__version__}")
        return 0
    if args.command == "check":
        problems = check(args.fixtures)
        for p in problems:
            print(p)
        print("fixtures up to date" if not problems else f"{len(problems)} problem(s)")
        return 1 if problems else 0
    output = args.fixtures if args.self_test else args.output
    results = verify(
        args.fixtures,
        output,
        args.require_all or args.self_test,
        set(args.only) if args.only else None,
        not args.loose_batches,
    )
    if args.json:
        print(json.dumps(results, ensure_ascii=False, indent=1))
    else:
        for rel in results["passed"]:
            print(f"PASS {rel}")
        for rel, problems in results["failed"].items():
            print(f"FAIL {rel}")
            for p in problems:
                print(f"     {p}")
        for rel in results["missing"]:
            print(f"MISSING {rel}")
        for rel in results["extra"]:
            print(f"EXTRA {rel} (no expectation)")
        print(
            f"{len(results['passed'])} passed, {len(results['failed'])} failed, "
            f"{len(results['missing'])} missing"
        )
    return 0 if results["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
