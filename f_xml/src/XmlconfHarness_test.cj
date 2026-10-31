/*
Copyright (c) 2026 WuJingrun（吴京润）

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/
package fountain::f_xml

import std.unittest.*
import std.unittest.testmacro.*
import std.collection.{ArrayList, HashMap}
import std.env
import std.fs.{File, OpenMode, Path, exists}

/**
 * xmlconf 20130923 的 harness。
 *
 * **不联网、不解析 catalog**：只读缓存里的 `cases.json`。套件本体与派生 JSON 不入库，
 * 缓存缺失时用例 **fail**（不是 skip），消息固定为「先运行 xmlconf_gen.py」。
 *
 * 判定口径（与生成脚本注释一致）：
 * - `valid` / `invalid` → 期望**解析成功**（`invalid` 是良构但不合 DTD，我们不校验 DTD）
 * - `not-wf` → 期望抛 `XmlException`
 * - `error` → 不判定，只观察
 */
internal class CaseOutcome {
    let ok: Bool
    let error: String

    init(ok: Bool, error: String) {
        this.ok = ok
        this.error = error
    }
}

@Test
public class XmlconfHarness_test {
    /** 缓存缺失时 fail 并提示运行生成脚本。 */
    @TestCase
    public func cacheMissingFails(): Unit {
        // 只有在缓存确实缺失时才验证提示；缓存存在时这条用例等价于自检通过。
        match (TestDataRoot.cacheDir()) {
            case Some(_) => @Assert(true)
            case None => assertTrue(false, TestDataRoot.MISSING_MESSAGE)
        }
    }

    /** 全量套件：输出 pass / fail / unsupported 三个数字，Gate A 要求 fail == 0。 */
    @TestCase
    public func fullSuite(): Unit {
        let cache = TestDataRoot.requireCacheDir()
        let cases = FlatJson.parseArray(FlatJson.readFile(cache.join("cases.json")))
        assertTrue(cases.size > 2000, "可跑集只有 ${cases.size} 条")

        let known = loadKnownIssues()
        assertTrue(known.size <= 5, "known-issues 超过 5 条：${known.size}")

        var passed: Int64 = 0
        var failed: Int64 = 0
        var observed: Int64 = 0
        var knownHits: Int64 = 0
        let failures = ArrayList<String>()

        for (record in cases) {
            let id = record.get("id")
            let uri = record.get("uri")
            let expected = record.get("type")
            let path = cache.join("suite").join(uri)
            if (!exists(path)) {
                failed++
                failures.add("${id}: 文件不存在 ${uri}")
                continue
            }
            let bytes = readBytes(path)
            let outcome = runCase(bytes)
            match (expected) {
                case "valid" | "invalid" =>
                    if (outcome.ok) {
                        passed++
                    } else if (known.contains(id)) {
                        knownHits++
                    } else {
                        failed++
                        failures.add("${id} (${expected}): 期望成功，实际 ${outcome.error}")
                    }
                case "not-wf" =>
                    if (!outcome.ok) {
                        passed++
                    } else if (known.contains(id)) {
                        knownHits++
                    } else {
                        failed++
                        failures.add("${id} (not-wf): 期望失败，实际解析成功")
                    }
                case _ =>
                    observed++
            }
        }

        let unsupported = countUnsupported(cache)
        println("xmlconf: pass=${passed} fail=${failed} unsupported=${unsupported} observed=${observed} known=${knownHits}")
        assertTrue(passed + knownHits == 2038, "pass+known=${passed + knownHits}，期望 2038")
        assertTrue(unsupported == 524, "unsupported=${unsupported}，期望 524")

        let reportPath = cache.join("failures.txt")
        let reportFile = File(reportPath.toString(), OpenMode.Write)
        for (line in failures) {
            reportFile.write((line + "\n").toArray())
        }
        reportFile.close()

        if (failures.size > 0) {
            var report = ""
            var limit = failures.size
            if (limit > 20) {
                limit = 20
            }
            for (i in 0..limit) {
                report += failures[i] + "\n"
            }
            assertTrue(failed == 0, "xmlconf 失败 ${failed} 条，前 ${limit} 条：\n${report}")
        }
    }

    private func runCase(bytes: Array<Byte>): CaseOutcome {
        try {
            XmlParser.parse(bytes)
            CaseOutcome(true, "")
        } catch (e: XmlException) {
            CaseOutcome(false, e.message)
        } catch (e: Exception) {
            CaseOutcome(false, e.toString())
        }
    }

    private func readBytes(path: Path): Array<Byte> {
        let file = File(path.toString(), OpenMode.Read)
        try {
            let bytes = ArrayList<Byte>()
            let buffer = Array<Byte>(8192, repeat: 0)
            var reading = true
            while (reading) {
                let n = file.read(buffer)
                if (n <= 0) {
                    reading = false
                } else {
                    for (i in 0..n) {
                        bytes.add(buffer[i])
                    }
                }
            }
            bytes.toArray()
        } finally {
            file.close()
        }
    }

    private func countUnsupported(cache: Path): Int64 {
        let path = cache.join("unsupported.json")
        if (!exists(path)) {
            return 0
        }
        Int64(FlatJson.parseArray(FlatJson.readFile(path)).size)
    }

    private func loadKnownIssues(): HashMap<String, String> {
        let map = HashMap<String, String>()
        let path = env.getWorkingDirectory().join("tools").join("known-issues.json")
        if (!exists(path)) {
            return map
        }
        let records = FlatJson.parseArray(FlatJson.readFile(path))
        for (record in records) {
            let id = record.get("id")
            if (!id.isEmpty() && id != "null") {
                map[id] = record.get("reason")
            }
        }
        map
    }
}
