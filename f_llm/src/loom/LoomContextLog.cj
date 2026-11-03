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

import std.collection.*
import std.sync.*

/** 一次模型交互（临时上下文的一条记录） */
public class LlmTurn {
    public let model: String
    public let system: String
    public let input: String
    public let output: String

    public init(model: String, system: String, input: String, output: String) {
        this.model = model
        this.system = system
        this.input = input
        this.output = output
    }
}

class TurnsBox {
    public var value: ArrayList<LlmTurn> = ArrayList<LlmTurn>()
}

class BoolValue {
    public var value: Bool = false
}

/**
 * 流程执行期的临时上下文：每次与大模型交互都记一条。
 *
 * 生命周期严格绑在一次流程执行上：`LoomRunner` 开始时 `begin()`，结束时 `snapshot()` + `clear()`
 * 并把快照交给记忆提取；不参与执行的模型调用（比如提取阶段的总结）不会被记录——那时候已经清空。
 */
public class LoomContextLog {
    private static let mutex = Mutex()
    private static var turns = ArrayList<LlmTurn>()
    private static var active = false

    private init() {
    }

    public static func begin(): Unit {
        synchronized(mutex){
            turns = ArrayList<LlmTurn>()
            active = true
        }
    }

    /** 未激活时直接丢弃，避免把流程外的调用混进来 */
    public static func record(turn: LlmTurn): Unit {
        synchronized(mutex){
            if(active){
                turns.add(turn)
            }
        }
    }

    public static func snapshot(): ArrayList<LlmTurn> {
        let box = TurnsBox()
        synchronized(mutex){
            box.value = turns.clone()
        }
        box.value
    }

    public static func clear(): Unit {
        synchronized(mutex){
            turns = ArrayList<LlmTurn>()
            active = false
        }
    }

    public static func isActive(): Bool {
        let box = BoolValue()
        synchronized(mutex){
            box.value = active
        }
        box.value
    }
}
