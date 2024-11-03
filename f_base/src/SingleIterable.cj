/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package f_base

public class SingleIterable<T> <: Iterable<T> {
    public SingleIterable(private let value: T) {}
    public func iterator(): Iterator<T> {
        SingleIterator<T>(value)
    }
}
public class SingleIterator<T> <: Iterator<T> {
    public SingleIterator(private let value: T) {}
    private var got = false

    public func next(): Option<T> {
        if (got) {
            None<T>
        } else {
            got = true
            value
        }
    }
}
