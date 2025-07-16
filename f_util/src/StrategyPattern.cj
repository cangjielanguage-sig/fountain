/*
    Copyright (c) 2022 WuJingrun（吴京润）
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package f_util

import std.collection.{HashMap, ArrayList}
import f_exception.IllegalAccessException

/*
 * 策略模式的接口，所有策略都要实现此接口
 * N 是策略的标识，需要用N找到对应的策略，
 * S 是策略的具体实现，N与S需要一一对应
 * A 是执行策略的参数
 * R 是执行策略的结果
 */
public interface Strategy<N, A, R> where N <: Hashable & Equatable<N> {
    /**
     * 返回策略标识
     */
    prop name: N

    /**
     * 执行策略
     */
    func execute(arg: A): R
}

/*策略的集合*/
public class Strategies<N, A, R> where N <: Hashable & Equatable<N> {
    private let strategies = HashMap<N, Strategy<N, A, R>>()
    public init() {}

    /** 把指定策略注册进来*/
    public func register(strategy: Strategy<N, A, R>): Strategies<N, A, R> {
        strategies[strategy.name] = strategy
        this
    }
    public func register<S>(strategies: Iterable<S>): Unit where S <: Strategy<N, A, R> {
        for (s in strategies) {
            this.strategies[s.name] = s
        }
    }

    /**
     * 用指定的标识和参数执行策略，如果没有找到标识是name的策略会抛出base.IllegalAccessException
     */
    public func execute(name: N, arg: A): R {
        match (strategies.get(name)) {
            case Some(s) => s.execute(arg)
            case _ => throw IllegalAccessException("there is no strategy to match current condition")
        }
    }
}
