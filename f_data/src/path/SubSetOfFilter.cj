/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.  
*/
package f_data.path

internal class SubSetOfFilter<T> <: Subset<T> & DataFilter where T <: ToString & DataFields<T> {
    init(left: DataPath, right: ArrayList<T>){
        super(left, right)
    }
    init(left: String, right: String, solid: String){
        this(compilePath(left, solid), parseArrayList<T>(right))
    }
    public func check(data: Data): Bool {
        let d = match(left.get(data).next()){
            case Some(x) => x
            case _ => return false
        }
        let size = match(d){
            case x: DataSequence => x.size
            case x: StringKeyMapTuples => x.size
            case _ =>
                var size = -1
                let info = TypeInfo.of(left)
                if(info.qualifiedName.startsWith('f_data.DataObject') && 
                   let Some(fn) <- TypeMemberInfos.instanceFunction(info, 'fields') && 
                   let fields: Iterator<ReadableField> <- fn.apply(left)){
                    size = 0
                    for(_ in fields){
                        size++
                    }
                }
                size
        }
        subset(data) == size
    }
}