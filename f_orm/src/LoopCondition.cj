/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package f_orm

import f_base.StringGenerator
import f_orm.exception.ORMException

public class LoopCondition<I, T> where I <: Iterable<T> {
    private var _wrapLeft = ''
    private var _wrapRight = ''
    private var _trimLeft = ''
    private var _trimRight = ''
    private var _delimiter = ''
    private var _argInSql = false
    private var _condition: (T, Int64) -> Bool = {v, i => true}
    private var _partial: (T, Int64) -> (String, Any) = {
        v, i => throw ORMException('partial for loop is not specified')
    }

    LoopCondition(private let values: I, private let executor: SqlExecutor) {}

    public func wrap(left: String, right: String): LoopCondition<I, T> {
        _wrapLeft = left
        _wrapRight = right
        this
    }
    public func wrapLeft(left: String): LoopCondition<I, T> {
        _wrapLeft = left
        this
    }
    public func wrapRight(right: String): LoopCondition<I, T> {
        _wrapRight = right
        this
    }
    public func trim(left: String, right: String): LoopCondition<I, T> {
        _trimLeft = left
        _trimRight = right
        this
    }
    public func trimLeft(left: String): LoopCondition<I, T> {
        _trimLeft = left
        this
    }
    public func trimRight(right: String): LoopCondition<I, T> {
        _trimRight = right
        this
    }
    public func delimiter(d: String): LoopCondition<I, T> {
        _delimiter = d
        this
    }
    public prop argInSql: LoopCondition<I, T> {
        get() {
            _argInSql = true
            this
        }
    }
    public func condition(cond: (T, Int64) -> Bool): LoopCondition<I, T> {
        _condition = cond
        this
    }
    public func partial(partial: (T, Int64) -> (String, Any)): LoopCondition<I, T> {
        _partial = partial
        this
    }
    public func partial(partial: (T, Int64) -> Any): LoopCondition<I, T> {
        func callee(v: T, i: Int64): (String, Any) {
            ('', partial(v, i))
        }
        this.partial(callee)
    }
    public func done(): String {
        let sqlFrag = Condition.trim(prefix: _trimLeft, suffix: _trimRight) {
            let builder = StringGenerator()
            var i = 0
            for (v in values where _condition(v, i)) {
                if (builder.size > 0) {
                    builder.append(' ')
                    builder.append(_delimiter)
                    builder.append(' ')
                }
                let (frag, arg) = _partial(v, i)
                builder.append(frag)
                if (_argInSql) {
                    match (arg) {
                        case x: ToString => builder.append(x)
                        case x =>
                            executor.add(arg)
                            builder.append('?')
                    }
                } else {
                    executor.add(arg)
                    builder.append('?')
                }
                i++
            }
            builder.toString()
        }
        ' ${_wrapLeft} ${sqlFrag} ${_wrapRight} '
    }
}
