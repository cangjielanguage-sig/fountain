## FileDownload

### 导入
```cj
import fountain::f_mvc.FileDownload
```

### API
```cj
public class FileDownload {
    /**
     * multi: 是否下载多个文件
     * contentType: 响应头ContentType，默认值 application/octet-stream。如果要下载多个文件，这个参数值是第一个文件的Content-Type
     */
    public FileDownload(private let multi!: Bool = false,
        private let contentType!: String = "application/octet-stream") 
    /**
     * 如果没有可以下载的文件，请仅调用此函数。
     */
    public func noContent(): Unit 
    /**
     * 把一个文件写到http 输入流，当只下载一个文件，且文件内容来自一个磁盘文件时，请调用此函数
     */
    public func write(file: File): Unit 
    /**
     * 把一个InputStream写到http 输入流，当只下载一个文件，且文件内容来自一个InputStream时，请调用此函数。
     * @param filename: 下载的文件名
     * @param input: 输入流
     * @param length: 输入流的长度，默认值 -1，表示未知长度
     */
    public func write(filename: String, input: InputStream, length!: Int64 = -1) 
    /**
     * 把一个字节数组写到http 输入流，当需要下载多个文件或文件特别大时，请调用此函数。
     * @param bytes: 字节数组
     */
    public func write(bytes: Array<Byte>): Unit 
    /**
     * 务必在本函数实参内部调用其它函数
     */
    public func write(fn: (FileDownload) -> Unit)
    /**
     * 创建一个文件下载对象，当需要下载多个文件时，请调用此函数表示开始下载。
     * 如果只下载一个文件，且文件特别大，请调用此函数表示开始下载。
     * 本函数在每次http访问时最多只调用一次。
     * 调用本函数就不要再调用write(file: File): Unit和write(filename: String, input: InputStream, length!: Int64 = -1): Unit
     * @param filename: 下载的文件名
     * @param length: 文件长度，默认值 -1，表示未知长度
     */
    public func start(filename: String, length!: Int64 = -1): FileDownload 
    /**
     * 下一个待下载文件的元数据，写入第二个及以后的文件时再调用本函数，或者需要写下一个文件内容之前调用本函数。
     * @param filename: 待下载的文件名
     * @param contentType: 待下载文件的Content-Type
     * @param length: 待下载文件的长度，默认值 -1，表示未知长度
     */
    public func next(filename: String, contentType: String, length!: Int64 = -1): Unit
    /**
     * 所有文件都下载完成调用此函数。本函数只调用一次。
     * 如果已调用write(file: File): Unit和write(filename: String, input: InputStream, length!: Int64 = -1): Unit，就不必再调用本函数，它们会自动调用本函数。
     */
    public func end() 
}
```

#### 快捷函数
```cj
public func download(data: File): Unit 

public func download(data: InputStream, filename: String, length!: Int64 = -1): Unit 

public func download(data: Array<Byte>, filename: String): Unit 

public func download<C>(data: C): Unit where C <: Iterable<(InputStream, String)> 

public func download(data: Array<File>): Unit
```