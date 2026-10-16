"""代码语法检查"""
import py_compile
import sys
from pathlib import Path


def run(skill_path: Path, config: dict) -> dict:
    """编译检查所有 Python 脚本"""
    check_config = config.get("syntax_check", {})
    if not check_config.get("enabled", True):
        return {"name": "代码语法检查", "status": "SKIP", "details": "已禁用"}

    glob_pattern = check_config.get("glob", "scripts/*.py")
    scripts_dir = skill_path / glob_pattern.split("/")[0]
    py_files = list(skill_path.glob(glob_pattern))

    if not py_files:
        return {
            "name": "代码语法检查",
            "status": "FAIL",
            "details": f"未找到 Python 文件: {glob_pattern}",
        }

    errors = []
    passed = []
    for f in py_files:
        try:
            py_compile.compile(str(f), doraise=True)
            passed.append(f"✅ {f.name}")
        except py_compile.PyCompileError as e:
            errors.append(f"❌ {f.name}: {e}")

    if errors:
        return {
            "name": "代码语法检查",
            "status": "FAIL",
            "details": f"共 {len(py_files)} 个脚本\n" + "\n".join(errors + passed),
        }
    return {
        "name": "代码语法检查",
        "status": "PASS",
        "details": f"{len(passed)} 个脚本全部通过编译检查",
    }
