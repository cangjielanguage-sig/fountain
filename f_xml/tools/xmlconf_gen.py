#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""xmlconf 20130923 套件的下载 / 校验 / 展平脚本。

唯一入口：把 W3C XML Conformance Test Suite（xmlts20130923.tar.gz）整理成两份
**派生清单**，供 `f_xml` 的 `XmlconfHarness_test` 直接读取：

    <cache>/cases.json        可跑集（不含 unsupported）
    <cache>/unsupported.json  被排除的用例与原因
    <cache>/suite/...         解压后的套件本体

缓存目录固定为 `f_xml/.cache/xmlconf/`（仓库根 `.gitignore` 的 `.cache/` 规则覆盖），
可用环境变量 `F_XML_XMLCONF_CACHE` 覆盖。**套件与派生 JSON 一律不入库**。

判定口径（与 `design.md` §9.1 对齐）：

1. `EDITION` 是集合：只要包含 `1`/`2`/`3`/`4` 中任意一个就排除——
   第 5 版改了 `Char` 产生式，我们要验的是 1.0 第 5 版。
2. 测试文件里出现 `<!ENTITY … SYSTEM|PUBLIC …>` 的用例排除：外部实体引用即报错，
   这不是「跑不过」，而是设计边界。
3. `TYPE` 只决定期望：`valid` / `invalid` 期望解析成功（`invalid` 是良构但不合 DTD，
   我们不校验 DTD），`not-wf` 期望抛错，`error` 不判定。

用法：

    python3 f_xml/tools/xmlconf_gen.py              # 缺缓存就下载，有缓存就复用
    python3 f_xml/tools/xmlconf_gen.py --offline    # 只用缓存；缺失则非 0 退出
    python3 f_xml/tools/xmlconf_gen.py --force      # 重新下载
"""

import argparse
import hashlib
import json
import os
import re
import shutil
import sys
import tarfile
import urllib.request

SUITE_URL = "https://www.w3.org/XML/Test/xmlts20130923.tar.gz"
SUITE_SHA256 = "9b61db9f5dbffa545f4b8d78422167083a8568c59bd1129f94138f936cf6fc1f"
SUITE_VERSION = "20130923"

HERE = os.path.dirname(os.path.abspath(__file__))
MODULE_ROOT = os.path.dirname(HERE)

MISSING_HINT = (
    "xmlconf 缓存缺失：请先运行 python3 f_xml/tools/xmlconf_gen.py"
    "（离线环境请把已生成的缓存放到 F_XML_XMLCONF_CACHE）"
)


def cache_root() -> str:
    override = os.environ.get("F_XML_XMLCONF_CACHE")
    if override:
        return os.path.abspath(override)
    return os.path.join(MODULE_ROOT, ".cache", "xmlconf")


def sha256_of(path: str) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def download(cache: str, force: bool) -> str:
    download_dir = os.path.join(cache, "download")
    os.makedirs(download_dir, exist_ok=True)
    archive = os.path.join(download_dir, "xmlts20130923.tar.gz")
    if force or not os.path.exists(archive):
        print("下载 %s" % SUITE_URL)
        with urllib.request.urlopen(SUITE_URL, timeout=120) as response:
            data = response.read()
        with open(archive, "wb") as handle:
            handle.write(data)
    actual = sha256_of(archive)
    if actual != SUITE_SHA256:
        sys.stderr.write("SHA-256 不匹配\n  期望: %s\n  实际: %s\n" % (SUITE_SHA256, actual))
        sys.exit(2)
    return archive


def extract(cache: str, archive: str, force: bool) -> str:
    suite = os.path.join(cache, "suite")
    marker = os.path.join(suite, "xmlconf", "xmlconf.xml")
    if force and os.path.isdir(suite):
        shutil.rmtree(suite)
    if not os.path.exists(marker):
        os.makedirs(suite, exist_ok=True)
        with tarfile.open(archive, "r:gz") as tar:
            members = [m for m in tar.getmembers() if m.isreg() or m.isdir()]
            # W3C 的包带只读权限位，直接 extractall 会在部分文件系统上报 utime 错误。
            for member in members:
                tar.extract(member, suite)
    return suite


ENTITY_SYSTEM = re.compile(r"<!ENTITY\s+%?\s*[\w.:-]+\s+(?:SYSTEM|PUBLIC)\s+['\"]([^'\"]+)['\"]")
TEST_TAG = re.compile(r"<TEST\b([^>]*)>", re.S | re.I)
ATTR = re.compile(r"([\w.:-]+)\s*=\s*(?:\"([^\"]*)\"|'([^']*)')")


def parse_attrs(text: str) -> dict:
    attrs = {}
    for match in ATTR.finditer(text):
        key = match.group(1).upper()
        value = match.group(2) if match.group(2) is not None else match.group(3)
        attrs[key] = value
    return attrs


def catalog_system_refs(path: str) -> list:
    """catalog 用外部实体引入子 catalog；我们自己解析，不经过 XML 解析器。"""
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        content = handle.read()
    refs = []
    base = os.path.dirname(path)
    for match in ENTITY_SYSTEM.finditer(content):
        refs.append(os.path.normpath(os.path.join(base, match.group(1))))
    return refs


def walk_catalogs(root_catalog: str) -> list:
    seen = []
    stack = [os.path.normpath(root_catalog)]
    while stack:
        current = stack.pop(0)
        if current in seen or not os.path.exists(current):
            continue
        seen.append(current)
        stack.extend(catalog_system_refs(current))
    return seen


def file_has_external_entity(path: str) -> bool:
    """测试文件是否声明了外部实体（`SYSTEM` / `PUBLIC`）。注释里的声明不算。"""
    if not os.path.exists(path):
        return False
    try:
        with open(path, "rb") as handle:
            data = handle.read()
    except OSError:
        return False
    text = data.decode("utf-8", errors="replace")
    text = re.sub(r"<!--.*?-->", "", text, flags=re.S)
    return re.search(r"<!ENTITY\s+%?\s*[\w.:-]+\s+(?:SYSTEM|PUBLIC)\b", text) is not None


def edition_excluded(edition: str) -> bool:
    if not edition:
        return False
    tokens = [t for t in re.split(r"[\s,]+", edition.strip()) if t]
    return any(t in ("1", "2", "3", "4") for t in tokens)


def collect(suite: str) -> tuple:
    root_catalog = os.path.join(suite, "xmlconf", "xmlconf.xml")
    catalogs = walk_catalogs(root_catalog)
    cases = []
    unsupported = []
    for catalog in catalogs:
        with open(catalog, "r", encoding="utf-8", errors="replace") as handle:
            content = handle.read()
        base = os.path.dirname(catalog)
        for match in TEST_TAG.finditer(content):
            attrs = parse_attrs(match.group(1))
            test_id = attrs.get("ID")
            uri = attrs.get("URI")
            if not test_id or not uri:
                continue
            absolute = os.path.normpath(os.path.join(base, uri))
            relative = os.path.relpath(absolute, suite).replace(os.sep, "/")
            edition = attrs.get("EDITION", "")
            entry = {
                "id": test_id,
                "type": attrs.get("TYPE", "").lower(),
                "uri": relative,
                "edition": edition or None,
                "entities": attrs.get("ENTITIES", "none") or "none",
                "sections": attrs.get("SECTIONS", ""),
            }
            if edition_excluded(edition):
                unsupported.append({"id": test_id, "reason": "edition"})
                continue
            # 只有「实体用例」才受外部实体规则影响：声明了 SYSTEM/PUBLIC 的实体永不加载，
            # 这些用例不是跑不过，而是踩在设计边界上。非实体用例即便文件里出现外部实体声明
            # （例如只用来做 DTD 校验的 ATTLIST），解析路径也不会走到它。
            if entry["entities"] != "none" and file_has_external_entity(absolute):
                unsupported.append({"id": test_id, "reason": "external-entity"})
                continue
            cases.append(entry)
    cases.sort(key=lambda c: c["id"])
    unsupported.sort(key=lambda c: c["id"])
    return cases, unsupported, len(catalogs)


def write_json(path: str, payload) -> None:
    with open(path, "w", encoding="utf-8", newline="\n") as handle:
        json.dump(payload, handle, ensure_ascii=False, indent=2, sort_keys=False)
        handle.write("\n")


def write_markdown(path: str, unsupported: list, stats: dict) -> None:
    lines = []
    lines.append("# xmlconf 20130923 不支持清单")
    lines.append("")
    lines.append("> 由 `f_xml/tools/xmlconf_gen.py` 生成，**不要手改**。")
    lines.append(">")
    lines.append("> 口径：`EDITION` 含 1/2/3/4（第 5 版改了 `Char` 产生式）；或测试文件里出现外部实体声明")
    lines.append("> （`SYSTEM` / `PUBLIC`）——外部实体与外部子集永不加载，这是设计边界，不是缺陷。")
    lines.append("")
    lines.append("## 统计")
    lines.append("")
    lines.append("| 项 | 数量 |")
    lines.append("|---|---|")
    lines.append("| 套件用例总数 | %d |" % stats["total"])
    lines.append("| 不可跑（本清单） | %d |" % stats["unsupported"])
    lines.append("| 可跑集 | %d |" % stats["runnable"])
    lines.append("| 参与判定的断言 | %d |" % stats["assertions"])
    lines.append("")
    lines.append("按 `TYPE`：")
    lines.append("")
    for key in ("valid", "invalid", "not-wf", "error"):
        lines.append("- `%s`：%d" % (key, stats["types"].get(key, 0)))
    lines.append("")
    lines.append("## 清单")
    lines.append("")
    lines.append("| # | ID | 原因 |")
    lines.append("|---|---|---|")
    for index, item in enumerate(unsupported, start=1):
        lines.append("| %d | `%s` | %s |" % (index, item["id"], item["reason"]))
    lines.append("")
    with open(path, "w", encoding="utf-8", newline="\n") as handle:
        handle.write("\n".join(lines))


def main() -> int:
    parser = argparse.ArgumentParser(description="生成 xmlconf 缓存（cases.json / unsupported.json）")
    parser.add_argument("--offline", action="store_true", help="只用缓存，不联网")
    parser.add_argument("--force", action="store_true", help="重新下载并解压")
    args = parser.parse_args()

    cache = cache_root()
    archive = os.path.join(cache, "download", "xmlts20130923.tar.gz")
    suite = os.path.join(cache, "suite")

    if args.offline:
        if not os.path.exists(archive) and not os.path.isdir(suite):
            sys.stderr.write(MISSING_HINT + "\n")
            return 3
    else:
        archive = download(cache, args.force)

    if os.path.exists(archive):
        actual = sha256_of(archive)
        if actual != SUITE_SHA256:
            sys.stderr.write("SHA-256 不匹配\n  期望: %s\n  实际: %s\n" % (SUITE_SHA256, actual))
            return 2
        suite = extract(cache, archive, args.force)

    cases_path = os.path.join(cache, "cases.json")
    unsupported_path = os.path.join(cache, "unsupported.json")
    if not os.path.exists(os.path.join(suite, "xmlconf", "xmlconf.xml")):
        sys.stderr.write(MISSING_HINT + "\n")
        return 3

    cases, unsupported, catalog_count = collect(suite)
    write_json(cases_path, cases)
    write_json(unsupported_path, unsupported)

    types = {}
    for case in cases:
        types[case["type"]] = types.get(case["type"], 0) + 1
    assertions = len([c for c in cases if c["type"] != "error"])
    stats = {
        "total": len(cases) + len(unsupported),
        "unsupported": len(unsupported),
        "runnable": len(cases),
        "assertions": assertions,
        "types": types,
    }
    doc = os.path.join(MODULE_ROOT, "doc", "xmlconf-unsupported.md")
    os.makedirs(os.path.dirname(doc), exist_ok=True)
    write_markdown(doc, unsupported, stats)

    print("套件版本: %s" % SUITE_VERSION)
    print("解析 catalog 数: %d" % catalog_count)
    print("总用例: %d  不可跑: %d  可跑: %d  断言: %d" %
          (stats["total"], stats["unsupported"], stats["runnable"], stats["assertions"]))
    print("按 TYPE: " + ", ".join("%s=%d" % (k, v) for k, v in sorted(types.items())))
    print("输出: %s" % cases_path)
    print("输出: %s" % unsupported_path)
    print("输出: %s" % doc)
    return 0


if __name__ == "__main__":
    sys.exit(main())
