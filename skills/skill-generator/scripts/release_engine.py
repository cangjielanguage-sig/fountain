#!/usr/bin/env python3
"""
skill-generator 收口检查引擎
通用 Skill 收口检查引擎，支持任意 Skill 目录

用法:
    python3 release_engine.py --skill-path /path/to/your/skill
    python3 release_engine.py --skill-path /path/to/your/skill --step all
    python3 release_engine.py --skill-path /path/to/your/skill --step version,syntax
"""

import os
import sys
import json
import argparse
import subprocess
import tempfile
import shutil
from pathlib import Path

# 检查模块路径（与引擎同目录）
CHECKS_DIR = Path(__file__).parent
sys.path.insert(0, str(CHECKS_DIR))


def load_config(skill_path: Path) -> dict:
    """加载 Skill 的配置文件"""
    config_path = skill_path / ".release-config.json"
    if not config_path.exists():
        # 使用默认模板
        template_path = Path(__file__).parent.parent / "assets" / "release-config.json"
        if template_path.exists():
            print(f"⚠️  {skill_path.name} 没有 .release-config.json，使用默认模板")
            with open(template_path, "r", encoding="utf-8") as f:
                config = json.load(f)
            config["name"] = skill_path.name
            return config
        else:
            print(f"❌ 找不到配置文件: {config_path}")
            sys.exit(1)
    with open(config_path, "r", encoding="utf-8") as f:
        return json.load(f)


def run_check(module_name: str, skill_path: Path, config: dict) -> dict:
    """运行单个检查模块"""
    try:
        module = __import__(module_name)
        return module.run(skill_path, config)
    except Exception as e:
        return {"name": module_name, "status": "ERROR", "error": str(e)}


def print_report(results: list, skill_name: str):
    """输出收口自检报告"""
    print(f"\n{'='*60}")
    print(f"  {skill_name} 收口自检报告")
    print(f"{'='*60}\n")

    passed = 0
    failed = 0
    errors = 0

    for r in results:
        status = r.get("status", "UNKNOWN")
        name = r.get("name", "未知检查")
        details = r.get("details", "")

        if status == "PASS":
            icon = "✅"
            passed += 1
        elif status == "FAIL":
            icon = "❌"
            failed += 1
        elif status == "ERROR":
            icon = "⚠️"
            errors += 1
        else:
            icon = "⏸️"

        print(f"  {icon} {name}")
        if details:
            for line in details.split("\n"):
                print(f"      {line}")

    print(f"\n{'='*60}")
    print(f"  结果: ✅通过 {passed}  |  ❌失败 {failed}  |  ⚠️错误 {errors}")
    print(f"{'='*60}")

    if failed > 0 or errors > 0:
        print("\n  ⚠️  有失败项，请修复后重新运行收口")
        return False
    return True


def main():
    parser = argparse.ArgumentParser(description="Skill 收口检查引擎")
    parser.add_argument("--skill-path", required=True, help="Skill 目录路径")
    parser.add_argument(
        "--step",
        default="all",
        help="要执行的步骤，逗号分隔: version,syntax,security,compat,smoke,zip,colleague,trace,all",
    )
    parser.add_argument("--output", help="报告输出JSON文件路径")
    args = parser.parse_args()

    skill_path = Path(args.skill_path).resolve()
    if not skill_path.exists():
        print(f"❌ Skill 路径不存在: {skill_path}")
        sys.exit(1)

    config = load_config(skill_path)
    skill_name = config.get("name", skill_path.name)

    step_map = {
        "version": "version_check",
        "syntax": "syntax_check",
        "security": "security_check",
        "compat": "compatibility_check",
        "smoke": "smoke_test",
        "zip": "zip_pack",
        "colleague": "colleague_sim",
        "trace": "trace_eval",
    }

    if args.step == "all":
        steps = list(step_map.values())
    else:
        steps = []
        for s in args.step.split(","):
            s = s.strip()
            if s in step_map:
                steps.append(step_map[s])
            else:
                print(f"⚠️  未知步骤: {s}，跳过")

    print(f"\n🔧 开始对 {skill_name} 执行收口检查...")
    print(f"   Skill路径: {skill_path}")
    print(f"   执行步骤: {', '.join(steps)}\n")

    results = []
    for step in steps:
        print(f"\n▶️  正在执行: {step} ...")
        result = run_check(step, skill_path, config)
        results.append(result)

    all_pass = print_report(results, skill_name)

    if args.output:
        with open(args.output, "w", encoding="utf-8") as f:
            json.dump(
                {"skill": skill_name, "path": str(skill_path), "results": results},
                f,
                ensure_ascii=False,
                indent=2,
            )
        print(f"\n📄 报告已保存: {args.output}")

    sys.exit(0 if all_pass else 1)


if __name__ == "__main__":
    main()
