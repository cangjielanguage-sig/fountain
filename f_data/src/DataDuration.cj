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

public class DataDuration <: Data & Hashable & Comparable<DataDuration> {
    public DataDuration(public let data: Duration) {}
    public func toString(): String {
        data.toString()
    }
    public static func tryParse(data: String): ?Data {
        match (Duration.tryParse(extractPureString(data).toAsciiLower())) {
            case Some(x) => DataDuration(x)
            case _ => None<Data>
        }
    }
    public static func parse(data: String): Data {
        tryParse(data).getOrThrow {
            DataException(
                "DataDuration.parse receives string as mdnhimjskns, or there upper cases, m n i j k are integers, but current is ${data}")
        }
    }
    public func toDuration(): Duration {
        data
    }
    public func tryToDuration(): ?Duration {
        data
    }
    public func hashCode(): Int64 {
        data.hashCode()
    }
    public func compare(other: DataDuration): Ordering {
        data.compare(other.data)
    }
}

extend Duration <: DataFields<Duration> {
    public func toData(): Data {
        DataDuration(this)
    }
    public static func tryFromData(data: Data, flag: DataConversionFlag): Any {
        match (data) {
            case x: DataDuration => x.tryToDuration()
            case _: DataNone => None<Duration>
            case _ where (flag & IGNORE_FIELD_TYPE_NOT_MATCH) == 0 => throw DataException(
                '(${data}) does not match to ${TypeInfos.get<Duration>()}')
            case x: DataDateTime => match (x.tryToDateTime()) {
                case Some(x) => x - DateTime.UnixEpoch
                case _ where (flag & IGNORE_FIELD_TYPE_NOT_MATCH) == 0 => throw DataException(
                    '(${data}) does not match to ${TypeInfos.get<Duration>()}')
                case _ => return None<Duration>
            }
            case x: DataString => Duration.tryParse(x.data)
            case _ where (flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0 => throw DataException(
                '(${data}) cannot be converted to ${TypeInfos.get<Duration>()}')
            case _ => None<Duration>
        }
    }
}
