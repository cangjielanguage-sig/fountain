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

import std.sync.*
import std.time.*

class TimeoutBox {
    public var done: Bool = false
    public var value: String = ''
    public var error: String = ''
}

/**
 * 带超时的调用包装。
 *
 * Cangjie 无法强杀线程，所以超时的语义是「**调用方按时返回**，被调用方在后台自行结束」——
 * 对 loom 来说够用：步骤失败会被流程记为错误，不会把整个流程挂死。
 */
public class LoomTimeout {
    private init() {
    }

    /** @return 正常时返回结果；超时返回 `timeout after Nms`；异常返回 `error: …` */
    public static func call(action: () -> String, timeoutMs: Int64): String {
        let box = TimeoutBox()
        spawn { =>
            try{
                box.value = action()
            }catch(error: Exception){
                box.error = error.message
            }
            box.done = true
        }
        var waited: Int64 = 0
        while(!box.done && waited < timeoutMs){
            sleep(Duration.millisecond * 10)
            waited += 10
        }
        if(!box.done){
            return 'timeout after ${timeoutMs}ms'
        }
        if(!box.error.isEmpty()){
            return 'error: ${box.error}'
        }
        box.value
    }
}
