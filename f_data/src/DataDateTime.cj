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

public class DataDateTime <: Data & Hashable & Comparable<DataDateTime> {
    public DataDateTime(public let data: DateTime){}
    public func toString(): String {
        data.toString()
    }
    public static func tryParse(data: String): ?Data {
        try {
            parse(data)
        } catch (e: Exception) {
            None<Data>
        }
    }
    public static func parse(data: String): Data {
        DataDateTime(DateTime.parse(extractPureString(data)))
    }
    public func toDateTime(): DateTime {
        data
    }
    public func tryToDateTime(): ?DateTime {
        data
    }
    public func hashCode(): Int64 {
        data.hashCode()
    }
    public func compare(other: DataDateTime): Ordering {
        data.compare(other.data)
    }
}
let currentThreadDateFormat = ThreadLocal<String>()
let defaultDateFormat = AtomicReference<Box<String>>(Box<String>(""))
public interface ExtendDateTimeData {
    static func setDefaultDateFormat(format: String): Unit
    static func setCurrentThreadDateFormat(format: String): Unit
}
extend DateTime <: DataFields<DateTime> & ExtendDateTimeData {
    public func toData(): Data {
        DataDateTime(this)
    }
    public static func tryFromData(data: Data, flag!: DataConversionFlag = SILENCE): Any {
        match(data){
            case x: DataDateTime => x.tryToDateTime()
            case _: DataNone => None<DateTime>
            case _ where (flag & IGNORE_FIELD_TYPE_NOT_MATCH) == 0 => throw DataException('(${data}) does not match ${TypeInfos.get<DateTime>()}')
            case x: DataDuration => match(x.tryToDuration()){
                case Some(x) => DateTime.UnixEpoch + x
                case _ => None<DateTime>
            }
            case x: DataString =>
                let fmt = currentThreadDateFormat.get() ?? defaultDateFormat.load().value
                try{
                    if (fmt.isEmpty()) {
                        DateTime.parse(x.data)
                    } else {
                        DateTime.parse(x.data, fmt)
                    }
                }catch(e: Exception){
                    if((flag & IGNORE_FIELD_TYPE_NOT_MATCH) == 0){
                        throw e
                    }else{
                        None<DateTime>
                    }
                }
            case _ where (flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0 => throw DataException('(${data}) cannot be converted to ${TypeInfos.get<DateTime>()}')
            case _ => None<DateTime>
        }
    }
    public static func setDefaultDateFormat(format: String) {
        var box = None<Box<String>>
        while (true) {
            let fmt = defaultDateFormat.load()
            if (fmt.value == "") {
                let newBox = match (box) {
                    case Some(x) => x
                    case _ => Box<String>(format)
                }
                if (defaultDateFormat.compareAndSwap(fmt, newBox)) {
                    return
                }
            } else {
                throw DataException("default date format has bean specified: ${fmt.value}")
            }
        }
    }
    public static func setCurrentThreadDateFormat(format: String) {
        currentThreadDateFormat.set(format)
    }
}
