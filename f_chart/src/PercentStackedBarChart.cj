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
package fountain::f_chart

import fountain::f_data.json.JsonObject

/**
 * M4 百分比堆叠柱状图：每个类目归一化到 100%。
 *
 * JSON 字段见 `doc/chart-json-spec.md` 的 `percent-stacked-bar` 小节。
 */
public class PercentStackedBarChart <: Chart {
    public init() {}

    public func draw(data: JsonObject): String {
        BarRenderer.render(data, "percent-stacked-bar", BarMode.PercentStacked)
    }
}
