package f_orm

public interface QueryMappersInit<T> where T <: QueryMappersInit<T> {
    static prop isSimpleData: Bool {
        get() {
            true
        }
    }
    static func queryMappers(): QueryMappers<T> {
        throw ORMException("not supported")
    }
}
extend<T> Option<T> <: QueryMappersInit<T> where T <: QueryMappersInit<T> {
    public static prop isSimpleData: Bool {
        get() {
            T.isSimpleData
        }
    }
    public static func queryMappers(): QueryMappers<T> {
        T.queryMappers()
    }
}
extend<T> Int8 <: QueryMappersInit<Int8> {}
extend<T> UInt8 <: QueryMappersInit<UInt8> {}
extend<T> Int16 <: QueryMappersInit<Int16> {}
extend<T> UInt16 <: QueryMappersInit<UInt16> {}
extend<T> Int32 <: QueryMappersInit<Int32> {}
extend<T> UInt32 <: QueryMappersInit<UInt32> {}
extend<T> Int64 <: QueryMappersInit<Int64> {}
extend<T> UInt64 <: QueryMappersInit<UInt64> {}
extend<T> Float16 <: QueryMappersInit<Float16> {}
extend<T> Float32 <: QueryMappersInit<Float32> {}
extend<T> Float64 <: QueryMappersInit<Float64> {}
extend<T> Rune <: QueryMappersInit<Rune> {}
extend<T> String <: QueryMappersInit<String> {}
extend<T> Bool <: QueryMappersInit<Bool> {}
extend<T> Duration <: QueryMappersInit<Duration> {}
extend<T> DateTime <: QueryMappersInit<DateTime> {}
extend<T> Array<T> <: QueryMappersInit<Array<T>> where T <: QueryMappersInit<T> {}
extend<T> DataInputStream <: QueryMappersInit<DataInputStream> {}
