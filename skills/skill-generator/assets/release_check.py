#!/usr/bin/env python3
"""
skill-generator 轻量版 — 单文件收口脚本
用法:
    cd /path/to/your/skill
    python3 scripts/release_check.py

功能:
    1. 版本号一致性检查
    2. 代码语法检查
    3. 安全检查（裸except/secret/eval/rm-rf）
    4. 跨平台兼容性扫描
    5. ZIP 打包（全新打包，禁止增量更新）
    6. ZIP 结构验证（ASCII文件名/SKILL.md根目录）

零依赖，纯 Python 标准库，跨平台兼容。
"""

import os
import sys
import re
import json
import py_compile
import zipfile
import tempfile
import shutil
from pathlib import Path

# === 配置区（按需修改） ===
SKILL_NAME = "你的skill名称"  # 修改为你的 skill 名称
VERSION_FILE = "references/VERSION.txt"
SCRIPTS_GLOB = "scripts/*.py"
# =========================

SKILL_PATH = Path(__file__).parent.parent.resolve()
# 本脚本自身的规则表里写着各种危险模式与平台专属 API，扫描时必须跳过自己
SELF_PATH = Path(__file__).resolve()


def log(title, status, details=""):
    icon = "✅" if status == "PASS" else "❌" if status == "FAIL" else "⏸️"
    print(f"\n{icon} {title}")
    if details:
        for line in details.split("\n"):
            print(f"   {line}")
    return status == "PASS"


def check_version():
    """检查版本号一致性"""
    vf = SKILL_PATH / VERSION_FILE
    if not vf.exists():
        return log("版本号检查", "FAIL", f"版本号文件不存在: {VERSION_FILE}")

    version = vf.read_text(encoding="utf-8").strip()
    files = ["SKILL.md", "CHANGELOG.md"]
    mismatches = []

    for fname in files:
        fpath = SKILL_PATH / fname
        if fpath.exists():
            content = fpath.read_text(encoding="utf-8", errors="ignore")
            if version not in content:
                mismatches.append(f"❌ {fname}: 未找到版本号 {version}")
            else:
                mismatches.append(f"✅ {fname}: 版本号一致")

    if any(m.startswith("❌") for m in mismatches):
        return log("版本号检查", "FAIL", "\n".join(mismatches))
    return log("版本号检查", "PASS", f"版本号: {version}\n" + "\n".join(mismatches))


def check_syntax():
    """代码语法检查"""
    py_files = list(SKILL_PATH.glob(SCRIPTS_GLOB))
    errors = []
    for f in py_files:
        try:
            py_compile.compile(str(f), doraise=True)
        except py_compile.PyCompileError as e:
            errors.append(f"❌ {f.name}: {e}")

    if errors:
        return log("语法检查", "FAIL", "\n".join(errors))
    return log("语法检查", "PASS", f"{len(py_files)} 个脚本全部通过")


def check_security():
    """安全检查"""
    checks = {
        "裸except": (r"except:", "scripts/*.py", 0),
        "硬编码secret": (r'"app_secret"\s*:\s*"[^"]+"', "scripts/*.py references/data/*.json", 0),
        "eval/exec": (r"\beval\b|\bexec\b", "scripts/*.py", 0),
        "rm -rf": (r"rm -rf", "scripts/* assets/* references/*", 0),
    }

    results = []
    all_ok = True
    for name, (pattern, glob, expected) in checks.items():
        matches = []
        for gp in glob.split():
            for f in SKILL_PATH.glob(gp):
                if not f.is_file() or f.resolve() == SELF_PATH:
                    continue
                try:
                    content = f.read_text(encoding="utf-8", errors="ignore")
                    for i, line in enumerate(content.split("\n"), 1):
                        if re.search(pattern, line):
                            if name == "硬编码secret" and '""' in line:
                                continue
                            matches.append(f"  {f.relative_to(SKILL_PATH)}:{i}")
                except Exception:
                    continue

        if len(matches) != expected:
            all_ok = False
            results.append(f"❌ {name}: {len(matches)} 处 (期望 {expected})")
            results.extend(matches[:3])
        else:
            results.append(f"✅ {name}: {len(matches)} 处")

    status = "PASS" if all_ok else "FAIL"
    return log("安全检查", status, "\n".join(results))


def check_compatibility():
    """跨平台兼容性检查"""
    checks = {
        "硬编码路径": (r"'/tmp/'|/tmp/|/Users/|/home/|C:\\\\Users", "scripts/*.py", 0),
        "Unix命令": (r"os\.system|subprocess\.run|subprocess\.call", "scripts/*.py", 0),
        "macOS专属": (r"osascript|CoreFoundation|AppKit", "scripts/*.py", 0),
        "Python3.9+": (r"dict\||list\||tuple\||set\|", "scripts/*.py", 0),
    }

    results = []
    all_ok = True
    for name, (pattern, glob, expected) in checks.items():
        matches = []
        for f in SKILL_PATH.glob(glob):
            if not f.is_file() or f.resolve() == SELF_PATH:
                continue
            try:
                content = f.read_text(encoding="utf-8", errors="ignore")
                for line in content.split("\n"):
                    if re.search(pattern, line):
                        if "python3" in line or "sys.executable" in line or "py_compile" in line:
                            continue
                        matches.append(f"  {f.name}: {line.strip()[:60]}")
            except Exception:
                continue

        if len(matches) != expected:
            all_ok = False
            results.append(f"❌ {name}: {len(matches)} 处")
            results.extend(matches[:3])
        else:
            results.append(f"✅ {name}: {len(matches)} 处")

    # ASCII 文件名
    non_ascii = []
    for f in SKILL_PATH.rglob("*"):
        try:
            f.name.encode("ascii")
        except UnicodeEncodeError:
            non_ascii.append(str(f.relative_to(SKILL_PATH)))
    if non_ascii:
        all_ok = False
        results.append(f"❌ 非ASCII文件名: {len(non_ascii)} 个")
        results.extend([f"  {n}" for n in non_ascii[:5]])
    else:
        results.append("✅ ASCII文件名: 全部通过")

    status = "PASS" if all_ok else "FAIL"
    return log("兼容性检查", status, "\n".join(results))


def check_zip():
    """ZIP 打包与验证"""
    zip_name = f"{SKILL_NAME}.zip"
    zip_path = SKILL_PATH.parent / zip_name

    # 删除旧 zip
    if zip_path.exists():
        zip_path.unlink()

    results = []

    # 打包
    try:
        with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zf:
            for root, dirs, files in os.walk(SKILL_PATH):
                dirs[:] = [d for d in dirs if d != "__pycache__" and not d.startswith(".")]
                for file in files:
                    if file.endswith(".zip") or file == ".DS_Store" or file.endswith(".pyc"):
                        continue
                    full = Path(root) / file
                    rel = full.relative_to(SKILL_PATH)
                    zf.write(full, rel)
        results.append(f"✅ 打包完成: {zip_path}")
    except Exception as e:
        return log("ZIP打包", "FAIL", f"打包失败: {e}")

    # 验证
    try:
        with zipfile.ZipFile(zip_path, "r") as zf:
            names = [i.filename for i in zf.infolist()]

            if "SKILL.md" in names:
                results.append("✅ SKILL.md 在根目录")
            else:
                results.append("❌ SKILL.md 不在根目录")

            non_ascii = []
            for name in names:
                try:
                    name.encode("ascii")
                except UnicodeEncodeError:
                    non_ascii.append(name)
            if non_ascii:
                results.append(f"❌ 非ASCII文件名: {len(non_ascii)} 个")
            else:
                results.append("✅ 全部文件名 ASCII 兼容")

            size_kb = zip_path.stat().st_size / 1024
            results.append(f"📦 包大小: {size_kb:.1f} KB")
    except Exception as e:
        results.append(f"❌ zip验证失败: {e}")

    has_fail = any(r.startswith("❌") for r in results)
    status = "FAIL" if has_fail else "PASS"
    return log("ZIP打包", status, "\n".join(results))


def main():
    print(f"\n{'='*60}")
    print(f"  🔧 {SKILL_NAME} 收口检查（轻量版）")
    print(f"{'='*60}")
    print(f"  Skill路径: {SKILL_PATH}")

    results = [
        check_version(),
        check_syntax(),
        check_security(),
        check_compatibility(),
        check_zip(),
    ]

    passed = sum(results)
    total = len(results)

    print(f"\n{'='*60}")
    print(f"  结果: ✅通过 {passed}/{total}")
    print(f"{'='*60}")

    if passed == total:
        print("\n🎉 全部通过，可以分发！")
        return 0
    else:
        print(f"\n⚠️  有 {total - passed} 项未通过，请修复后重新运行")
        return 1


if __name__ == "__main__":
    sys.exit(main())
