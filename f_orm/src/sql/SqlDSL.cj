/*
Copyright (c) 2025 WuJingrun（吴京润）

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
package f_orm.sql

import std.ast.*

public interface SqlDSL {
    func setSqlFromObject<T>(dsl: String, arg: T, clearArgsAfterExec!: Bool): SqlExecutor where T <: ObjectData<T>
    func setSqlFromMap(dsl: String, arg: Map<String, Any>, clearArgsAfterExec!: Bool): SqlExecutor 
}
private interface SqlDSLPart{}
private class StringSqlDSLPart <: SqlDSLPart {
    StringSqlDSLPart(let partial: String){}
}
private class ArgSqlDSLPart <: SqlDSLPart {
    ArgSqlDSLPart(let arg: String){}
}
private let dslmap = ConcurrentHashMap<String, ArrayList<SqlDSLPart>>()
extend SqlExecutor <: SqlDSL {
    private func compile(dsl: String){
        dslmap.computeIfAbsent(dsl){
            let list = ArrayList<SqlDSLPart>()
            let gen = StringGenerator()
            let tokens = cangjieLex(dsl)
            var i = 0
            while(i < tokens.size) {
                let token = tokens[i]
                match(token.kind){
                    case NL => ()
                    case COLON => 
                        i++
                        if(gen.size > 0){
                            list.add(StringSqlDSLPart(gen.toString()))
                            gen.reset()
                        }
                        list.add(ArgSqlDSLPart(token.value))
                    case _ => gen.append(' ').append(token.value).append(' ')
                }
                i++
            }
            if(gen.size > 0){
                list.add(StringSqlDSLPart(gen.toString()))
            }
            list
        }
    }
    private func convert<T>(sqlgen: StringGenerator, name: String, data: ?Data): Unit {
        match(data){
            case Some(x: DataNone) => this.argNull()
            case Some(x: DataBool) => this.arg(x.data)
            case Some(x: DataDateTime) => this.arg(x.data)
            case Some(x: DataDuration) => this.arg(x.data)
            case Some(x: DataString) => this.arg(x.data)
            case Some(x: DataCollection<Array<Byte>, Byte>) => this.arg(x.data)
            case Some(x: DataReal) => this.arg(x.data.toString())
            case Some(x: Iterable<Data>) => 
                var c = 0
                for(d in x){
                    convert<T>(sqlgen, name, d)
                    if(c > 0){
                        sqlgen.append(',')
                    }
                    sqlgen.append('?')
                    c++
                }
                return
            case x => throw IllegalArgumentException('${TypeInfo.of(x)} which field name is ${name} in ${TypeInfo.of<T>()} is not supported yet.')
        }
        sqlgen.append(' ? ')
    }
    public func setSqlFromMap(dsl: String, arg: Map<String, Any>, clearArgsAfterExec!: Bool = true): SqlExecutor {
        let sqlgen = StringGenerator()
        for(part in compile(dsl)){
            match(part){
                case x: StringSqlDSLPart => sqlgen.append(x.partial)
                case p: ArgSqlDSLPart => match(arg.get(p.arg)){
                    case Some(x: ToData) => convert<Map<String, Any>>(sqlgen, p.arg, x.toData())
                    case Some(x: InputStream) => 
                        this.arg(x)
                        sqlgen.append(' ? ')
                    case None => 
                        this.argNull()
                        sqlgen.append(' ? ')
                    case Some(x) => throw IllegalArgumentException('${TypeInfo.of(x)} which key is ${p.arg} in current Map<String, Any> is not supported yet.')
                }
                case _ => throw UnreachableException()
            }
        }
        this.setSql(sqlgen.toString(), clearArgsAfterExec: clearArgsAfterExec)
    }
    public func setSqlFromObject<T>(dsl: String, arg: T, clearArgsAfterExec!: Bool = true): SqlExecutor where T <: ObjectData<T> {
        let sqlgen = StringGenerator()
        let fields = T.dataFields()
        for(part in compile(dsl)){
            match(part){
                case x: StringSqlDSLPart => sqlgen.append(x.partial)
                case x: ArgSqlDSLPart => convert<T>(sqlgen, x.arg, fields.readableField(x.arg)?.get(x.arg))
                case _ => throw UnreachableException()
            }
        }
        this.setSql(sqlgen.toString(), clearArgsAfterExec: clearArgsAfterExec)
    }
}