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

import std.reflect.TypeInfo

public class AsyncIterator<T> <: Iterator<Future<?T>> {
    public AsyncIterator(private let itr: Iterator<T>) {}
    public func next(): ?Future<?T> {
        spawn {
            itr.next()
        }
    }
}
public class OfTypeIterator<T, R> <: Iterator<R> {
    public OfTypeIterator(private let itr: Iterator<T>){}
    public func next(): ?R {
        for(v in itr where v is R){
            return v as R
        }
        None
    }
}
public interface ExtendIterator<T> {
    func async(): Iterator<Future<?T>>
    func min(cmp: (T, T) -> Ordering): ?T
    func max(cmp: (T, T) -> Ordering): ?T
    func filterType<R>(): Iterator<R>
    func flatten<R>(toThrow!: Bool): Iterator<R>
}

extend<T> Iterator<T> <: ExtendIterator<T> {
    public func async(): Iterator<Future<?T>> {
        AsyncIterator<T>(this)
    }
    public func min(cmp: (T, T) -> Ordering): ?T {
        var r = None<T>
        for(v in this where r.isNone() || cmp(v, r.getOrThrow()) == LT){
            r = v
        }
        r
    }
    public func max(cmp: (T, T) -> Ordering): ?T {
        var r = None<T>
        for(v in this where r.isNone() || cmp(v, r.getOrThrow()) == GT){
            r = v
        }
        r
    }
    public func filterType<R>(): Iterator<R> {
        OfTypeIterator<T, R>(this)
    }
    public func flatten<R>(toThrow!: Bool = true): Iterator<R> {
        if (toThrow) {
            flatMap<R> {
                v => match (v) {
                    case x: Iterator<R> => x
                    case _ => throw IllegalArgumentException(
                        '${TypeInfo.of<T>()} does not match ${TypeInfo.of<Iterator<R>>()}')
                }
            }
        } else {
            flatMap<R> {
                v => match (v) {
                    case x: Iterator<R> => x
                    case _ => EmptyIterator<R>.INSTANCE
                }
            }
        }
    }
}
