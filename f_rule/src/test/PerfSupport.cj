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
package fountain::f_rule.test

import std.collection.{ArrayList, HashSet}
import std.fs.{File, Path}
import std.time.MonoTime
import fountain::f_rule.condition.{JoinConstraint, Operator, Pattern}
import fountain::f_rule.fact.{DynamicFact, TypeTag}
import fountain::f_rule.rule.{Rule, RuleSet, RuleSetBuilder}

/**
 * 性能门禁阈值（`doc/09-testing.md` §5）。
 *
 * 阈值是验收合同的一部分：调优只能改进实现，不能在这里放宽。
 */
public class PerfGate {
    public static let B01_BUILD_NANOS: Int64 = 500_000_000
    public static let B01_NODE_LIMIT: Int64 = 3000
    public static let B02_INSERT_NANOS: Int64 = 2_000_000_000
    public static let B03_INSERT_P95_NANOS: Int64 = 1_000_000
    public static let B04_RETRACT_NANOS: Int64 = 500_000_000
    public static let B05_RSS_BYTES: Int64 = 512 * 1024 * 1024
    public static let B06_REBUILD_NANOS: Int64 = 50_000_000
    public static let B07_TABLE_NANOS: Int64 = 300_000_000
}

/**
 * 采样结果（`doc/09-testing.md` §5 的测量纪律）。
 *
 * 采样值按升序保存；[percentile] 用最近秩（ceil(p*n)），不是 `max` 也不是均值。
 */
public class PerfStats {
    private let values_: Array<Int64>
    private let warmups_: Int64

    init(values: Array<Int64>, warmups: Int64) {
        this.values_ = PerfSupport.sorted(values)
        this.warmups_ = warmups
    }

    public func count(): Int64 {
        values_.size
    }

    public func warmups(): Int64 {
        warmups_
    }

    public func min(): Int64 {
        if (values_.size == 0) {
            return 0
        }
        values_[0]
    }

    public func max(): Int64 {
        if (values_.size == 0) {
            return 0
        }
        values_[values_.size - 1]
    }

    public func mean(): Int64 {
        if (values_.size == 0) {
            return 0
        }
        var total: Int64 = 0
        for (value in values_) {
            total += value
        }
        total / Int64(values_.size)
    }

    /** 最近秩分位数：`ceil(ratio * n)` 位（1 基），越界夹紧。 */
    public func percentile(ratio: Float64): Int64 {
        if (values_.size == 0) {
            return 0
        }
        let target = Float64(values_.size) * ratio
        var rank = Int64(target)
        if (Float64(rank) < target) {
            rank += 1
        }
        if (rank < 1) {
            rank = 1
        }
        if (rank > Int64(values_.size)) {
            rank = Int64(values_.size)
        }
        values_[rank - 1]
    }

    public func p50(): Int64 {
        percentile(0.5)
    }

    public func p95(): Int64 {
        percentile(0.95)
    }

    public func raw(): Array<Int64> {
        values_
    }
}

/** 采样与门禁工具；所有性能用例都走这里，保证测量口径一致。 */
public class PerfSupport {
    private init() {}

    /**
     * 先 warmup 再采样。
     *
     * warmup 不计入样本（覆盖 JIT/索引懒建/缓存预热），样本数记录在 [PerfStats] 里。
     */
    public static func measure(warmup: Int64, samples: Int64, body: () -> Unit): PerfStats {
        var i: Int64 = 0
        while (i < warmup) {
            body()
            i += 1
        }
        let values = ArrayList<Int64>()
        i = 0
        while (i < samples) {
            let start = MonoTime.now()
            body()
            let elapsed = (MonoTime.now() - start).toNanoseconds()
            values.add(elapsed)
            i += 1
        }
        PerfStats(values.toArray(), warmup)
    }

    /** 当前进程 RSS（字节）；读 `/proc/self/status` 的 `VmRSS`。 */
    public static func rssBytes(): Int64 {
        let text = String.fromUtf8(File.readFrom(Path("/proc/self/status")))
        for (line in text.split("\n")) {
            if (!line.startsWith("VmRSS:")) {
                continue
            }
            var number: Int64 = 0
            var seenDigit = false
            for (byte in line.toArray()) {
                if (byte >= 48 && byte <= 57) {
                    number = number * 10 + Int64(byte - 48)
                    seenDigit = true
                } else if (seenDigit) {
                    break
                }
            }
            return number * 1024
        }
        -1
    }

    /** 打印一行实测值，供 `doc/perf.md` 引用。 */
    public static func report(name: String, stats: PerfStats, detail!: String = ""): Unit {
        println("[BENCH] ${name} warmup=${stats.warmups()} samples=${stats.count()} " +
            "min=${millis(stats.min())}ms p50=${millis(stats.p50())}ms " +
            "p95=${millis(stats.p95())}ms max=${millis(stats.max())}ms ${detail}")
    }

    public static func millis(nanos: Int64): String {
        "${Float64(nanos) / 1_000_000.0}"
    }

    public static func requireAtMost(name: String, actual: Int64, limit: Int64, unit!: String = "ms"): Unit {
        if (actual > limit) {
            throw Exception(
                "门禁 ${name} 不达标：实测 ${millis(actual)}${unit} > 上限 ${millis(limit)}${unit}"
            )
        }
    }

    public static func requireBelow(name: String, actual: Int64, limit: Int64): Unit {
        if (actual >= limit) {
            throw Exception("门禁 ${name} 不达标：实测 ${actual} 未小于上限 ${limit}")
        }
    }

    /** 字符串排序（差分比对用，稳定升序）。 */
    public static func sortedKeys(values: ArrayList<String>): Array<String> {
        let items = ArrayList<String>()
        for (value in values) {
            items.add(value)
        }
        var i = 1
        while (i < items.size) {
            let current = items[i]
            var j = i - 1
            while (j >= 0 && items[j] > current) {
                items[j + 1] = items[j]
                j -= 1
            }
            items[j + 1] = current
            i += 1
        }
        items.toArray()
    }

    static func sorted(values: Array<Int64>): Array<Int64> {
        let items = ArrayList<Int64>()
        for (value in values) {
            items.add(value)
        }
        var i = 1
        while (i < items.size) {
            let current = items[i]
            var j = i - 1
            while (j >= 0 && items[j] > current) {
                items[j + 1] = items[j]
                j -= 1
            }
            items[j + 1] = current
            i += 1
        }
        items.toArray()
    }
}

/**
 * 规模夹具：1000 规则（每规则 2 模式）/ 10000 事实。
 *
 * 事实按 `(code, group)` 一一铺满 100×100 网格，规则按 1000 个互不相同的
 * `(code, group)` 组合登记，并用 `orderId` 等值连接两个模式。于是每条规则恰好
 * 命中一条事实（两个模式绑定同一实例），激活数 = 规则数，便于与朴素匹配逐条对账。
 *
 * 约束分布刻意让 alpha/beta 共享发生：100 个 `code` 等值签名、100 个 `group`
 * 等值签名被 1000 条规则复用，网络节点数远小于 2000 + 1000。
 */
public class PerfFixture {
    public static let TYPE: String = "PerfOrder"
    public static let CODES: Int64 = 100
    public static let GROUPS: Int64 = 100
    public static let FIELDS: Array<String> = ["orderId", "amount", "level", "code", "group"]

    private init() {}

    public static func code(index: Int64): String {
        "C${index}"
    }

    public static func group(index: Int64): String {
        "G${index}"
    }

    /** 规则 `i` 的两个模式签名。 */
    public static func pairOfRule(index: Int64): String {
        "${code(index % CODES)}|${group((index / 10) % GROUPS)}"
    }

    /** 事实 `index` 的 `(code, group)` 签名。 */
    public static func pairOfFact(index: Int64): String {
        "${code(index % CODES)}|${group((index / CODES) % GROUPS)}"
    }

    public static func rulePairs(count: Int64): HashSet<String> {
        let out = HashSet<String>()
        var i: Int64 = 0
        while (i < count) {
            out.add(pairOfRule(i))
            i += 1
        }
        out
    }

    /** 这些事实里会被规则集命中的条数（激活数）。 */
    public static func expectedActivations(ruleCount: Int64, factCount: Int64): Int64 {
        let pairs = rulePairs(ruleCount)
        var total: Int64 = 0
        var i: Int64 = 0
        while (i < factCount) {
            if (pairs.contains(pairOfFact(i))) {
                total += 1
            }
            i += 1
        }
        total
    }

    public static func rules(count: Int64): Array<Rule> {
        let out = ArrayList<Rule>()
        var i: Int64 = 0
        while (i < count) {
            let rule = Rule.builder("P${i}")
                .facts(TypeTag.DEFAULT_SPACE)
                .salience(i % 10)
                .addPattern(Pattern(TYPE, "a").constrain("code", Operator.Eq, code(i % CODES)))
                .addPattern(Pattern(TYPE, "b").constrain("group", Operator.Eq, group((i / 10) % GROUPS)))
                .join(JoinConstraint("a", "orderId", Operator.Eq, "b", "orderId"))
                .then({ ctx => ctx.set("hit", true) })
                .build()
            out.add(rule)
            i += 1
        }
        out.toArray()
    }

    public static func facts(count: Int64): Array<DynamicFact> {
        let out = ArrayList<DynamicFact>()
        var i: Int64 = 0
        while (i < count) {
            out.add(fact(i))
            i += 1
        }
        out.toArray()
    }

    /** 第 `index` 条事实；`index >= count` 时仍可用来构造增量插入的样本。 */
    public static func fact(index: Int64): DynamicFact {
        let fact = DynamicFact(TYPE)
        fact.set("orderId", index)
        fact.set("amount", (index * 7) % 1000)
        fact.set("level", index % 5)
        fact.set("code", code(index % CODES))
        fact.set("group", group((index / CODES) % GROUPS))
        fact
    }

    public static func ruleSet(id: String, count: Int64): RuleSet {
        let builder = RuleSetBuilder(id)
            .version("v1")
            .registerDynamicType(TypeTag.DEFAULT_SPACE, TYPE, FIELDS)
        for (rule in rules(count)) {
            let _ = builder.rule(rule)
        }
        builder.build()
    }
}
