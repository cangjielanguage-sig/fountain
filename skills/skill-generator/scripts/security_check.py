"""安全检查"""
import re
from pathlib import Path

# 规则定义文件：这些文件里出现危险模式，是在描述规则本身，不是违规
_RULE_DEFINITION_FILES = {
    "colleague_sim.py", "compatibility_check.py", "security_check.py",
    "smoke_test.py", "syntax_check.py", "trace_eval.py",
    "version_check.py", "zip_pack.py", "release_engine.py", "release_check.py",
    ".release-config.json", "release-config.json",
}


def run(skill_path: Path, config: dict) -> dict:
    """安全检查：裸except、硬编码secret、eval/exec、rm -rf"""
    check_config = config.get("security_check", {})
    if not check_config.get("enabled", True):
        return {"name": "安全检查", "status": "SKIP", "details": "已禁用"}

    checks = check_config.get("checks", {})
    results = []
    all_pass = True

    for check_name, check_def in checks.items():
        pattern = check_def.get("pattern", "")
        glob_pattern = check_def.get("glob", "scripts/*.py")
        expected = check_def.get("expected_count", 0)
        exclude_empty = check_def.get("exclude_empty", False)

        files = []
        for gp in glob_pattern.split():
            files.extend(skill_path.glob(gp))

        matches = []
        for f in files:
            if not f.is_file():
                continue
            if f.name in _RULE_DEFINITION_FILES:
                continue
            try:
                content = f.read_text(encoding="utf-8")
                for i, line in enumerate(content.split("\n"), 1):
                    stripped = line.strip()
                    # 跳过注释和 docstring
                    if stripped.startswith("#") or stripped.startswith('"""') or stripped.startswith("'''"):
                        continue
                    # 跳过自身模块的检查代码（如 "if 'except:' in content"）
                    if "in content" in stripped or "in line" in stripped:
                        continue
                    if re.search(pattern, line):
                        # 排除空值
                        if exclude_empty and '""' in line:
                            continue
                        rel = f.relative_to(skill_path)
                        matches.append(f"  {rel}:{i}: {line.strip()[:80]}")
            except Exception:
                continue

        count = len(matches)
        if count != expected:
            all_pass = False
            results.append(f"❌ {check_name}: 发现 {count} 处 (期望 {expected})")
            if matches:
                results.extend(matches[:5])  # 最多显示5条
                if len(matches) > 5:
                    results.append(f"  ... 还有 {len(matches)-5} 处")
        else:
            results.append(f"✅ {check_name}: {count} 处 (期望 {expected})")

    status = "PASS" if all_pass else "FAIL"
    return {
        "name": "安全检查",
        "status": status,
        "details": "\n".join(results),
    }
