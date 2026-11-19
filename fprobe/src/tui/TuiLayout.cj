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
package fountain::fprobe.tui

/**
 * 右侧指标区的固定预算。
 *
 * 终端总高度减去：顶部标题 1 行、底部告警 1 行、panel 上下边框 2 行、
 * 指标表行数，再留 1 行空白；剩余高度给图表。
 */
public class TuiLayout {
    /** `f_chart.tui` 的最小高度；低于它改用单行 sparkline。 */
    public static let MIN_CHART_HEIGHT: Int64 = 8

    private static let CHROME_HEIGHT: Int64 = 5

    /** 指标表之下的可用高度，永不为负。 */
    public static func innerHeight(viewportHeight: Int64, metricRows: Int64): Int64 {
        let available = viewportHeight - metricRows - CHROME_HEIGHT
        if (available < 0) {
            0
        } else {
            available
        }
    }

    /** 图表高度；不足 `MIN_CHART_HEIGHT` 时返回 0，由调用方回退。 */
    public static func chartHeight(viewportHeight: Int64, metricRows: Int64): Int64 {
        let inner = innerHeight(viewportHeight, metricRows)
        if (inner >= MIN_CHART_HEIGHT) {
            inner
        } else {
            0
        }
    }
}
