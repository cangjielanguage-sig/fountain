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

public struct Equaler<T> {
    public Equaler(private let eq: (T, T) -> Bool) {}

    public static func equals<T>(left: T, right: T): Bool where T <: Equal<T> {
        left == right
    }
    public static func create<T>() where T <: Equal<T> {
        Equaler<T>(equals<T>)
    }
    public operator func ()(left: T, right: T): Bool {
        eq(left, right)
    }
    public func then(equal: (T, T) -> Bool): Equaler<T> {
        Equaler<T> {
            left, right => match (this.eq(left, right)) {
                case true => equal(left, right)
                case _ => false
            }
        }
    }
    public func then(equal: Equaler<T>): Equaler<T> {
        Equaler<T> {
            left, right => match (this.eq(left, right)) {
                case true => equal(left, right)
                case _ => false
            }
        }
    }
    public static func equalling<O, T>(mapper: (O) -> T): Equaler<O> where T <: Equal<T> {
        Equaler<O> {
            left, right => mapper(left) == mapper(right)
        }
    }
    public static func equalling<O, T>(mapper: (O) -> T, equal: (T, T) -> Bool): Equaler<O> {
        Equaler<O> {
            left, right => equal(mapper(left), mapper(right))
        }
    }
    public static func equalling<O, T>(mapper: (O) -> T, equal: Equaler<T>): Equaler<O> {
        Equaler<O> {
            left, right => equal(mapper(left), mapper(right))
        }
    }
    public func then<O>(mapper: (T) -> O, equal: (O, O) -> Bool): Equaler<T> {
        Equaler<T> {
            left, right => match (this.eq(left, right)) {
                case true => equal(mapper(left), mapper(right))
                case _ => false
            }
        }
    }
    public func then<O>(mapper: (T) -> O, equal: Equaler<O>): Equaler<T> {
        Equaler<T> {
            left, right => match (this.eq(left, right)) {
                case true => equal(mapper(left), mapper(right))
                case _ => false
            }
        }
    }
}
