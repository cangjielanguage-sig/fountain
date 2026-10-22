"""冒烟测试"""
import subprocess
import shlex
from pathlib import Path


def run(skill_path: Path, config: dict) -> dict:
    """执行配置的冒烟测试用例"""
    check_config = config.get("smoke_test", {})
    if not check_config.get("enabled", True):
        return {"name": "冒烟测试", "status": "SKIP", "details": "已禁用"}

    tests = check_config.get("tests", [])
    if not tests:
        return {"name": "冒烟测试", "status": "SKIP", "details": "未配置测试用例"}

    results = []
    all_pass = True

    for test in tests:
        name = test.get("name", "未命名测试")
        command = test.get("command", "")
        expect_contains = test.get("expect_contains", "")
        expect_returncode = test.get("expect_returncode", 0)

        # 在 skill 目录下执行
        try:
            result = subprocess.run(
                command,
                shell=True,
                cwd=str(skill_path),
                capture_output=True,
                text=True,
                timeout=30,
            )
            output = result.stdout + result.stderr

            passed = True
            fail_reasons = []

            if expect_contains and expect_contains not in output:
                passed = False
                fail_reasons.append(f"输出不包含 '{expect_contains}'")

            if result.returncode != expect_returncode:
                passed = False
                fail_reasons.append(f"返回码 {result.returncode} (期望 {expect_returncode})")

            if passed:
                results.append(f"✅ {name}")
            else:
                all_pass = False
                results.append(f"❌ {name}: {'; '.join(fail_reasons)}")
                results.append(f"   输出: {output[:200].strip()}")

        except subprocess.TimeoutExpired:
            all_pass = False
            results.append(f"❌ {name}: 超时(30s)")
        except Exception as e:
            all_pass = False
            results.append(f"❌ {name}: 执行异常: {e}")

    status = "PASS" if all_pass else "FAIL"
    return {
        "name": "冒烟测试",
        "status": status,
        "details": f"共 {len(tests)} 项测试\n" + "\n".join(results),
    }
