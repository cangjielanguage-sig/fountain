/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
*/
package f_base

import std.collection.concurrent.ConcurrentHashMap
import std.sync.ReentrantMutex

public class TypeInfos {
    private static let infos = ConcurrentHashMap<String, TypeInfo>()
    private static let mutex = ReentrantMutex()

    public static func getTypeInfo(qualifiedName: String): TypeInfo {
        if (let Some(x) <- infos.get(qualifiedName)) {
            x
        } else {
            synchronized(mutex){
                if(let Some(x) <- infos.get(qualifiedName)) {
                    x
                } else {
                    let info = TypeInfos.getTypeInfo(qualifiedName)
                    infos[qualifiedName] = info
                    info
                }
            }
        }
    }
    public static func getGenericTypes(qualifiedName: String): Array<TypeInfo> {
        let idx = qualifiedName.indexOf("<")
        if (let Some(i) <- idx) {
            let generics = qualifiedName[i .. qualifiedName.size - 1]
            let types = parseParameterTypes(generics)
            types
        } else {
            []
        }
    }
}
