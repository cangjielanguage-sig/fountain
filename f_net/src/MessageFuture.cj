/*
Copyright (c) 2025 WuJingrun（吴京润）

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
package fountain::f_net

import std.sync.Mutex

public struct MessageFuture<DE>{
    private let mutex = Mutex()
    private var ref = None<DE>
    private let condition = synchronized(mutex){
        mutex.condition()
    }
    mut func set(data: DE): Unit {
        synchronized(mutex){
            ref = data
            condition.notify()
        }
    }
    public func get(): DE {
        synchronized(mutex){
            if(let Some(d) <- ref){
                d
            }else{
                condition.wait()
                ref.getOrThrow()
            }
        }
    }
    public func tryGet(): ?DE {
        synchronized(mutex){
            ref
        }
    }
    public func tryGet(timeout: Duration): ?DE {
        synchronized(mutex){
            if(let Some(d) <- ref){
                d
            }else{
                condition.wait(timeout: timeout)
                ref
            }
        }
    }
}