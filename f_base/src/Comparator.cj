/*
   Copyright (c) 2022 WuJingrun（吴京润）
   fountain is licensed under Mulan PSL v2.
   You can use this software according to the terms and conditions of the Mulan PSL v2.
   You may obtain a copy of Mulan PSL v2 at:
           http://license.coscl.org.cn/MulanPSL2
   THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
   See the Mulan PSL v2 for more details.
 */

package f_base

public struct Comparator<T> {
    public Comparator(public let comparator: (T, T) -> Ordering) {}

    public static func compare<T>(left: T, right: T): Ordering where T <: Comparable<T> {
        left.compare(right)
    }
    public static func create<T>() where T <: Comparable<T> {
        Comparator<T>(compare<T>)
    }
    public operator func ()(left: T, right: T): Ordering {
        comparator(left, right)
    }
    public func reverse(): Comparator<T> {
        Comparator<T> {
            left, right => match (comparator(left, right)) {
                case LT => GT
                case GT => LT
                case EQ => EQ
            }
        }
    }
    public func then(comparator: (T, T) -> Ordering): Comparator<T> {
        Comparator<T> {
            left, right => match (this.comparator(left, right)) {
                case EQ => comparator(left, right)
                case x => x
            }
        }
    }
    public func then(comparator: Comparator<T>): Comparator<T> {
        Comparator<T> {
            left, right => match (this.comparator(left, right)) {
                case EQ => comparator(left, right)
                case x => x
            }
        }
    }
    public static func comparing<O, T>(mapper: (O) -> T): Comparator<O> where T <: Comparable<T> {
        Comparator<O> {
            left, right => mapper(left).compare(mapper(right))
        }
    }
    public static func comparing<O, T>(mapper: (O) -> T, comparator: (T, T) -> Ordering): Comparator<O> {
        Comparator<O> {
            left, right => comparator(mapper(left), mapper(right))
        }
    }
    public static func comparing<O>(mapper: (O) -> T, comparator: Comparator<T>): Comparator<O> {
        Comparator<O> {
            left, right => comparator(mapper(left), mapper(right))
        }
    }
    public func then<O>(mapper: (T) -> O, comparator: (O, O) -> Ordering): Comparator<T> {
        Comparator<T> {
            left, right => match (this.comparator(left, right)) {
                case EQ => comparator(mapper(left), mapper(right))
                case x => x
            }
        }
    }
    public func then<O>(mapper: (T) -> O, comparator: Comparator<O>): Comparator<T> {
        Comparator<T> {
            left, right => match (this.comparator(left, right)) {
                case EQ => comparator(mapper(left), mapper(right))
                case x => x
            }
        }
    }
}
