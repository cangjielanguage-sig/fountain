/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.  
*/
package f_concurrent

import std.sync.{AtomicInt8, AtomicUInt8, AtomicInt16, AtomicUInt16, AtomicInt32, AtomicUInt32, AtomicInt64, AtomicUInt64}
import f_base.Integer

public interface AtomicInteger<N> where N <: Integer<N> {
    func fetchAdd(val: N): N
    func fetchSub(val: N): N
    func fetchAnd(val: N): N
    func fetchOr(val: N): N
    func fetchXor(val: N): N

    func fetchIncr(): N {
        fetchAdd(N.one)
    }
    func fetchDecr(): N {
        fetchSub(N.one)
    }
    func incrFetch(): N {
        addFetch(N.one)
    }
    func decrFetch(): N {
        subFetch(N.one)
    }

    func addFetch(val: N): N {
        fetchAdd(val) + val
    }
    func subFetch(val: N): N {
        fetchSub(val) - val
    }
    func andFetch(val: N): N {
        fetchAnd(val) & val
    }
    func orFetch(val: N): N {
        fetchOr(val) | val
    }
    func xorFetch(val: N): N {
        fetchXor(val) ^ val
    }
}

extend AtomicInt8 <: AtomicInteger<Int8> {}
extend AtomicUInt8 <: AtomicInteger<UInt8> {}
extend AtomicInt16 <: AtomicInteger<Int16> {}
extend AtomicUInt16 <: AtomicInteger<UInt16> {}
extend AtomicInt32 <: AtomicInteger<Int32> {}
extend AtomicUInt32 <: AtomicInteger<UInt32> {}
extend AtomicInt64 <: AtomicInteger<Int64> {}
extend AtomicUInt64 <: AtomicInteger<UInt64> {}
