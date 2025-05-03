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

import std.collection.ArrayList
import f_orm.exception.ORMException

public class ChooseCondition {
    private static let emptyPartial: () -> (String, ToString) = {=> ('', '')}
    private let conditions = ArrayList<(() -> Bool, () -> (String, ToString))> ()
    private var _otherwise: () -> (String, ToString) = emptyPartial
    private var pair = true
    private var _argInSql: Bool = false
    public ChooseCondition(private let executor: SqlExecutor){}
    public prop argInSql: ChooseCondition {
        get(){
            _argInSql = true
            this
        }
    }
    public func condition(condition: () -> Bool): ChooseCondition {
        if(pair){
            pair = false
            conditions.add((condition, emptyPartial))
            this
        }else{
            throw ORMException('condition and sql partial generation function arg not paring')
        }
    }
    public func partial(partial: () -> (String, ToString)): ChooseCondition {
        if(pair){
            throw ORMException('condition and sql partial generation function arg not paring')
        }else{
            pair = true
            let idx = conditions.size - 1
            let (c, _) = conditions[idx]
            conditions[idx] = (c, partial)
            this
        }
    }
    public func partial(partial: () -> ToString): ChooseCondition {
        this.partial{('', partial())}
    }
    public func otherwise(partial: () -> (String, ToString)): ChooseCondition {
        _otherwise = partial
        this
    }
    public func otherwise(partial: () -> ToString): ChooseCondition {
        otherwise{('', partial())}
    }
    public func done(): String {
        if(!pair){
            throw ORMException('condition and sql partial generation function arg not paring')
        }
        func gen(partial: () -> (String, ToString)){
            let (frag, arg) = partial()
            if(frag.size > 0){
                if(_argInSql){
                    ' ${frag} ${arg} ${Condition.delimiter} '
                }else{
                    executor.add<ToString>(arg)
                    ' ${frag} ? ${Condition.delimiter} '
                }
            }else if(_argInSql){
                ' ${arg} ${Condition.delimiter} '
            }else{
                executor.add<ToString>(arg)
                ' ? ${Condition.delimiter} '
            }
        }
        for((cond, partial) in conditions where cond()) {
            return gen(partial)
        }
        gen(_otherwise)
    }
}