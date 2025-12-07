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
package f_data

public class DataDict <: Data & Collection<(String, Data)> {
    private let tuples = HashMap<String, Data>()
    public prop size: Int64 {
        get(){
            tuples.size
        }
    }
    public func isEmpty(): Bool {
        tuples.isEmpty()
    }
    public func add<V>(key: String, value: V): Unit where V <: ToData {
        tuples.add(key, value.toData())
    }
    public func iterator(): Iterator<(String, Data)> {
        tuples.iterator()
    }
    public static func parse(_: String): Data {
        throw DataException()
    }
    public static func tryParse(_: String): ?Data {
        throw DataException()
    }
    public func toString(): String {
        let s = StringGenerator('[')
        for((k, v) in tuples){
            if(s.size > 1){
                s.append(',')
            }
            s.append('(')
            s.append(k.toString())
            s.append(',')
            s.append(v.toString())
            s.append(')')
        }
        s.append(']').toString()
    }
}