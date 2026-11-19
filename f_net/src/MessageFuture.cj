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
import std.time.MonoTime

public class MessageFuture<DE> {
    private let mutex = Mutex()
    private var ref = None<DE>
    
    private var failure = None<Exception>

    private let condition = synchronized(mutex){
        mutex.condition()
    }
    func set(data: DE): Unit {
        synchronized(mutex){
            if (failure.isNone()) {
                ref = data
                condition.notifyAll()
            }
        }
    }
    func fail(error: Exception): Unit {
        synchronized(mutex) {
            if (ref.isNone() && failure.isNone()) {
                failure = Some(error)
                condition.notifyAll()
            }
        }
    }
    private func result(): ?DE {
        if (let Some(error) <- failure) { throw error }
        ref
    }
    public func get(): DE {
        synchronized(mutex){
            while (ref.isNone() && failure.isNone()) {
                condition.wait()
            }
            result().getOrThrow()
        }
    }
    public func tryGet(): ?DE {
        synchronized(mutex){
            result()
        }
    }
    public func tryGet(timeout: Duration): ?DE {
        synchronized(mutex){
            let deadline = MonoTime.now() + timeout
            while (ref.isNone() && failure.isNone()) {
                let remaining = deadline - MonoTime.now()
                if (remaining <= Duration.Zero) { break }
                condition.wait(timeout: remaining)
            }
            result()
        }
    }
}
