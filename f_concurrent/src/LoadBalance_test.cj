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
package fountain::f_concurrent

import std.collection.TreeMap
import std.unittest.*
import std.unittest.testmacro.*

/**
 * 负载均衡的取值语义（见 .autocode/bugs/bug.md）：
 *
 * `LoadBalance` 的 TreeMap 以各节点的**累计权重**为键：K_i = w_1 + ... + w_i；取节点用
 * `tree.forward(v, inclusive: true)` 找第一个键 >= v ⇒ 节点 i 的「桶」是 (K_{i-1}, K_i]。
 * 所以算法给出的 v 必须落在累计区间内、并打进桶的内部（落在桶边界上会归给前一个节点）。
 *
 * RPC 客户端（`RPCClient.call`）用 `for(client in multiClient)` 取**第一个**节点发请求 ⇒
 * 等价于本用例的 `pick()`（迭代器的第一个元素）。
 */
@Test
public class LoadBalanceTest {
    private static let names = ['A', 'B', 'C', 'D']

    /** 等价于 `RPCClient.call` 的取节点方式：取迭代器的第一个元素。 */
    private static func pick(lb: LoadBalance<Float64, Unit, String>): String {
        let f = lb.iterator().next().getOrThrow()
        f(())
    }
    private static func count(lb: LoadBalance<Float64, Unit, String>, rounds: Int64): TreeMap<String, Int64> {
        let counts = TreeMap<String, Int64>()
        for (_ in 0..rounds) {
            let name = pick(lb)
            counts[name] = (counts.get(name) ?? 0) + 1
        }
        counts
    }
    private static func sequence(lb: LoadBalance<Float64, Unit, String>, rounds: Int64): String {
        let sb = StringBuilder()
        for (_ in 0..rounds) {
            sb.append(pick(lb))
        }
        sb.toString()
    }
    /**
     * 按 `ClientConfig.createClient` 的接线构造轮询：step=1.0、从桶中点 0.5 起步、上界 Σw。
     */
    private static func roundRobin(weights: Array<Float64>): LoadBalance<Float64, Unit, String> {
        var sum = 0.0f64
        for (w in weights) {
            sum += w
        }
        let lb = LoadBalance<Float64, Unit, String>(0.0f64, RoundRobin<Float64>(1.0f64, 0.5f64, sum))
        for (i in 0..weights.size) {
            let name = names[i]
            lb.add(weights[i]) {_ => name}
        }
        lb
    }
    /** 按 `ClientConfig.createClient` 的接线构造随机：在 (0, Σw) 上均匀取值。 */
    private static func random(weights: Array<Float64>): LoadBalance<Float64, Unit, String> {
        var sum = 0.0f64
        for (w in weights) {
            sum += w
        }
        let lb = LoadBalance<Float64, Unit, String>(0.0f64, Float64Weight(0.0f64, sum))
        for (i in 0..weights.size) {
            let name = names[i]
            lb.add(weights[i]) {_ => name}
        }
        lb
    }

    /**
     * 迭代必须从「算法选定的位置」开始。修前 `LoadBalanceIterator` 读的是整棵树（按键升序），
     * 算法选择被完全忽略 ⇒ 每次都命中第一个节点（实测 A=100/B=0）。
     */
    @TestCase
    public func testRoundRobinMustFollowAlgoChoice() {
        @Assert(sequence(roundRobin([1.0f64, 1.0f64]), 6), 'ABABAB')
        @Assert(sequence(roundRobin([2.0f64, 1.0f64]), 6), 'AABAAB')
    }
    /** 等权轮询：100 次调用应 50/50。 */
    @TestCase
    public func testRoundRobinEqualWeights() {
        let counts = count(roundRobin([1.0f64, 1.0f64]), 100)
        @Assert(counts['A'], 50)
        @Assert(counts['B'], 50)
    }
    /** 2:1 权重轮询：100 次调用应 67/33。 */
    @TestCase
    public func testRoundRobinWeightedTwoToOne() {
        let counts = count(roundRobin([2.0f64, 1.0f64]), 100)
        @Assert(counts['A'], 67)
        @Assert(counts['B'], 33)
    }
    /** 4:1 权重轮询：100 次调用应 80/20。 */
    @TestCase
    public func testRoundRobinWeightedFourToOne() {
        let counts = count(roundRobin([4.0f64, 1.0f64]), 100)
        @Assert(counts['A'], 80)
        @Assert(counts['B'], 20)
    }
    /** 等权随机：1000 次调用应大致 50/50。 */
    @TestCase
    public func testRandomEqualWeights() {
        let counts = count(random([1.0f64, 1.0f64]), 1000)
        let a = counts['A']
        @Assert(a >= 400 && a <= 600)
    }
    /**
     * 2:1 权重随机：1000 次调用应大致 67/33。
     * 修前 `Float64Weight` 用 `closed: true`（浮点被 +1.0 ⇒ 区间变成 [min, max+1)），
     * 命中率是 75/25。
     */
    @TestCase
    public func testRandomWeightedTwoToOne() {
        let counts = count(random([2.0f64, 1.0f64]), 1000)
        let a = counts['A']
        @Assert(a >= 580 && a <= 750)
    }
}
