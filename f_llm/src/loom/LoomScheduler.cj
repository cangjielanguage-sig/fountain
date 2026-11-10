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
package fountain::f_llm.loom

import fountain::f_ticktock.*

/**
 * 调度抽象：把 `scheduleCreate` / `scheduleDelete` 与 `f_ticktock` 解耦，便于测试注入。
 *
 * cron 采用 `f_ticktock` 的七段式：`秒 分 时 天 月 星期 年`，通配符只支持 `*`。
 */
public interface LoomScheduler {
    func schedule(name: String, cron: String, body: () -> Unit): Unit
    func cancel(name: String): Unit
}

/** 默认实现：落到 `f_ticktock.Ticktock` 的单例调度器 */
public class TicktockScheduler <: LoomScheduler {
    private let ticktock: Ticktock

    public init() {
        this.ticktock = Ticktock.getInstance().getOrThrow()
    }

    public init(ticktock: Ticktock) {
        this.ticktock = ticktock
    }

    public func schedule(name: String, cron: String, body: () -> Unit): Unit {
        ticktock.addOrReplaceTask(
            FuncCronTicktockTask(taskName: name, taskCron: cron, executor: body))
    }

    public func cancel(name: String): Unit {
        ticktock.removeTask(name)
    }
}

/** 进程级持有者：装配时安装，工具调用时取用 */
public class LoomSchedules {
    private static var scheduler: ?LoomScheduler = None

    private init() {
    }

    public static func install(value: LoomScheduler): Unit {
        scheduler = Some(value)
    }

    public static func current(): ?LoomScheduler {
        scheduler
    }

    public static func reset(): Unit {
        scheduler = None
    }
}
