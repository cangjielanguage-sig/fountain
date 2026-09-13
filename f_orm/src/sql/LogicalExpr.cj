/*
Copyright (c) 2026 WuJingrun（吴京润）

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/
package fountain::f_orm.sql

public enum CmpOp <: ToString{
    | EQ
    | NEQ
    | LT
    | LTE
    | GT
    | GTE
    | IN
    | NOT_IN
    | LIKE
    | NOT_LIKE
    | IS_NULL
    | IS_NOT_NULL
    | BETWEEN
    | NOT_BETWEEN
    public func toString(): String {
        match(this){
            case EQ => " = "
            case NEQ => " <> "
            case LT => " < "
            case LTE => " <= "
            case GT => " > "
            case GTE => " >= "
            case IN => " IN "
            case NOT_IN => " NOT IN "
            case LIKE => " LIKE "
            case NOT_LIKE => " NOT LIKE "
            case IS_NULL => " IS NULL "
            case IS_NOT_NULL => " IS NOT NULL "
            case BETWEEN => " BETWEEN "
            case NOT_BETWEEN => " NOT BETWEEN "
        }
    }
}
public interface LogicalExpr <: ToString {}
public open class CmpExpr <: RootDAO & LogicalExpr {
    CmpExpr(
        private let column: Column,
        private let op: CmpOp,
        private let value: Any
    ){}
    public prop executor: SqlExecutor {
        get(){
            SqlExecutor.getCurrent()
        }
    }
    public func toString(): String {
        match(op){
            case BETWEEN | NOT_BETWEEN => 
                match(value){
                    case x: Array<Any> => ' ${column} ${op} ${arg(x[0])} AND ${arg(x[1])} '
                    case _ => throw SqlArgException('value must be Array<Any> for BETWEEN or NOT_BETWEEN')
                }
            case IN | NOT_IN =>
                match(value){
                    case x: Collection<Any> => ' ${column} ${op} (${arg(x)}) '
                    case _ => throw SqlArgException('value must be Collection<Any> for IN or NOT_IN')
                }
            case _ =>
                '${column} ${op} ${arg(value)}'
        }
    }
}
public class BetweenExpr <: CmpExpr {
    init(column: Column, op: CmpOp, value: Array<Any>){
        super(column, op, value)
        match(op){
            case BETWEEN | NOT_BETWEEN => ()
            case _ => throw SqlArgException('op must be BETWEEN or NOT_BETWEEN')

        }
    }
}

public class InExpr <: CmpExpr {
    init(column: Column, op: CmpOp, value: Collection<Any>){
        super(column, op, value)
        match(op){
            case IN | NOT_IN => ()
            case _ => throw SqlArgException('op must be IN or NOT_IN')
        }
    }
}

public enum RelationOp <: ToString {
    | AND
    | OR
    | NOT
    public func toString(): String {
        match(this){
            case AND => " AND "
            case OR => " OR "
            case NOT => " NOT "
        }
    }
}
public class RelationExpr <: LogicalExpr & ToString {
    RelationExpr(
        private let op: RelationOp,
        private let exprs: Array<LogicalExpr>,
        private let paren: Bool
    ){}
    public func toString(): String {
        let builder = StringBuilder()
        let ss = if(paren){
            builder.append('(')
            1
        }else{
            0
        }
        if(let NOT <- op){
            builder.append(op)
            if(exprs.size > 1){
                throw SqlArgException('NOT only support one expr')
            }else{
                builder.append(exprs[0])
            }
        }else{
            for(expr in exprs){
                if(builder.size > ss){
                    builder.append(op)
                }
                builder.append(expr)
            }
        }
        if(paren){
            builder.append(')')
        }
        return builder.toString()
    }
}
public class ParenExpr <: LogicalExpr & ToString {
    ParenExpr(private let expr: LogicalExpr){}
    public func toString(): String {
        return '(${expr})'
    }
}