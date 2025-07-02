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

public class Mediator<N, C, A, R> where C <: Colleague<N, A, R>, A <: ColleagueArgument<N>, N <: Hashable & Equatable<N> {
    private let colleagues = HashMap<N, Colleague<N, A, R>>()
    public func register(colleague: Colleague<N, A, R>) {
        colleagues[colleague.name] = colleague
    }
    public func execute(arg: A): R {
        colleagues[arg.name].execute(arg)
    }
}

public interface Colleague<N, A, R> where A <: ColleagueArgument<N>, N <: Hashable & Equatable<N> {
    prop name: N
    func execute(arg: A): R
}

public interface ColleagueArgument<N> where N <: Hashable & Equatable<N> {
    prop name: N
}
