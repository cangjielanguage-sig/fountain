## STDX依赖
配置环境变量：`export CANGJIE_STDX_DYNAMIC_PATH=/path/to/dynamic_stdx`

# `HttpClient`
http客户端的实现，这是stdx.net.http.Client的简单包装
---

## 声明
### `HttpClient`
```cj
public class HttpClient <: Resource {
    /**
     * 全局的读超时
     */
    public static func globalReadTimeout(readTimeout: Duration): Unit 
    /**
     * 全局的写超时
     */
    public static func globalWriteTimeout(writeTimeout: Duration): Unit 
    /**
     * @param url 待访问的URL
     */
    public HttpClient(var url: String)
    /**
     * @param auto true-自动访问重定向的URL，false-不访问重定向的URL
     */
    public func autoRedirect(auto: Bool): This

    public func connector(c: (SocketAddress) -> StreamingSocket): This
    /**
     * 指定cookie
     */
    public func cookieJar(cookieJar: ?CookieJar): This
    /**
     * 连接池大小
     */
    public func poolSize(size: Int64): This
    /**
     * 本次访问的读超时
     */
    public func readTimeout(timeout: Duration): This
    /**
     * 本次访问的写超时
     */
    public func writeTimeout(timeout: Duration): This
    /**
     * 设置tls配置
     */
    public func tlsConfig(config: TlsClientConfig): This
    /**
     * 设置请求头
     */
    public func header(key: String, value: String): This
    /**
     * 设置请求头
     */
    public func header<T>(key: String, value: T): This where T <: ToString
    public func isClosed(): Bool
    public func close(): Unit
    /**
     * 执行GET访问
     */
    public func get(): HttpResponse
    /**
     * 执行DELETE访问
     */
    public func delete(): HttpResponse
    /**
     * 执行PUT访问
     */
    public func put(): HttpResponse
    /**
     * 执行PUT访问
     * @param body 请求体
     */
    public func put(body: String): HttpResponse
    /**
     * 执行PUT访问
     * @param body 请求体
     */
    public func put(body: InputStream): HttpResponse
    /**
     * 执行PUT访问
     * @param body 请求体
     */
    public func put(body: Array<Byte>): HttpResponse
    /**
     * 执行PUT访问
     * @param contentType 请求体的数据格式
     * @param body 请求体
     */
    public func put<T>(contentType: String, body: T): HttpResponse where T <: DataFields<T>
    /**
     * 执行POST访问
     */
    public func post(): HttpResponse
    /**
     * 执行POST访问
     * @param body 请求体
     */
    public func post(body: String): HttpResponse
    /**
     * 执行POST访问
     * @param body 请求体
     */
    public func post(body: InputStream): HttpResponse
    /**
     * 执行POST访问
     * @param body 请求体
     */
    public func post(body: Array<Byte>): HttpResponse
    /**
     * 执行POST访问
     * @param contentType 请求体的数据格式
     * @param body 请求体
     */
    public func post<T>(contentType: String, body: T): HttpResponse where T <: DataFields<T>
    /**
     * 初始化一个表单对象，当前HttpClient实例会作为FormBuilder的初始化参数
     */
    public func form(): FormBuilder
    /**
     * 初始化一个multipart/form-data数据类型的对象，当前HttpClient实例会作为MultipartFormDataBuilder的初始化参数
     */
    public func multipartFormdata(): MultipartFormDataBuilder
}
```

### `FormBuilder`
```cj
public class FormBuilder {
    /**
     * 添加一个表单参数
     * @param key 参数名
     * @param value 参数值
     */
    public func add(key: String, value: String): This 
    /**
     * 修改一个表单参数，如果表单内已有同名参数，原参数会被新值覆盖
     * @param key 参数名
     * @param value 参数值
     */
    public func set(key: String, value: String): This
    /**
     * 删除一个表单参数
     * @param key 参数名
     */
    public func remove(key: String): This 
    /**
     * 调用内部维持的HttpClient执行GET访问
     */
    public func get(): HttpResponse 
    /**
     * 调用内部维持的HttpClient执行DELETE访问
     */
    public func delete(): HttpResponse 
    /**
     * 调用内部维持的HttpClient执行PUT访问
     */
    public func put(): HttpResponse 
    /**
     * 调用内部维持的HttpClient执行POST访问
     */
    public func post(): HttpResponse 
}
```

### `MultipartFormDataBuilder`
用来构造multipart/form-data的数据格式
```cj
public class MultipartFormDataBuilder {
    public func newPart(): MultipartFileBuilder{
        data.newPart()
    }
    /**
     * 发起PUT访问
     */
    public func put(){
        client.put(data.input())
    }
    /**
     * 发起POST访问
     */
    public func post(){
        client.post(data.input())
    }
}
```

### http响应扩展
```cj
/**
 * 将响应体转换成函数泛型类型的实例
 */
public interface ExtendHttpResponse {
    func convert<T>(): ?T where T <: DataFields<T>
}
extend HttpResponse <: ExtendHttpResponse
```