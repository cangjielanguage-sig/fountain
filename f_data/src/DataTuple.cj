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

public class DataTuple <: Data {
    public DataTuple(public let key: Data, public let value: Data){}

    public func toString(): String {
        "(${key},${value})"
    }
    public static func create<K, V>(key: K, value: V): DataTuple where K <: DataFields<K>, V <: DataFields<V> {
        DataTuple(key.toData(), value.toData())
    }
    public static func parseTuple<K, V>(string: String): DataTuple where K <: Data, V <: Data {
        func doParse<T>(bytes: ArrayList<Byte>): Data where T <: Data {
            let tmp = StringBuilder().appendFromUtf8(bytes.toArray()).toString()
            try {
                T.parse(tmp)
            } catch(e: Exception) {
                throw DataException("to parse from sub string ${tmp} in ${string} to ${TypeInfos<K>.instance}", e)
            }
        }
        let s = string[1 .. string.size - 1]
        let bytes = ArrayList<Byte>()
        var k = None<Data>
        for (b in s) {
            match(b) {
                case b'\\' => continue
                case b',' =>
                    k = doParse<K>(bytes)
                    bytes.clear()
                case _ => bytes.append(b)
            }
        }
        DataTuple(k.getOrThrow(), doParse<V>(bytes))
    }
    public static func tryParseTuple<K, V>(string: String): ?DataTuple where K <: Data, V <: Data {
        try {
            parseTuple<K, V>(string)
        } catch (_) {
            None<DataTuple>
        }
    }
    public static func parse(string: String): Data {
        parseTuple<DataString, DataString>(string)
    }
    public static func tryParse(string: String): ?Data {
        match(tryParseTuple<DataString, DataString>(string)) {
            case x: Data => x
            case _ => None<Data>
        }
    }
}
