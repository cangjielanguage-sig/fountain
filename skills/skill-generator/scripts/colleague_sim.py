"""同事审查模拟"""
import zipfile
import tempfile
import shutil
import os
import re
import subprocess
import sys
import json
from pathlib import Path

# 检查模块文件名（自检时排除自身，其中包含规则描述是正常的）
_CHECK_MODULE_NAMES = {
    "colleague_sim.py", "compatibility_check.py", "security_check.py",
    "smoke_test.py", "syntax_check.py", "trace_eval.py",
    "version_check.py", "zip_pack.py",
}


def run(skill_path: Path, config: dict) -> dict:
    """模拟同事用外部工具导入和审查"""
    check_config = config.get("colleague_sim", {})
    if not check_config.get("enabled", True):
        return {"name": "同事审查模拟", "status": "SKIP", "details": "已禁用"}

    checks = check_config.get("checks", {})
    results = []
    all_pass = True

    # 找 zip 文件
    name = config.get("name", skill_path.name)
    zip_name = config.get("zip_pack", {}).get("output_name", "{name}.zip").replace("{name}", name)
    zip_path = skill_path.parent / zip_name

    if not zip_path.exists():
        return {
            "name": "同事审查模拟",
            "status": "FAIL",
            "details": f"找不到打包文件: {zip_path}\n请先执行 zip_pack 步骤",
        }

    # 创建临时目录解压
    tmpdir = Path(tempfile.mkdtemp())
    try:
        with zipfile.ZipFile(zip_path, "r") as zf:
            zf.extractall(tmpdir)

        # 1. ZIP 解压验证
        if checks.get("zip_extract", True):
            extracted_files = list(tmpdir.rglob("*"))
            file_count = len([f for f in extracted_files if f.is_file()])
            results.append(f"✅ ZIP解压: {file_count} 个文件")

        # 2. 文件纯净性
        purity = checks.get("file_purity", {})
        if purity:
            forbidden = purity.get("forbidden_keywords", [])
            found_bad = []
            for root, dirs, files in os.walk(tmpdir):
                for fname in files:
                    fpath = Path(root) / fname
                    rel = str(fpath.relative_to(tmpdir))
                    # 排除配置文件和检查模块（其中包含规则描述是正常的）
                    if fname == ".release-config.json" or "release-config" in fname:
                        continue
                    if fname in _CHECK_MODULE_NAMES:
                        continue
                    if fpath.suffix not in [".py", ".json", ".md", ".html", ".txt"]:
                        continue
                    try:
                        content = fpath.read_text(encoding="utf-8", errors="ignore")
                        for kw in forbidden:
                            if kw.lower() in content.lower():
                                found_bad.append(f"  {rel}: 包含 '{kw}'")
                    except Exception:
                        continue
            if found_bad:
                all_pass = False
                results.append(f"❌ 纯净性: 发现 {len(found_bad)} 处敏感内容")
                results.extend(found_bad[:5])
            else:
                results.append("✅ 纯净性: 无敏感内容")

        # 3. Secret 扫描
        if checks.get("secret_scan", True):
            found_secret = False
            for root, dirs, files in os.walk(tmpdir):
                for fname in files:
                    if fname.endswith((".py", ".json", ".html")):
                        fpath = Path(root) / fname
                        try:
                            content = fpath.read_text(encoding="utf-8", errors="ignore")
                            if re.search(r'"app_secret"\s*:\s*"[^"]+"', content):
                                rel = fpath.relative_to(tmpdir)
                                results.append(f"❌ Secret: {rel} 包含硬编码 app_secret")
                                found_secret = True
                        except Exception:
                            continue
            if not found_secret:
                results.append("✅ Secret扫描: 无硬编码")

        # 4. 意图边界测试
        if checks.get("intent_boundary", True):
            mb_script = tmpdir / "scripts" / "material_builder.py"
            if mb_script.exists():
                boundary_tests = [
                    ("帮我审这篇材料", "review"),
                    ("再审", "action"),
                    ("出Word", "action"),
                    ("帮我写材料", "material"),
                ]
                intent_ok = True
                for text, expected in boundary_tests:
                    try:
                        result = subprocess.run(
                            [sys.executable, str(mb_script), "--identify", text],
                            capture_output=True,
                            text=True,
                            timeout=10,
                        )
                        try:
                            data = json.loads(result.stdout)
                            actual = data.get("mode", "unknown")
                            ok = actual == expected or (expected == "action" and data.get("action"))
                            if not ok:
                                intent_ok = False
                                results.append(f"❌ 意图: '{text}' → {actual} (期望 {expected})")
                        except json.JSONDecodeError:
                            intent_ok = False
                            results.append(f"❌ 意图: '{text}' → 解析失败")
                    except Exception as e:
                        intent_ok = False
                        results.append(f"❌ 意图: '{text}' → 执行异常: {e}")
                if intent_ok:
                    results.append("✅ 意图边界: 全部通过")
            else:
                results.append("⏸️ 意图边界: 未找到 material_builder.py")

    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)

    status = "PASS" if all_pass else "FAIL"
    return {
        "name": "同事审查模拟（外部视角）",
        "status": status,
        "details": "\n".join(results),
    }
