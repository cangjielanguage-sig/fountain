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
package f_mvc

public class RequestMetas {
    private let mutex = Mutex()
    public static let instance = RequestMetas()
    private let metas = ArrayList<RequestMeta>()
    private let tags = ConcurrentHashMap<String, HashSet<String>>()
    private init(){}
    func tryAdd(meta: RequestMeta){
        synchronized(mutex){
            let key = '${meta.method}:${meta.path}'
            if(let Some(s) <- tags.get(key)){
                if(let intersection <- meta.intersectionConsumes(s) && intersection.size > 0){
                    let gen = StringGenerator('[')
                    for(c in intersection){
                        if(gen.size > 1){
                            gen.append(',')
                        }
                        gen.append(c)
                    }
                    gen.append(']')
                    throw MVCException('duplicate request meta: ${key}; consumes: ${gen}')
                }else{
                    s.add(all: meta.consumes)
                }
            }else{
                tags.add(key, HashSet<String>(meta.consumes))
            }
            metas.add(meta)
        }
    }
}