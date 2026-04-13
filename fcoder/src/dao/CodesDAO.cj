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
package fountain::fcoder.dao

import fountain::f_orm.macros.*

@DAO
public interface CodesDAO <: RootDAO {
    func findCodes(params: CodeParam, embedding: Array<Float64>): ArrayList<String> {
        executor.setSql('''
            WITH confidence AS (
          SELECT code 
            ${if(params.code.size > 0){
                '''
                , (1.0 - (embedding <=> ${arg(embedding.toString())})) * ${arg(params.weight)} + 
                ts_rank(search_vector, query) * (1.0 - ${arg(params.weight)}) as confidence
           FROM codes, to_tsquery('chinese_english', ${arg(params.code)}) as query
                '''
            }else{
                '''
           FROM codes
                '''
            }}
          WHERE project_id = ${arg(params.projectId)}
               ${meet(params.moduleName.size > 0){
          ' AND module_name = ${arg(params.moduleName)} '}}
               ${meet(params.packageName.size > 0){
          ' AND package_name = ${arg(params.packageName)} '}}
               ${meet(params.code.size > 0){
          ' AND search_vector @@ query '}}
         )
         SELECT code
           FROM confidence
           ${meet(params.code.size > 0){
         'WHERE confidence >= ${arg(params.confidence)}'}}
        ''').singleList<String>()
    }

    func saveCode(code: Code, embedding: Array<Float64>): Unit {
        executor.setSql('''
        insert 
          into codes(
               project_id,
               file_path,
               module_name,
               package_name,
               code_lang,
               code,
               embedding
       )values(${arg(code.projectId)},
               ${arg(code.filePath)},
               ${arg(code.moduleName)},
               ${arg(code.packageName)},
               ${arg(code.codeLang)},
               ${arg(code.code)},
               ${arg(embedding.toString())}
       )''').insert
    }
}