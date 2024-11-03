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

/* 此类一般只作为局部变量使用，不会发生逃逸
   仓颉已支持类实例的逃逸分析和栈上分配
   按照HashBuilder_test的简单性能测试。
 */
public class HashBuilder {
    private static const coefficient: Int64 = 131
    private static const initHash = 71
    private var hashed = initHash

    /**
      * 调用一次，本类的实例回到初始状态
      */
    public func finish(): Int64 {
        let h = hashed
        hashed = initHash
        h
    }

    @OverflowWrapping
    public func append(arg: Int64): HashBuilder {
        hashed = hashed * coefficient + arg
        this
    }
    public func append<T>(arg: T): HashBuilder where T <: Hashable {
        append(arg.hashCode())
    }
    public func append(arg: Int8): HashBuilder {
        append(arg.hashCode())
    }
    public func append(arg: UInt8): HashBuilder {
        append(arg.hashCode())
    }
    public func append(arg: Int16): HashBuilder {
        append(arg.hashCode())
    }
    public func append(arg: UInt16): HashBuilder {
        append(arg.hashCode())
    }
    public func append(arg: Int32): HashBuilder {
        append(arg.hashCode())
    }
    public func append(arg: UInt32): HashBuilder {
        append(arg.hashCode())
    }
    public func append(arg: UInt64): HashBuilder {
        append(arg.hashCode())
    }
    public func append(arg: Float64): HashBuilder {
        append(arg.hashCode())
    }
    public func append(arg: Float32): HashBuilder {
        append(arg.hashCode())
    }
    public func append(arg: Float16): HashBuilder {
        append(arg.hashCode())
    }
    public func append(arg: Rune): HashBuilder {
        append(arg.hashCode())
    }
    public func append(arg: Bool): HashBuilder {
        append(arg.hashCode())
    }

    public func append<T>(args: Iterable<T>): HashBuilder where T <: Hashable {
        match (args) {
            case x: Hashable => append(x.hashCode())
            case _ =>
                for (arg in args) {
                    append(arg.hashCode())
                }
                this
        }
    }
    public func append<T>(args: Array<T>): HashBuilder where T <: Hashable {
        let itr: Iterable<T> = args
        append<T>(itr)
    }
    public func append(args: Array<Hashable>): HashBuilder {
        append<Hashable>(args)
    }
    public func append(arg: String): HashBuilder {
        append(arg.hashCode())
    }
    public func append(arg: StringBuilder): HashBuilder {
        append(arg.toString())
    }
    public func append(args: Iterable<Hashable>): HashBuilder {
        append<Hashable>(args)
    }
}
