## STDX依赖
配置环境变量：`export CANGJIE_STDX_DYNAMIC_PATH=/path/to/dynamic_stdx`

### 配置
```bash
#multipart缓冲区的一半大小，默认是2048字节
export http_halfBufferSize=2048
#上传文件的临时保存路径，此例子是默认路径
export http_uploadDir=/tmp/fountain/upload
```

### `MediaType`
```cj
/**
 * 各种数据格式的父类型
 * 可以继承此类实现自定义数据格式
 */
public abstract class MediaType <: ToString & Hashable & Equatable<MediaType> {
    /**
     * @param mediaType 格式类型的名称
     */
    public MediaType(public let mediaType: String) 
    public open func toString(): String 
    public open func hashCode(): Int64 
    /**
     * 用格式名称得到一个新的MediaType实例。
     * 有些数据格式会有不同的字符集定义，比如文本格式；或有不同的参数，比如multipart/form-data，有boundary。
     * 因此需要使用此函数基于当前实例创建新的MediaType
     */
    public func make(mediaType: String): MediaType
    public open operator func ==(other: MediaType): Bool 
    /**
     * 泛型约束是fountain::f_data.DataFields<T>，此函数会将参数转为字节数组。
     * 通常做法是调用data.toData()，得到fountain::f_data.Data实例，再调用本类的fromData(data: Data)转成字节数组
     */
    public func fromDataFields<T>(data: T): Array<Byte> where T <: DataFields<T> 
    /**
     * 可从Data实例获得数据，将数据转成MediaType表示的数据格式，最后再转换成字节数组。
     * 比如JsonValue.tryFromData(data)可以将Data实例转成JsonValue。
     */
    public open func fromData(data: Data): Array<Byte>
    /**
     * 一般是将字节数组转成MediaType表示的数据格式，再转换成Data实例
     * 比如可以先按照当前MediaType指定的字符集把字节数组转成字节串，
     * 最后调用JsonValue.fromStr(jsonStr).toData()即可把json字符串转成Data实例
     */
    public open func toData(data: Array<Byte>): Data
    /**
     * 从InputStream读取字节并转成Data数据
     */
    public open func toData(input: InputStream): Data 
    /**
     * 将字符串转成MediaType表示的数据格式，再转成Data实例
     */
    public open func toData(data: String): Data 
    /**
     * 用将Data实例调用T.fromData(data)即可将data实例转成泛型类型
     */
    public func toDataFields<T>(data: Data): T where T <: DataFields<T> {
        (T.fromData(data) as T).getOrThrow{MediaTypeException(data.toString())}
    }
    public func toDataFields<T>(data: Array<Byte>): T where T <: DataFields<T> {
        toDataFields<T>(toData(data))
    }
    public func toDataFields<T>(input: InputStream): T where T <: DataFields<T> {
        toDataFields<T>(toData(input))
    }
    public func toDataFields<T>(data: String): T where T <: DataFields<T> {
        toDataFields<T>(toData(data))
    }
}
```

### `MediaTypes`
```cj
/**
 * 此类维持着所有的MediaType具体实现
 */
public class MediaTypes {
    /**
     * 注册将MediaType实例
     */
    public static func register(mediaType: MediaType): Unit
    /**
     * 用mediaType名称得到MediaType，如果参数表示的数据格式没有注册到MediaTypes会抛出异常
     */
    public static func parse(mediaType: String): MediaType 
    /**
     * 用mediaType名称得到MediaType，如果参数表示的数据格式没有注册到MediaTypes会返回None<MediaType>
     */
    public static func tryParse(mediaType: String): ?MediaType 
}
```

### `MultipartFileBuilder`
```cj
/**
 * multipart/form-data数据段的构造器，对应一个Content-Disposition和相应的数据
 */
public class MultipartFileBuilder {
    /**
     * 本段数据的名称
     */
    public func name(name: String): This 
    /**
     * 本段数据的值
     */
    public func value(content: Array<Byte>): This 
    /**
     * 本段数据的值，将参数转成UTF8字节数组
     */
    public func value<T>(content: T): This where T <: ToString 
    /**
     * 本段数据是一个文件
     */
    public func file(file: File): This 
    /**
     * 本段数据来自一个InputStream，并用其它参数构造Content-Disposition。
     * @param fileName 文件名
     * @param content 数据输入流
     * @param size 本数据段的大小
     * @param creationDate 本段数据的创建时间
     * @param modificationDate 本段数据的最后修改时间
     */
    public func file(fileName: String, content: InputStream, size!: Int64 = -1, 
                     creationDate!: ?DateTime = None<DateTime>, modificationDate!: ?DateTime = None<DateTime>): This
    /**
     * 构造一个MultipartFile实例，并返回本类内部的数据构造MultipartFormData，
     */
    public func build(): MultipartFormData 
}
```

### ``
```cj
public class MultipartFormData {
    /**
     * 当前multipart/form-data的boundary
     */
    public let boundary = 'FountainBoundary${RandomString().randomLettersNumbers(32)}'
    /**
     * 创建一个新的数据段构造器
     */
    public func newPart(): MultipartFileBuilder 
    /**
     * 将数据转换成字节序列写到参数output
     */
    public func encode(output: OutputStream): Unit
    /**
     * 返回的是MultipartFileInputStream
     */ 
    public func input(): InputStream 
}
```

### `MultipartFileInputStream`
```cj
/**
 * 从本类的实例读取multipart/form-data的数据
 */
public class MultipartFileInputStream <: InputStream {
    public func read(buf: Array<Byte>): Int64
}
```

### 实现的数据格式
- text/plain
- application/json
- multipart/form-data
