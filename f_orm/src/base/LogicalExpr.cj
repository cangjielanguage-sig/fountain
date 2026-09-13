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
package fountain::f_orm.base

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
public struct EmptyExpr <: LogicalExpr {
    init(){}
    public func toString(): String {
        ''
    }
}
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
                    case x: Array<Any> => 
                        match((x[0], x[1])){
                            case (x: Column, y: Column) => ' ${column} ${op} ${x} AND ${y} '
                            case _ => ' ${column} ${op} ${arg(x[0])} AND ${arg(x[1])} '
                        }
                    case _ => throw SqlArgException('value must be Array<Any> for BETWEEN or NOT_BETWEEN')
                }
            case IN | NOT_IN =>
                match(value){
                    case x: Collection<Any> => ' ${column} ${op} (${arg(x)}) '
                    case x: Column => ' ${column} ${op} (${x}) '
                    case _ => throw SqlArgException('value must be Collection<Any> for IN or NOT_IN')
                }
            case IS_NULL | IS_NOT_NULL => ' ${column} ${op} '
            case x: Column => ' ${column} ${op} ${x} '
            case _ => '${column} ${op} ${arg(value)}'
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

public class NullExpr <: CmpExpr {
    init(column: Column, op: CmpOp){
        super(column, op, Option<Any>.None)
        match(op){
            case IS_NULL | IS_NOT_NULL => ()
            case _ => throw SqlArgException('op must be IS_NULL or IS_NOT_NULL')
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
        private let exprs: Array<LogicalExpr>
    ){}
    public func toString(): String {
        let builder = StringGenerator()
        if(let NOT <- op){
            builder.append(op)
            if(exprs.size > 1){
                throw SqlArgException('NOT only support one expr')
            }else{
                builder.append('(').append(exprs[0]).append(')')
            }
        }else{
            for(expr in exprs){
                if(builder.size > 0){
                    builder.append(op)
                }
                builder.append(expr)
            }
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
public class CommaExpr <: LogicalExpr & ToString {
    CommaExpr(private let exprs: Array<LogicalExpr>){}
    public func toString(): String {
        let builder = StringBuilder()
        for(expr in exprs){
            if(builder.size > 0){
                builder.append(',')
            }
            builder.append(expr)
        }
        return builder.toString()
    }
}