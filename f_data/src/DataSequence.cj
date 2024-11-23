/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
*/
package f_data

sealed abstract class DataList<D> <: Data & Iterable<D> where D <: Data {
    public DataList(private let data: ArrayList<D>){}
    public init(data: Array<D>){
        this(ArrayList<D>(data))
    }
    public init(){
        this(ArrayList<D>())
    }

    public func add(data: D){
        this.data.append(data)
    }
    public func iterator(): Iterator<D> {
        data.iterator()
    }
    public func toString(): String {
        let s = StringBuilder("[")
        var i = 0
        while(i < data.size) {
            if(i > 0){
                s.append(",")
            }
            s.append(data[i].toString())
            i++
        }
        s.append("]")
        s.toString()
    }
    public static func parseSequence<T>(string: String): DataSequence where T <: Data {
        let s = string[1 .. string.size - 1]
        let data = DataSequence()
        let bytes = ArrayList<Byte>()
        for (b in s) {
            if (b == b'\\') {
                continue
            } else if (b == b',') {
                let tmp = StringBuilder().appendFromUtf8(bytes.toArray()).toString()
                bytes.clear()
                try {
                    data.add(T.parse(tmp))
                } catch (e: Exception) {
                    throw DataException("to parse from sub string ${tmp} in ${string} to ${TypeInfos.get<T>()}", e)
                }
            } else {
                bytes.append(b)
            }
        }
        data
    }
    public static func tryParseSequence<T>(string: String): ?DataSequence where T <: Data {
        try {
            parseSequence<T>(string)
        } catch (_) {
            None<DataSequence>
        }
    }
    public static func parse(string: String): Data {
        parseSequence<DataString>(string)
    }
    public static func tryParse(string: String): ?Data {
        try{
            parse(string)
        } catch (_) {
            None<Data>
        }
    }
}
public class DataSequence <: DataList<Data>{
    public init(data: ArrayList<Data>){
        super(data)
    }
    public init(data: Array<Data>){
        super(data)
    }
    public init(){
        super()
    }
}
public class DataTuples <: DataList<DataTuple> {
    public init(data: ArrayList<DataTuple>){
        super(data)
    }
    public init(data: Array<DataTuple>){
        super(data)
    }
    public init(){
        super()
    }
}
public class StringKeyMapTuples <: Data & Iterable<DataTuple> {
    private let map = LinkedHashMap<String, DataTuple>()

    public func addAll<L>(list: L): Unit where L <: DataList<DataTuple> {
        for(d in list){
            add(d)
        }
    }
    public func add(tuple: DataTuple): Unit {
        map[tuple.key.toString()] = tuple
    }
    public func add<V>(key: String, value: V): Unit where V <: DataFields<V> {
        map[key] = DataTuple(key.toData(), value.toData())
    }
    public func iterator(): Iterator<DataTuple>{
        map.values().iterator()
    }
    public func toString(): String {
        var i = 0
        let builder = StringBuilder('[')
        for(tuple in map.values()){
            if(i > 0){
                builder.append(',')
            }
            builder.append(tuple)
            i++
        }
        builder.append(']')
        builder.toString()
    }
    public static func parseMap(string: String): StringKeyMapTuples  {
        let s = string[1 .. string.size - 1]
        let data = StringKeyMapTuples()
        let bytes = ArrayList<Byte>()
        for (b in s) {
            if (b == b'\\') {
                continue
            } else if (b == b',') {
                let tmp = StringBuilder().appendFromUtf8(bytes.toArray()).toString()
                bytes.clear()
                try {
                    data.add((DataTuple.parse(tmp) as DataTuple).getOrThrow())
                } catch (e: Exception) {
                    throw DataException("to parse from sub string ${tmp} in ${string} to ${TypeInfos.get<DataTuple>()}", e)
                }
            } else {
                bytes.append(b)
            }
        }
        data
    }
    public static func tryParseMap(string: String): ?StringKeyMapTuples {
        try {
            parseMap(string)
        } catch (_) {
            None<StringKeyMapTuples>
        }
    }
    public static func parse(string: String): Data {
        parseMap(string)
    }
    public static func tryParse(string: String): ?Data {
        try{
            parse(string)
        } catch (_) {
            None<Data>
        }
    }
}