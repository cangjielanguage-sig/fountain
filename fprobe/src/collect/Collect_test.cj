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
package fountain::fprobe.collect

import std.math.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
public class IntervalCounter_test {
    @TestCase
    public func firstSampleOnlyRecordsBaseline(): Unit {
        let counter = IntervalCounter()
        @Assert(counter.update(1000, 1000).isNone())
    }

    @TestCase
    public func rateIsDeltaPerSecond(): Unit {
        let counter = IntervalCounter()
        counter.update(1000, 1000)
        let rate = counter.update(3000, 2000)
        @Assert(rate.isSome())
        @Assert(abs(rate.getOrThrow() - 2000.0) < 1e-9)
    }

    @TestCase
    public func zeroIntervalReturnsNone(): Unit {
        let counter = IntervalCounter()
        counter.update(100, 1000)
        @Assert(counter.update(200, 1000).isNone())
    }

    /** 计数回绕（当前值小于上次值）不得产生负速率。 */
    @TestCase
    public func wrappedCounterDoesNotProduceNegativeRate(): Unit {
        let counter = IntervalCounter()
        counter.update(1000, 1000)
        let rate = counter.update(10, 2000)
        @Assert(rate.isSome())
        @Assert(rate.getOrThrow() == 0.0)
        // 回绕后的计数成为新基线
        let next = counter.update(210, 3000)
        @Assert(abs(next.getOrThrow() - 200.0) < 1e-9)
    }
}

@Test
public class MetricProjection_test {
    private static let sample = '''
{"mounts":[{"usedPercent":10},{"usedPercent":80},{"usedPercent":40}]}
'''


    @TestCase
    public func maxOverArray(): Unit {
        let projection = MetricProjection("disk", "mount.maxUsedPercent", "$.mounts[*].usedPercent",
            aggregation: Aggregation.Max, unit: "%")
        let value = projection.evaluate(sample)
        @Assert(value.isSome())
        @Assert(value.getOrThrow() == 80.0)
        @Assert(projection.unit == "%")
        @Assert(projection.key() == "disk.mount.maxUsedPercent")
    }

    @TestCase
    public func sumOverArray(): Unit {
        let projection = MetricProjection("disk", "mount.totalUsedPercent", "$.mounts[*].usedPercent",
            aggregation: Aggregation.Sum)
        @Assert(projection.evaluate(sample).getOrThrow() == 130.0)
    }

    @TestCase
    public func averageOverArray(): Unit {
        let projection = MetricProjection("disk", "mount.avgUsedPercent", "$.mounts[*].usedPercent",
            aggregation: Aggregation.Avg)
        @Assert(abs(projection.evaluate(sample).getOrThrow() - 130.0 / 3.0) < 1e-9)
    }

    @TestCase
    public func firstReturnsHeadElement(): Unit {
        let projection = MetricProjection("disk", "mount.firstUsedPercent", "$.mounts[*].usedPercent")
        @Assert(projection.evaluate(sample).getOrThrow() == 10.0)
    }

    @TestCase
    public func emptyArrayReturnsNone(): Unit {
        let projection = MetricProjection("disk", "mount.maxUsedPercent", "$.mounts[*].usedPercent",
            aggregation: Aggregation.Max)
        @Assert(projection.evaluate('{"mounts":[]}').isNone())
    }

    @TestCase
    public func missingPathReturnsNone(): Unit {
        let projection = MetricProjection("disk", "mount.maxUsedPercent", "$.mounts[*].usedPercent")
        @Assert(projection.evaluate('{"other":1}').isNone())
    }

    @TestCase
    public func invalidJsonReturnsNone(): Unit {
        let projection = MetricProjection("disk", "mount.maxUsedPercent", "$.mounts[*].usedPercent")
        @Assert(projection.evaluate("not-json").isNone())
    }

    @TestCase
    public func aggregationParsesNames(): Unit {
        @Assert(Aggregation.parse("first").getOrThrow(), Aggregation.First)
        @Assert(Aggregation.parse("max").getOrThrow(), Aggregation.Max)
        @Assert(Aggregation.parse("sum").getOrThrow(), Aggregation.Sum)
        @Assert(Aggregation.parse("avg").getOrThrow(), Aggregation.Avg)
        @Assert(Aggregation.parse("bogus").isNone())
    }
}
