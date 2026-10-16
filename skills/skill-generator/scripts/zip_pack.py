"""ZIP 打包检查"""
import zipfile
import os
from pathlib import Path


def run(skill_path: Path, config: dict) -> dict:
    """打包并验证 ZIP 结构"""
    check_config = config.get("zip_pack", {})
    if not check_config.get("enabled", True):
        return {"name": "ZIP打包检查", "status": "SKIP", "details": "已禁用"}

    name = config.get("name", skill_path.name)
    output_name = check_config.get("output_name", "{name}.zip").replace("{name}", name)
    exclude = check_config.get("exclude_patterns", ["*.zip", "*/__pycache__/*"])
    require_ascii = check_config.get("require_ascii_filenames", True)
    require_skill_md = check_config.get("require_skill_md_root", True)

    # 输出路径：和 skill 同级目录
    output_path = skill_path.parent / output_name

    # 删除旧 zip
    if output_path.exists():
        output_path.unlink()

    results = []

    # 打包
    try:
        with zipfile.ZipFile(output_path, "w", zipfile.ZIP_DEFLATED) as zf:
            for root, dirs, files in os.walk(skill_path):
                # 排除 __pycache__
                dirs[:] = [d for d in dirs if d != "__pycache__" and not d.startswith(".")]
                for file in files:
                    # 排除规则
                    skip = False
                    for pat in exclude:
                        if pat.startswith("*"):
                            if file.endswith(pat.lstrip("*")) or file == pat.lstrip("*"):
                                skip = True
                                break
                        if pat in file:
                            skip = True
                            break
                    if skip:
                        continue

                    full = Path(root) / file
                    rel = full.relative_to(skill_path)
                    zf.write(full, rel)

        results.append(f"✅ 打包完成: {output_path}")
    except Exception as e:
        return {
            "name": "ZIP打包检查",
            "status": "FAIL",
            "details": f"打包失败: {e}",
        }

    # 验证 zip 结构
    try:
        with zipfile.ZipFile(output_path, "r") as zf:
            names = [i.filename for i in zf.infolist()]

            # SKILL.md 在根目录
            if require_skill_md:
                if "SKILL.md" in names:
                    results.append("✅ SKILL.md 在 zip 根目录")
                else:
                    results.append("❌ SKILL.md 不在 zip 根目录")

            # 无嵌套根目录
            root_dirs = set(n.split("/")[0] for n in names if "/" in n)
            if len(root_dirs) > 1 or (len(root_dirs) == 1 and list(root_dirs)[0] != ""):
                results.append(f"✅ 目录结构正常 ({len(root_dirs)} 个根目录)")
            else:
                results.append("⚠️ 目录结构: 只有单层")

            # ASCII 文件名
            if require_ascii:
                non_ascii = []
                for name in names:
                    try:
                        name.encode("ascii")
                    except UnicodeEncodeError:
                        non_ascii.append(name)
                if non_ascii:
                    results.append(f"❌ 非ASCII文件名: {len(non_ascii)} 个")
                    results.extend([f"  {n}" for n in non_ascii[:5]])
                else:
                    results.append("✅ 全部文件名 ASCII 兼容")

            # 文件大小
            size_kb = output_path.stat().st_size / 1024
            results.append(f"📦 包大小: {size_kb:.1f} KB")

    except Exception as e:
        results.append(f"❌ zip验证失败: {e}")

    has_fail = any(r.startswith("❌") for r in results)
    status = "FAIL" if has_fail else "PASS"
    return {
        "name": "ZIP打包检查",
        "status": status,
        "details": "\n".join(results),
    }
