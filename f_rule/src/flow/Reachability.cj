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

import std.collection.{ArrayList, HashMap, HashSet}
import fountain::f_rule.exception.{RuleErrorCode, RuleException}

/**
 * 扇出可达性检查（`doc/06-flow-orchestration.md` §3.4，P-05）。
 *
 * `ImmediateDispatcher.dispatch()` 命中 `EndExecutor` 立即返回，剩余队列事件不会被清空，
 * 而是在下一次 `start()` 被重放——比"丢弃"更隐蔽。因此 `ResolveTask` 的每条子事件路径
 * 都必须在到达 End 之前汇入 `JoinTask`；本类在构建期做 BFS 拦截。
 */
public class Reachability {
    /**
     * 从每个扇出产出事件出发做 BFS；命中结束事件即抛 `FANOUT_WITHOUT_JOIN`。
     *
     * `edges` 只应包含 JoinTask 之前的边。JoinTask 的输出是遍历终点，调用方不要把
     * `join -> End` 这类合法边传进来。
     */
    public static func validate(productions: Array<Array<String>>, edges: Array<(String, String)>,
        endEvent: String): Unit {
        let graph = HashMap<String, ArrayList<String>>()
        for ((from, to) in edges) {
            let next = match (graph.get(from)) {
                case Some(found) => found
                case None =>
                    let created = ArrayList<String>()
                    graph[from] = created
                    created
            }
            next.add(to)
        }
        for (group in productions) {
            for (start in group) {
                visit(start, endEvent, graph)
            }
        }
    }

    /** 多个 JoinTask 的 branches 必须两两不重叠（`f_egraph` 同一事件只能注册一个执行器）。 */
    public static func validateJoinBranches(groups: Array<Array<String>>): Unit {
        let seen = HashSet<String>()
        for (group in groups) {
            for (branch in group) {
                if (seen.contains(branch)) {
                    throw RuleException(
                        RuleErrorCode.ILLEGAL_STATE,
                        "多个 JoinTask 共享分支事件 ${branch}，同一事件只能注册一个执行器"
                    )
                }
                seen.add(branch)
            }
        }
    }

    private static func visit(start: String, endEvent: String,
        graph: HashMap<String, ArrayList<String>>): Unit {
        let visited = HashSet<String>()
        let queue = ArrayList<String>()
        queue.add(start)
        while (queue.size > 0) {
            let node = queue.remove(at: 0)
            if (node == endEvent) {
                throw RuleException(
                    RuleErrorCode.FANOUT_WITHOUT_JOIN,
                    "扇出分支 '${start}' 存在直达 ${endEvent} 的路径；扇出必须先汇入 JoinTask"
                )
            }
            if (visited.contains(node)) {
                continue
            }
            visited.add(node)
            match (graph.get(node)) {
                case Some(next) =>
                    for (target in next) {
                        if (!visited.contains(target)) {
                            queue.add(target)
                        }
                    }
                case None => ()
            }
        }
    }
}
