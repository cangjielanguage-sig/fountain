/*
    Copyright (c) 2022 WuJingrun（吴京润）
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
macro package f_orm.macros

import std.ast.*
import f_macros.*

//DAO 接口必须是public，不能带泛型形参，且必须继承orm.RootDAO
//在DAO接口函数的默认实现添加生成sql和调用RootDAO函数完成访问数据库的工作
//一个持久化对象一个DAO接口
//模块内的DAO接口的函数声明不能重名。
//对于良好的编程实践，由于DAO接口不应该暴露到模块外面，一个包内导入的DAO接口函数不重名就不会有影响，
//不同包内导入的不同DAO接口函数重名也不会有影响，不过原则上还是不建议这样做。
//实际使用时，在Service层应该是有类似以下代码
//    //Service层的代码
//    package fountain.apppack.service
//    import apppack.model.ArgData
//    import apppack.model.po.SomePO
//    import fountain.orm.RootService
//    public interface SomePOService <: RootService{
//        func queryData(arg: ArgData): ArrayList<SomePO>
//    }
//    //===========================
//    package fountain.apppack.service.impl
//    import fountain.orm.{ORM, SqlExecutor}
//    import apppack.service.SomePOService
//    import apppack.model.ArgData
//    import apppack.model.po.SomePO
//    import apppack.dao.SomePODAO
//    public class SomePOServiceImpl <: SomePOService{
//        public func queryData(arg: ArgData): ArrayList<SomePO>{
//            executor().execute<ArrayList<SomePO>>{exe: SqlExecutor =>
//                exe.listSomePO(arg)
//            }
//        }
//    }
//    //DAO层的代码
//    package fountain.apppack.dao
//    import fountain.base.*
//    import fountain.orm.*
//    import apppack.model.ArgData
//    import apppack.model.po.SomePO
//    @DAO
//    public interface SomeDAO {
//        prop executor: SqlExecutor//所有dao必须有这一行
//        func listSomePO(arg: ArgData): ArrayList<SomePO>{
//            executor.generateSql{sqlargs: SqlArgs =>
//                """
//                select *
//                  from some_table
//                 where ${sqlargs.appendArg(" id = ", arg.id)}
//                       ${sqlargs.meet(arg.name != String.empty, " `name` like ", "${arg.name}%", prefix: " and ")}
//                       ${sqlargs.meet(arg.minBirthday.isSome() && arg.maxBirthday.isSome(), "${sqlargs.appendArg(" birthday between ", arg.minBirthday)} ${sqlargs.appendArg(" and ", arg.maxBirthday)}")}
//                """
//            }.list<SomePO>(somePOMappers)
//        }
//        prop somePOMappers: QueryMappers<SomePO>{
//            get(){
//                QueryMappers<SomePO>(
//                    mappers: [QueryMapper<SomePO>(
//                        index: 0,
//                        name: "id",
//                        dataType: int64,
//                        putter: {o: SomePO, v: Any => o.id = orm.convert<Int64>(v)}
//                    ), QueryMapper<SomePO>(
//                        index: 1,
//                        name: "name",
//                        dataType: string,
//                        putter: {o: SomePO, v: Any => o.name = orm.convert<String>(v)}
//                    ),...],
//                    creator: {=> SomePO()}
//                )
//            }
//        }
//    }
public macro DAO(input: Tokens): Tokens {
    match(parseDecl(input)){
        case d: InterfaceDecl => 
            let name = d.identifier
            input + `nl` + quote(
                extend SqlExecutor <: $(name){}
            )
        case d: MacroExpandDecl => 
            var m = d
            while(let md: MacroExpandDecl <- m.macroInputDecl){
                m = md
            }
            let tokens = quote(
                @DAO
                $(m.macroInputs)
            )
            m.macroInputs = tokens
            m.macroInputDecl = parseDecl(tokens)
            return d.toTokens()
        case _ => 
            diagReport(ERROR, input,
            'input must be interface decl',
            '')
            throw IllegalArgumentException("input must be a interface decl")
    }
}
