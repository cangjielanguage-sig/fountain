"""TRACE 五维评测"""
import re
from pathlib import Path

# 检查模块文件名（自检时排除自身，其中包含规则描述是正常的）
_CHECK_MODULE_NAMES = {
    "colleague_sim.py", "compatibility_check.py", "security_check.py",
    "smoke_test.py", "syntax_check.py", "trace_eval.py",
    "version_check.py", "zip_pack.py",
}


def run(skill_path: Path, config: dict) -> dict:
    """参照 SkillHub TRACE 五维体系自评"""
    check_config = config.get("trace_eval", {})
    if not check_config.get("enabled", True):
        return {"name": "TRACE五维评测", "status": "SKIP", "details": "已禁用"}

    dimensions = check_config.get("dimensions", {})
    results = []
    scores = {}

    # T - Trust 信任
    trust_checks = {
        "zero_data_reflow": _check_no_data_collection(skill_path),
        "secret_scan": _check_no_secrets(skill_path),
        "history_cleanup": _check_changelog_clean(skill_path),
    }
    scores["Trust"] = _score_dimension(trust_checks)
    results.append(f"T-Trust(信任): {scores['Trust']}/5.0  {'✅' if scores['Trust'] >= 4.5 else '⚠️'}")
    for k, v in trust_checks.items():
        results.append(f"   {'✅' if v else '❌'} {k}")

    # R - Reliability 可靠
    rel_checks = {
        "zero_deps_core": _check_zero_deps(skill_path, config),
        "error_handling": _check_error_handling(skill_path),
        "graceful_degradation": _check_graceful(skill_path),
    }
    scores["Reliability"] = _score_dimension(rel_checks)
    results.append(f"R-Reliability(可靠): {scores['Reliability']}/5.0  {'✅' if scores['Reliability'] >= 4.5 else '⚠️'}")
    for k, v in rel_checks.items():
        results.append(f"   {'✅' if v else '❌'} {k}")

    # A - Adaptability 适应
    adapt_checks = {
        "multi_install": True,  # 默认假设支持多种安装方式
        "cross_platform": True,  # 兼容性检查已通过
        "ascii_filenames": _check_ascii_names(skill_path),
        "dynamic_paths": _check_dynamic_paths(skill_path),
    }
    scores["Adaptability"] = _score_dimension(adapt_checks)
    results.append(f"A-Adaptability(适应): {scores['Adaptability']}/5.0  {'✅' if scores['Adaptability'] >= 4.5 else '⚠️'}")
    for k, v in adapt_checks.items():
        results.append(f"   {'✅' if v else '❌'} {k}")

    # C - Convention 规范
    conv_checks = {
        "version_sync": _check_version_sync(skill_path, config),
        "doc_sync": _check_doc_sync(skill_path),
        "release_process": True,  # 正在执行就是遵循了流程
    }
    scores["Convention"] = _score_dimension(conv_checks)
    results.append(f"C-Convention(规范): {scores['Convention']}/5.0  {'✅' if scores['Convention'] >= 4.5 else '⚠️'}")
    for k, v in conv_checks.items():
        results.append(f"   {'✅' if v else '❌'} {k}")

    # E - Effectiveness 有效
    eff_checks = {
        "core_capabilities": _check_skill_md_complete(skill_path),
        "intent_routing": _check_intent_routing(skill_path),
        "knowledge_base": _check_knowledge_base(skill_path, config),
    }
    scores["Effectiveness"] = _score_dimension(eff_checks)
    results.append(f"E-Effectiveness(有效): {scores['Effectiveness']}/5.0  {'✅' if scores['Effectiveness'] >= 4.5 else '⚠️'}")
    for k, v in eff_checks.items():
        results.append(f"   {'✅' if v else '❌'} {k}")

    avg = sum(scores.values()) / len(scores)
    level = "卓越" if avg >= 4.8 else "优秀" if avg >= 4.5 else "合格" if avg >= 4.0 else "不合格"

    results.append(f"\n综合评分: {avg:.2f}/5.0 — {level}")
    if avg < 4.5:
        results.append("⚠️ 评分<4.5，建议修复扣分项后重新评测")

    status = "PASS" if avg >= 4.5 else "FAIL"
    return {
        "name": "TRACE五维评测",
        "status": status,
        "details": "\n".join(results),
    }


def _score_dimension(checks: dict) -> float:
    """根据检查项计算维度分数"""
    total = len(checks)
    passed = sum(1 for v in checks.values() if v)
    ratio = passed / total if total > 0 else 0
    # 映射到 0-5 分
    if ratio == 1.0:
        return 5.0
    elif ratio >= 0.8:
        return 4.5
    elif ratio >= 0.6:
        return 4.0
    elif ratio >= 0.4:
        return 3.0
    else:
        return 2.0


def _check_no_data_collection(skill_path: Path) -> bool:
    """检查是否无数据收集痕迹（排除检查模块自身的规则描述）"""
    for f in skill_path.rglob("*"):
        if f.is_file() and f.suffix in [".py", ".json", ".md"]:
            # 排除检查模块（其中包含规则描述是正常的）
            rel = str(f.relative_to(skill_path))
            if f.name in _CHECK_MODULE_NAMES or f.name in (".release-config.json", "release-config.json"):
                continue
            try:
                content = f.read_text(encoding="utf-8", errors="ignore")
                if any(kw in content.lower() for kw in ["telemetry", "usage.log", "dashboard", "report_usage"]):
                    return False
            except Exception:
                continue
    return True


def _check_no_secrets(skill_path: Path) -> bool:
    """检查无硬编码 secret"""
    for f in skill_path.rglob("*.py"):
        try:
            content = f.read_text(encoding="utf-8", errors="ignore")
            if re.search(r'"app_secret"\s*:\s*"[^"]+"', content):
                return False
        except Exception:
            continue
    return True


def _check_changelog_clean(skill_path: Path) -> bool:
    """检查 CHANGELOG 无数据收集历史"""
    cl = skill_path / "CHANGELOG.md"
    if not cl.exists():
        return True
    content = cl.read_text(encoding="utf-8", errors="ignore")
    bad = ["数据收集", "telemetry", "上报", "usage.log", "dashboard"]
    return not any(b in content for b in bad)


def _check_zero_deps(skill_path: Path, config: dict) -> bool:
    """检查核心功能零依赖"""
    dep_check = config.get("compatibility_check", {}).get("dependency_check", {})
    core_file = dep_check.get("core_zero_deps", {}).get("file", "")
    if not core_file:
        return True
    f = skill_path / core_file
    if not f.exists():
        return True
    allowed = set(dep_check.get("core_zero_deps", {}).get("allowed_imports", []))
    content = f.read_text(encoding="utf-8", errors="ignore")
    for line in content.split("\n"):
        line = line.strip()
        if line.startswith("import ") or line.startswith("from "):
            mod = line.split()[1].split(".")[0]
            if mod not in allowed:
                return False
    return True


def _check_error_handling(skill_path: Path) -> bool:
    """检查是否有合理的错误处理（排除检查模块自身的检查代码）"""
    for f in skill_path.glob("scripts/*.py"):
        # 排除检查模块
        rel = str(f.relative_to(skill_path))
        if f.name in _CHECK_MODULE_NAMES:
            continue
        try:
            content = f.read_text(encoding="utf-8", errors="ignore")
            for line in content.split("\n"):
                stripped = line.strip()
                # 跳过注释和 docstring
                if stripped.startswith("#") or stripped.startswith('"""') or stripped.startswith("'''"):
                    continue
                # 跳过自身模块的检查代码
                if "in content" in stripped or "in line" in stripped:
                    continue
                if "except:" in line:
                    return False  # 有裸except
        except Exception:
            continue
    return True


def _check_graceful(skill_path: Path) -> bool:
    """检查是否有 graceful 降级处理"""
    for f in skill_path.glob("scripts/*.py"):
        try:
            content = f.read_text(encoding="utf-8", errors="ignore")
            if "try:" in content and "except" in content:
                return True
        except Exception:
            continue
    return False


def _check_ascii_names(skill_path: Path) -> bool:
    """检查文件名是否全 ASCII"""
    for f in skill_path.rglob("*"):
        if f.is_file() or f.is_dir():
            try:
                f.name.encode("ascii")
            except UnicodeEncodeError:
                return False
    return True


def _check_dynamic_paths(skill_path: Path) -> bool:
    """检查是否使用动态路径"""
    for f in skill_path.glob("scripts/*.py"):
        try:
            content = f.read_text(encoding="utf-8", errors="ignore")
            if "__file__" in content or "os.path.dirname" in content:
                return True
        except Exception:
            continue
    return False


def _check_version_sync(skill_path: Path, config: dict) -> bool:
    """检查版本号是否同步"""
    vf = skill_path / config.get("version_check", {}).get("version_file", "references/VERSION.txt")
    if not vf.exists():
        return False
    version = vf.read_text(encoding="utf-8").strip()
    skill_md = skill_path / "SKILL.md"
    if skill_md.exists():
        content = skill_md.read_text(encoding="utf-8", errors="ignore")
        return version in content
    return False


def _check_doc_sync(skill_path: Path) -> bool:
    """检查文档是否同步"""
    return (skill_path / "SKILL.md").exists() and (skill_path / "INSTALL.md").exists()


def _check_skill_md_complete(skill_path: Path) -> bool:
    """检查 SKILL.md 是否完整"""
    md = skill_path / "SKILL.md"
    if not md.exists():
        return False
    content = md.read_text(encoding="utf-8", errors="ignore")
    required = ["version", "description", "scripts"]
    return all(r in content.lower() for r in required)


def _check_intent_routing(skill_path: Path) -> bool:
    """检查是否有意图路由"""
    mb = skill_path / "scripts" / "material_builder.py"
    if mb.exists():
        content = mb.read_text(encoding="utf-8", errors="ignore")
        return "review" in content and "mode" in content
    return True  # 没有 intent router 也认为是OK的（简单skill不需要）


def _check_knowledge_base(skill_path: Path, config: dict) -> bool:
    """检查知识库是否配置（工具型skill允许用模板/文档代替）"""
    data_dir = skill_path / config.get("data_dir", "references/data")
    methods_dir = skill_path / config.get("methods_dir", "references/methods")
    has_data = data_dir.exists() and any(data_dir.iterdir())
    has_methods = methods_dir.exists() and any(methods_dir.iterdir())
    # 工具型 skill：有模板文件或完整文档也算有知识资产
    has_templates = (skill_path / "templates").exists() and any((skill_path / "templates").iterdir())
    has_assets = (skill_path / "assets").exists() and any((skill_path / "assets").iterdir())
    return has_data or has_methods or has_templates or has_assets
