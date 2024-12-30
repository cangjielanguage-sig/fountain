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

internal class AnySubPathNode <: DataPathNode {
    static let instance = AnySubPathNode()
    private init(){}
    public func get(data: Data): Iterator<Data> {
        match(data){
            case x: StringKeyMapTuples => x.iterator().map{tpl => tpl.value}
            case x: DataSequence => x.iterator()
            case _ => 
                let info = TypeInfo.of(data)
                if(info.qualifiedName.startsWith('f_data.DataObject') && 
                   let Some(fn) <- TypeMemberInfos.instanceFunction(info, 'iterator') && 
                   let tuples: Iterator<(String, Data)> <- fn.apply(data)){
                    tuples.map{f => f[1]}
                }else{
                    SingleIterator<Data>(data)
                }
        }
    }
}