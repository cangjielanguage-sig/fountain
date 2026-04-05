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
package fountain::f_orm.migro

import std.env.{getStdOut, getStdIn}
import std.fs.*

public struct SchemaFinderMediator {
    private let finders = ConcurrentHashMap<String, SchemaFinder>()
    public init(){
        for(f in lookupList<SchemaFinder>()){
            finders[f.driverName] = f
        }
    }
    public func generate(cmdargs: Array<String>): Unit {
        let sqls = TableMetas.tableMetas().groupBy{m => m.driver}.iterator().flatMap{tuple: (String, ArrayList<TableMeta>) => 
            let (driver, metas) = tuple
            let first = Box<Bool>(true)
            metas.iterator().flatMap{m: TableMeta => 
                let finder = finders[driver]
                let columns = finder.findTableSchema(m.database, m.tableName)
                    .fold(ArrayList<ColumnMeta>()){list, meta => 
                        list.add(meta)
                        list
                    }
                let sqls = if(columns.isEmpty()){
                    finder.generateCreateSql(m.tableName, m.columns.iterator())
                }else{
                    finder.generateAlterSql(m.tableName, m.columns, columns.iterator())
                }
                let currentIndexes = finder.findIndexes(m.database, m.tableName)
                let indexeSqls = finder.generateIndexSql(m.tableName, m.indexes, currentIndexes)
                if(first.value){
                    first.value = false
                    ['use ${m.database};'].iterator().concat(sqls)
                }else{
                    sqls.iterator()
                }.concat(indexeSqls)
            }.map{sql => (driver, sql)}
        }.inspect{tuple => (tuple[0], getStdOut().writeln(tuple[1]))}
        .fold(ArrayList<(String, String)>()){list, tuple =>
            list.add(tuple)
            list
        }
        for(i in 0 .. cmdargs.size where cmdargs[i] == '-m' || cmdargs[i] == '--mode'){
            match(cmdargs[i + 1]){
                case 'file' => 
                    try(sqlfile = File('./migro.sql', Write)){
                        for((_, sql) in sqls){
                            sqlfile.write('${sql}\n'.unsafeBytes())
                        }
                    }
                case 'auto' => execute(sqls)
                case 'dry' => break
                case 'interactive' =>
                    getStdOut().write('> 是否立即执行生成的SQL? [y/N]：')
                    while(let Some(r) <- getStdIn().read()){
                        match(r){
                            case 'y' | 'Y' => execute(sqls)
                            case 'n' | 'N' => break
                            case _ => continue
                        }
                    }
                case _ => throw Exception("Invalid migration mode ${cmdargs[i + 1]}")
            }
            break
        }
    }
    private func execute(sqls: ArrayList<(String, String)>): Unit {
        for((driver, sql) in sqls){
            try(exe = ORM.executor(driver)){
                getStdOut().writeln('> ${sql}')
                try{
                    exe.setSql(sql).update
                }catch(e: Exception){
                    e.printStackTrace()
                }
            }
        }
    }
}