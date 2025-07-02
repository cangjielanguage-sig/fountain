/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
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
