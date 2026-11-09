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

import std.unittest.*
import std.unittest.testmacro.*

/** 12.1：ViewModel 的节点选择与分页都是纯函数，可在无终端环境下断言。 */
@Test
public class ViewModel_test {
    @TestCase
    public func emptyHasNoSelectionAndStartsOnCpu(): Unit {
        let view = ViewModel.empty()
        @Assert(view.nodes.isEmpty())
        @Assert(view.selectedNode().isNone())
        @Assert(view.page(), MetricPage.CPU)
        @Assert(view.pageNumber(), 1)
        @Assert(view.pageCount(), 8)
    }

    @TestCase
    public func withNodesClampsOutOfRangeSelection(): Unit {
        let view = ViewModel(["a", "b"], 9, 0, 0)
        @Assert(view.selectedNode().getOrThrow(), "b")
        let empty = view.withNodes([])
        @Assert(empty.selectedNode().isNone())
    }

    @TestCase
    public func selectNextMovesDownAndStopsAtLast(): Unit {
        var view = ViewModel(["a", "b", "c"], 0, 0, 0)
        view = view.selectNext()
        @Assert(view.selectedNode().getOrThrow(), "b")
        view = view.selectNext()
        view = view.selectNext()
        @Assert(view.selectedNode().getOrThrow(), "c")
    }

    @TestCase
    public func selectPreviousStopsAtFirst(): Unit {
        var view = ViewModel(["a", "b"], 1, 0, 0)
        view = view.selectPrevious()
        @Assert(view.selectedNode().getOrThrow(), "a")
        view = view.selectPrevious()
        @Assert(view.selectedNode().getOrThrow(), "a")
    }

    @TestCase
    public func tabMovesToNextPageAndWraps(): Unit {
        var view = ViewModel.empty()
        view = view.nextPage()
        @Assert(view.page(), MetricPage.MEMORY)
        for (_ in 0..7) {
            view = view.nextPage()
        }
        @Assert(view.page(), MetricPage.CPU)
        @Assert(view.pageNumber(), 1)
    }

    @TestCase
    public func shiftTabMovesBackwardsAndWraps(): Unit {
        var view = ViewModel.empty()
        view = view.previousPage()
        @Assert(view.page(), MetricPage.ALARMS)
        view = view.previousPage()
        @Assert(view.page(), MetricPage.TOPOLOGY)
    }

    @TestCase
    public func alarmKeyJumpsToAlarmPage(): Unit {
        let view = ViewModel.empty().showAlarms()
        @Assert(view.page(), MetricPage.ALARMS)
    }

    @TestCase
    public func alarmCountIsKeptAcrossNavigation(): Unit {
        var view = ViewModel.empty().withAlarmCount(3)
        view = view.nextPage().selectNext()
        @Assert(view.alarmCount, 3)
    }
}
