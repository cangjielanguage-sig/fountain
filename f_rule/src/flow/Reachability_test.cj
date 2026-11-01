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
package fountain::f_rule.flow

import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_rule.exception.{RuleErrorCode, RuleException}

/**
 * 扇出可达性（`doc/06-flow-orchestration.md` §3.4，P-05）。
 *
 * `f_egraph` 的 dispatcher 遇到 End 立即返回，剩余队列事件会在下一次 `start()` 重放；
 * 因此扇出的每条分支都必须先汇入 `JoinTask`，构建期就要拦截直达 End 的路径。
 */
@Test
class Reachability_test {
    private func codeOf(action: () -> Unit): RuleErrorCode {
        var caught = RuleErrorCode.CLOSED
        try {
            action()
        } catch (e: RuleException) {
            caught = e.code
        }
        caught
    }

    /** 分支直达 End → `FANOUT_WITHOUT_JOIN`。 */
    @TestCase
    public func branchReachingEndIsRejected(): Unit {
        let code = codeOf({ =>
            Reachability.validate([["order.priced.check", "user.level.check"]],
                [("order.priced.check", "End")], "End")
        })
        @Expect(code, RuleErrorCode.FANOUT_WITHOUT_JOIN)
    }

    /** 间接路径到达 End 同样拒绝。 */
    @TestCase
    public func indirectPathToEndIsRejected(): Unit {
        let code = codeOf({ =>
            Reachability.validate([["a", "b"]],
                [("a", "x"), ("x", "End"), ("b", "y")], "End")
        })
        @Expect(code, RuleErrorCode.FANOUT_WITHOUT_JOIN)
    }

    /** 两个 JoinTask 的 branches 重叠 → `ILLEGAL_STATE`。 */
    @TestCase
    public func overlappingJoinBranchesAreRejected(): Unit {
        let code = codeOf({ =>
            Reachability.validateJoinBranches([["a", "b"], ["b", "c"]])
        })
        @Expect(code, RuleErrorCode.ILLEGAL_STATE)
    }

    /** 合法编排：扇出分支都汇入同一个 Join，Join 之前无 End 路径。 */
    @TestCase
    public func legalFanoutWithJoinPasses(): Unit {
        @Expect(codeOf({ =>
            Reachability.validate([["order.priced.check", "user.level.check"]],
                [("order.priced.check", "join"), ("user.level.check", "join")], "End")
            Reachability.validateJoinBranches([
                ["order.bulk.done", "user.level.done"],
                ["order.other.done"]
            ])
        }), RuleErrorCode.CLOSED)
    }
}
