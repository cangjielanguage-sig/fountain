/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package f_orm.wrap

public import std.time.{Duration, DateTime}

public interface Data<T> <: AnyData where T <: Data<T> {
    func getValue(): T
    static prop dataType: DataType
    static prop nullable: Bool {
        get() {
            false
        }
    }
}

extend<T> Option<T> <: Data<Option<T>> where T <: Data<T> {
    public func getValue(): ?T {
        this
    }
    public static prop dataType: DataType {
        get() {
            DataType.valueOf("nullable_${T.dataType}")
        }
    }
    public static prop nullable: Bool {
        get() {
            true
        }
    }
    public prop hasValue: Bool {
        get() {
            match (this) {
                case Some(_) => true
                case _ => false
            }
        }
    }
}

extend<T> Int8 <: Data<Int8> {
    public func getValue(): Int8 {
        this
    }
    public static prop dataType: DataType {
        get() {
            int8
        }
    }
}
extend<T> UInt8 <: Data<UInt8> {
    public func getValue(): UInt8 {
        this
    }

    public static prop dataType: DataType {
        get() {
            uint8
        }
    }
}

extend<T> Int16 <: Data<Int16> {
    public func getValue(): Int16 {
        this
    }
    public static prop dataType: DataType {
        get() {
            int16
        }
    }
}
extend<T> UInt16 <: Data<UInt16> {
    public func getValue(): UInt16 {
        this
    }
    public static prop dataType: DataType {
        get() {
            uint16
        }
    }
}

extend<T> Int32 <: Data<Int32> {
    public func getValue(): Int32 {
        this
    }
    public static prop dataType: DataType {
        get() {
            int32
        }
    }
}
extend<T> UInt32 <: Data<UInt32> {
    public func getValue(): UInt32 {
        this
    }
    public static prop dataType: DataType {
        get() {
            uint32
        }
    }
}

extend<T> Int64 <: Data<Int64> {
    public func getValue(): Int64 {
        this
    }
    public static prop dataType: DataType {
        get() {
            int64
        }
    }
}
extend<T> UInt64 <: Data<UInt64> {
    public func getValue(): UInt64 {
        this
    }
    public static prop dataType: DataType {
        get() {
            uint64
        }
    }
}

extend<T> Float16 <: Data<Float16> {
    public func getValue(): Float16 {
        this
    }
    public static prop dataType: DataType {
        get() {
            float16
        }
    }
}
extend<T> Float32 <: Data<Float32> {
    public func getValue(): Float32 {
        this
    }
    public static prop dataType: DataType {
        get() {
            float32
        }
    }
}
extend<T> Float64 <: Data<Float64> {
    public func getValue(): Float64 {
        this
    }
    public static prop dataType: DataType {
        get() {
            float64
        }
    }
}
extend<T> Decimal <: Data<Decimal> {
    public func getValue(): Decimal {
        this
    }
    public static prop dataType: DataType {
        get(){
            decimal
        }
    }
}

extend<T> Bool <: Data<Bool> {
    public func getValue(): Bool {
        this
    }
    public static prop dataType: DataType {
        get() {
            bool
        }
    }
}

extend<T> String <: Data<String> {
    public func getValue(): String {
        this
    }
    public static prop dataType: DataType {
        get() {
            string
        }
    }
}

extend<T> Duration <: Data<Duration> {
    public func getValue(): Duration {
        this
    }
    public static prop dataType: DataType {
        get() {
            duration
        }
    }
}

extend<T> DateTime <: Data<DateTime> {
    public func getValue(): DateTime {
        this
    }
    public static prop dataType: DataType {
        get() {
            datetime
        }
    }
}

extend<T> Array<T> <: Data<Array<T>> where T <: Data<T> {
    public func getValue(): Array<T> {
        this
    }
    public static prop dataType: DataType {
        get() {
            match (T.dataType) {
                case int8 => bytes
                case _ => array
            }
        }
    }
}
