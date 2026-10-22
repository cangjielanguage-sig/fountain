"""版本号一致性检查"""
import re
from pathlib import Path


def run(skill_path: Path, config: dict) -> dict:
    """检查版本号在各文件中是否一致"""
    check_config = config.get("version_check", {})
    if not check_config.get("enabled", True):
        return {"name": "版本号一致性检查", "status": "SKIP", "details": "已禁用"}

    version_file = check_config.get("version_file", "references/VERSION.txt")
    files_to_check = check_config.get("files_to_check", ["SKILL.md"])
    pattern_template = check_config.get("pattern", "v{VERSION}")

    # 读取版本号文件
    vf = skill_path / version_file
    if not vf.exists():
        return {
            "name": "版本号一致性检查",
            "status": "FAIL",
            "details": f"版本号文件不存在: {version_file}",
        }

    version = vf.read_text(encoding="utf-8").strip()
    expected = pattern_template.replace("{VERSION}", version)

    mismatches = []
    for fname in files_to_check:
        fpath = skill_path / fname
        if not fpath.exists():
            mismatches.append(f"❌ {fname}: 文件不存在")
            continue
        content = fpath.read_text(encoding="utf-8")
        if expected not in content:
            # 尝试模糊匹配
            if version not in content:
                mismatches.append(f"❌ {fname}: 未找到版本号 {version}")
            else:
                mismatches.append(f"⚠️ {fname}: 找到版本号但格式不匹配 {expected}")
        else:
            mismatches.append(f"✅ {fname}: 版本号一致 ({version})")

    if any(m.startswith("❌") for m in mismatches):
        return {
            "name": "版本号一致性检查",
            "status": "FAIL",
            "details": "\n".join(mismatches),
        }
    return {
        "name": "版本号一致性检查",
        "status": "PASS",
        "details": f"版本号: {version}\n" + "\n".join(mismatches),
    }
