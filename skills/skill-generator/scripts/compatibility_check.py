"""跨平台兼容性检查"""
import re
from pathlib import Path

# 检查模块文件名（自检时排除自身，其中包含规则描述是正常的）
_CHECK_MODULE_NAMES = {
    "colleague_sim.py", "compatibility_check.py", "security_check.py",
    "smoke_test.py", "syntax_check.py", "trace_eval.py",
    "version_check.py", "zip_pack.py",
}


def run(skill_path: Path, config: dict) -> dict:
    """检查跨OS、跨Claw平台兼容性"""
    check_config = config.get("compatibility_check", {})
    if not check_config.get("enabled", True):
        return {"name": "兼容性检查", "status": "SKIP", "details": "已禁用"}

    results = []
    all_pass = True

    # A. OS兼容性
    os_compat = check_config.get("os_compat", {})
    for check_name, check_def in os_compat.items():
        pattern = check_def.get("pattern", "")
        glob_pattern = check_def.get("glob", "scripts/*.py")
        expected = check_def.get("expected_count", None)
        must_have = check_def.get("must_have", None)
        exclude_patterns = check_def.get("exclude_patterns", [])
        allow_list = check_def.get("allow_list", [])

        files = []
        for gp in glob_pattern.split():
            files.extend(skill_path.glob(gp))

        matches = []
        for f in files:
            if not f.is_file():
                continue
            try:
                content = f.read_text(encoding="utf-8")
                # 检查模块自身使用 subprocess 是功能必需，按文件名排除
                rel_path = str(f.relative_to(skill_path))
                is_check_module = f.name in _CHECK_MODULE_NAMES
                for i, line in enumerate(content.split("\n"), 1):
                    if re.search(pattern, line):
                        # 排除
                        skip = False
                        for ep in exclude_patterns:
                            if ep in line:
                                skip = True
                                break
                        for al in allow_list:
                            if al in line:
                                skip = True
                                break
                        # 检查模块中的 subprocess 调用是功能必需，允许
                        if is_check_module and "subprocess" in pattern:
                            skip = True
                        if skip:
                            continue
                        rel = f.relative_to(skill_path)
                        matches.append(f"  {rel}:{i}: {line.strip()[:80]}")
            except Exception:
                continue

        # 判断逻辑
        if must_have is not None:
            # 检查 open() 是否都有 encoding=
            missing = []
            for f in files:
                if not f.is_file():
                    continue
                try:
                    content = f.read_text(encoding="utf-8")
                    for i, line in enumerate(content.split("\n"), 1):
                        if re.search(pattern, line):
                            if must_have not in line:
                                skip = False
                                for ep in exclude_patterns:
                                    if ep in line:
                                        skip = True
                                        break
                                if not skip:
                                    rel = f.relative_to(skill_path)
                                    missing.append(f"  {rel}:{i}: {line.strip()[:80]}")
                except Exception:
                    continue
            if missing:
                all_pass = False
                results.append(f"❌ {check_name}: {len(missing)} 处未指定编码")
                results.extend(missing[:5])
            else:
                results.append(f"✅ {check_name}: 全部指定了编码")
        elif expected is not None:
            if len(matches) != expected:
                all_pass = False
                results.append(f"❌ {check_name}: 发现 {len(matches)} 处 (期望 {expected})")
                results.extend(matches[:5])
            else:
                results.append(f"✅ {check_name}: {len(matches)} 处 (期望 {expected})")

    # B. 平台兼容性
    platform_compat = check_config.get("platform_compat", {})
    if platform_compat.get("ascii_filenames", True):
        non_ascii = []
        for f in skill_path.rglob("*"):
            if f.is_file() or f.is_dir():
                try:
                    f.name.encode("ascii")
                except UnicodeEncodeError:
                    non_ascii.append(str(f.relative_to(skill_path)))
        if non_ascii:
            all_pass = False
            results.append(f"❌ ASCII文件名: 发现 {len(non_ascii)} 个非ASCII名")
            results.extend([f"  {n}" for n in non_ascii[:10]])
        else:
            results.append("✅ ASCII文件名: 全部通过")

    if platform_compat.get("skill_md_in_root", True):
        if (skill_path / "SKILL.md").exists():
            results.append("✅ SKILL.md在根目录: 通过")
        else:
            all_pass = False
            results.append("❌ SKILL.md在根目录: 未找到")

    # C. 依赖检查
    dep_check = check_config.get("dependency_check", {})
    core_zero = dep_check.get("core_zero_deps", {})
    if core_zero:
        core_file = skill_path / core_zero.get("file", "")
        allowed = set(core_zero.get("allowed_imports", []))
        if core_file.exists():
            content = core_file.read_text(encoding="utf-8")
            bad_imports = []
            for line in content.split("\n"):
                line = line.strip()
                if line.startswith("import ") or line.startswith("from "):
                    mod = line.split()[1].split(".")[0]
                    if mod not in allowed:
                        bad_imports.append(f"  {line}")
            if bad_imports:
                all_pass = False
                results.append(f"❌ 核心功能依赖: 发现非标准库导入")
                results.extend(bad_imports[:5])
            else:
                results.append("✅ 核心功能依赖: 零外部依赖")

    status = "PASS" if all_pass else "FAIL"
    return {
        "name": "兼容性检查（OS+平台+依赖）",
        "status": status,
        "details": "\n".join(results),
    }
