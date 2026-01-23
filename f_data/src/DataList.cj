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
package fountain::f_data

public class DataList <: Data & Collection<Data> {
    private let list = ArrayList<Data>()
    public prop size: Int64 {
        get(){
            list.size
        }
    }
    public func isEmpty(): Bool {
        list.isEmpty()
    }
    public func add<T>(item: T): Unit where T <: ToData {
        list.add(item.toData())
    }
    public func iterator(): Iterator<Data> {
        list.iterator()
    }
    public static func parse(_: String): Data {
        throw DataException()
    }
    public static func tryParse(_: String): ?Data {
        throw DataException()
    }
    public func toString(): String {
        let s = StringGenerator('[')
        for(d in list){
            if(s.size > 1){
                s.append(',')
            }
            s.append(d.toString())
        }
        s.append(']').toString()
    }
}