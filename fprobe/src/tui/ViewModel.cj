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
 * TUI 右侧的指标页。
 *
 * 枚举顺序就是 `Tab` / `Shift+Tab` 的翻页顺序；`ALARMS` 既可由 `a` 直达，
 * 也可由 `Tab` 从拓扑页继续前进到达。
 */
public enum MetricPage <: Equatable<MetricPage> {
    | CPU
    | MEMORY
    | DISK
    | NETWORK
    | SERVICE
    | HEALTH
    | TOPOLOGY
    | ALARMS

    public operator func ==(other: MetricPage): Bool {
        match ((this, other)) {
            case (CPU, CPU) | (MEMORY, MEMORY) | (DISK, DISK) | (NETWORK, NETWORK) => true
            case (SERVICE, SERVICE) | (HEALTH, HEALTH) | (TOPOLOGY, TOPOLOGY) | (ALARMS, ALARMS) => true
            case _ => false
        }
    }

    public func title(): String {
        match (this) {
            case CPU => "CPU"
            case MEMORY => "内存"
            case DISK => "磁盘"
            case NETWORK => "网络"
            case SERVICE => "服务"
            case HEALTH => "健康"
            case TOPOLOGY => "拓扑"
            case ALARMS => "告警"
        }
    }

    /** 该页在 TUI 中使用的图表类型；空串表示不画图。 */
    public func chartType(): String {
        match (this) {
            case CPU | MEMORY | NETWORK | SERVICE | HEALTH => "line"
            case DISK => "bar"
            case TOPOLOGY | ALARMS => ""
        }
    }

    /** 与 `ProbeAgent.kind` 对应的键；告警页不绑定具体监控项。 */
    public func kind(): String {
        match (this) {
            case CPU => "cpu"
            case MEMORY => "memory"
            case DISK => "disk"
            case NETWORK => "network"
            case SERVICE => "service"
            case HEALTH => "mvc-health"
            case TOPOLOGY => "topology"
            case ALARMS => ""
        }
    }
}

/**
 * 监督端 TUI 的视图状态（设计 D9）。
 *
 * 所有状态迁移都返回新实例，不修改自身；选中项与页索引在这里完成夹取与回绕，
 * 因此可以完全脱离终端做单元测试。
 */
public class ViewModel {
    public static let PAGES: Array<MetricPage> = [
        MetricPage.CPU,
        MetricPage.MEMORY,
        MetricPage.DISK,
        MetricPage.NETWORK,
        MetricPage.SERVICE,
        MetricPage.HEALTH,
        MetricPage.TOPOLOGY,
        MetricPage.ALARMS
    ]

    public let nodes: Array<String>
    public let selection: Int64
    public let pageIndex: Int64
    public let alarmCount: Int64

    public init(nodes: Array<String>, selection: Int64, pageIndex: Int64, alarmCount: Int64) {
        this.nodes = nodes
        this.selection = clampSelection(selection, nodes.size)
        this.pageIndex = normalizePage(pageIndex)
        this.alarmCount = alarmCount
    }

    public static func empty(): ViewModel {
        ViewModel([], 0, 0, 0)
    }

    /** 替换节点列表；选中项越界时收敛到最后一个节点。 */
    public func withNodes(values: Array<String>): ViewModel {
        ViewModel(values, selection, pageIndex, alarmCount)
    }

    public func selectedNode(): ?String {
        if (nodes.isEmpty()) {
            return None<String>
        }
        Some(nodes[selection])
    }

    public func page(): MetricPage {
        PAGES[pageIndex]
    }

    /** 从 1 开始，便于状态栏直接展示。 */
    public func pageNumber(): Int64 {
        pageIndex + 1
    }

    public func pageCount(): Int64 {
        PAGES.size
    }

    public func selectNext(): ViewModel {
        if (nodes.isEmpty()) {
            return this
        }
        ViewModel(nodes, selection + 1, pageIndex, alarmCount)
    }

    public func selectPrevious(): ViewModel {
        ViewModel(nodes, selection - 1, pageIndex, alarmCount)
    }

    public func nextPage(): ViewModel {
        ViewModel(nodes, selection, pageIndex + 1, alarmCount)
    }

    public func previousPage(): ViewModel {
        ViewModel(nodes, selection, pageIndex - 1, alarmCount)
    }

    /** `a` 键直达告警页。 */
    public func showAlarms(): ViewModel {
        ViewModel(nodes, selection, alarmPageIndex(), alarmCount)
    }

    public func withAlarmCount(value: Int64): ViewModel {
        ViewModel(nodes, selection, pageIndex, value)
    }

    private static func clampSelection(value: Int64, size: Int64): Int64 {
        if (size <= 0) {
            return 0
        }
        if (value < 0) {
            return 0
        }
        if (value >= size) {
            return size - 1
        }
        value
    }

    private static func normalizePage(value: Int64): Int64 {
        let size = PAGES.size
        var result = value % size
        if (result < 0) {
            result += size
        }
        result
    }

    private static func alarmPageIndex(): Int64 {
        for (i in 0..PAGES.size) {
            if (PAGES[i] == MetricPage.ALARMS) {
                return i
            }
        }
        0
    }
}
