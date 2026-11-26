#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成 f_rule XLSX 决策表夹具（`doc/07-decision-table.md` §6）。

产物（相对本脚本所在仓库布局）：

- ``src/fixtures/pricing.xlsx``      —— 与 ``pricing.csv`` 等价的单表工作簿（T-12）
- ``src/fixtures/pricing_large.xlsx`` —— 10 万行单表工作簿（T-14）

用法（在 f_rule 目录下）::

    python3 doc/tools/gen_fixtures.py

依赖：openpyxl 3.1.5（本仓库夹具生成与融合侧一致）。
"""

from __future__ import annotations

import os
import sys
from typing import List

try:
    from openpyxl import Workbook
except ImportError:  # pragma: no cover - 环境缺依赖时给出明确提示
    sys.stderr.write("需要 openpyxl：pip install 'openpyxl==3.1.5'\n")
    raise SystemExit(1)

EXPECTED_OPENPYXL = "3.1.5"

#: 夹具输出目录：脚本位于 ``<pkg>/doc/tools/``，夹具在 ``<pkg>/src/fixtures/``
PKG_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
FIXTURE_DIR = os.path.join(PKG_ROOT, "src", "fixtures")

#: pricing.xlsx 与 pricing.csv 共用同一份内容（T-12 等价性）
PRICING_META = [
    ("key", "value"),
    ("id", "pricing"),
    ("name", "订单折扣"),
    ("version", "v1"),
    ("factSpace", "orders"),
    ("hitPolicy", "First"),
    ("salience", "100"),
]

PRICING_HEADER = [
    "id",
    "name",
    "when.order.level",
    "when.order.amount",
    "then.discount",
    "then.event",
]

#: ``>=3`` / ``>200`` 是条件文本，必须写成文本单元格；折扣是真正的数字单元格
PRICING_ROWS = [
    ["R1", "VIP 大额", ">=3", ">200", 0.85, "order.discounted"],
    ["R2", "普通大额", ">=1", ">500", 0.90, "order.discounted"],
    ["R3", "兜底", None, None, 1.0, "order.discounted"],
]

LARGE_ROWS = 100_000


def _write_meta(workbook: Workbook, rows: List[tuple]) -> None:
    """写入 hidden 的 ``_meta`` sheet（key/value 两列）。"""
    meta = workbook.create_sheet("_meta")
    for row in rows:
        meta.append(list(row))
    meta.sheet_state = "hidden"


def build_pricing(path: str) -> None:
    workbook = Workbook()
    sheet = workbook.active
    sheet.title = "pricing"
    sheet.append(PRICING_HEADER)
    for row in PRICING_ROWS:
        sheet.append(row)
    _write_meta(workbook, PRICING_META)
    workbook.save(path)


def build_pricing_large(path: str) -> None:
    """10 万行：``level`` 在 0..4 之间轮转，``amount`` 即行号，折扣固定 0.9。"""
    workbook = Workbook(write_only=True)
    sheet = workbook.create_sheet("pricing_large")
    sheet.append(["id", "when.order.level", "when.order.amount", "then.discount"])
    for index in range(LARGE_ROWS):
        sheet.append(["L{}".format(index + 1), index % 5, index, 0.9])
    _write_meta(
        workbook,
        [
            ("key", "value"),
            ("id", "pricing_large"),
            ("version", "v1"),
            ("factSpace", "orders"),
            ("hitPolicy", "First"),
            ("salience", "0"),
        ],
    )
    workbook.save(path)


def main() -> int:
    import openpyxl

    if openpyxl.__version__ != EXPECTED_OPENPYXL:
        sys.stderr.write(
            "警告：本仓库夹具由 openpyxl {} 生成，当前是 {}\n".format(
                EXPECTED_OPENPYXL, openpyxl.__version__
            )
        )
    os.makedirs(FIXTURE_DIR, exist_ok=True)
    pricing = os.path.join(FIXTURE_DIR, "pricing.xlsx")
    large = os.path.join(FIXTURE_DIR, "pricing_large.xlsx")
    build_pricing(pricing)
    print("生成 {}".format(pricing))
    build_pricing_large(large)
    print("生成 {}（{} 行）".format(large, LARGE_ROWS))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
