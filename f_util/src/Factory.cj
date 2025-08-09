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
package f_util

import std.collection.HashMap
import f_exception.IllegalAccessException

public interface Producer<N, A, O> where N <: Hashable & Equatable<N> {
    prop name: N
    func produce(): O {
        throw IllegalAccessException("unimplemented")
    }
    func produce(arg: A): O {
        throw IllegalAccessException("unimplemented")
    }
}

public class Factory<N, A, O> where N <: Hashable & Equatable<N> {
    private let producers = HashMap<N, Producer<N, A, O>>()

    public func assemble(producer: Producer<N, A, O>): Unit {
        producers.add(producer.name, producer)
    }
    public func assemble(producers: Iterable<Producer<N, A, O>>): Unit {
        for (producer in producers) {
            assemble(producer)
        }
    }
    public func produce(name: N): O {
        producers[name].produce()
    }
    public func produce(name: N, arg: A): O {
        producers[name].produce(arg)
    }
}
