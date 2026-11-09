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
package fountain::fprobe.report

import std.collection.{ArrayList, HashMap}
import std.env.getTempDirectory
import std.fs.Directory
import fountain::f_chart.Chart
import fountain::f_data.*
import fountain::f_data.json.JsonObject
import fountain::fprobe.tui.HistorySource

/** 用例共享的临时目录；调用方负责删除。 */
func reportTempDir(): String {
    Directory.createTemp(getTempDirectory()).toString()
}

/** 只按 `node|metric` 返回预设历史点的替身。 */
class FakeHistory <: HistorySource {
    private let data = HashMap<String, Array<Float64>>()

    init() {}

    func set(node: String, metric: String, values: Array<Float64>): Unit {
        data["${node}|${metric}"] = values
    }

    public func values(node: String, metric: String): Array<Float64> {
        match (data.get("${node}|${metric}")) {
            case Some(values) => values
            case None => Array<Float64>()
        }
    }
}

/** 不画真实图形，只回显固定 SVG 的替身。 */
class FixedChart <: Chart {
    private let content: String
    private let calls: ArrayList<String>

    init(content: String, calls: ArrayList<String>) {
        this.content = content
        this.calls = calls
    }

    public func draw(data: JsonObject): String {
        calls.add(JsonValue.from(data).toString())
        content
    }
}

let FIXED_SVG = '<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><circle cx="5" cy="5" r="4"/></svg>'
