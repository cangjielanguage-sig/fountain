# f_httpclient


## STDX依赖

配置环境变量：`export CANGJIE_STDX_DYNAMIC_PATH=/path/to/dynamic_stdx`

# `HttpClient`
http客户端的实现，这是stdx.net.http.Client的简单包装


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

---

## 其他公开 API

以下声明未在上文展开，按「模块级 / 类型」分组列出（`extend` 里的成员归到被扩展的类型）；完整语义见 `src/` 下对应文件。

- `HttpClient`：`func enablePush(enable: Bool): This`、`func headerTableSize(size: UInt32): This`、`func httpProxy(addr: String): This`、`func httpsProxy(addr: String): This`、`func initialWindowSize(size: UInt32): This`、`func logger(logger: Logger): This`、`func maxConcurrentStreams(size: UInt32): This`、`func maxFrameSize(size: UInt32): This`、`func maxHeaderListSize(size: UInt32): This`、`func noProxy(): This`
- `HttpResponse`：`func readEntire(): String`、`func sseReader(maxLineBytes!: Int64, idleTimeout!: Duration): SseReader`、`func readJson(): JsonValue`、`func readToEnd(): Array<Byte>`、`func reader(): StringReader<InputStream>`、`func tryParse<T>(): ?T where T <: DataFields<T>`

---

## SSE 客户端

`text/event-stream` 的解析放在本模块，业务模块（如 `f_llm`）只消费事件，不再各写一份行解析。

```cj
public struct SseEvent {
    public SseEvent(public let event: String, public let data: String, public let id: String, public let retry: Int64){}
}

public class SseReader <: Resource {
    public init(body: InputStream, maxLineBytes!: Int64 = 1024 * 1024, idleTimeout!: Duration = Duration.second * 120)
    public func next(): ?SseEvent      // 流正常结束返回 None
    public func close(): Unit
}

extend HttpResponse <: ExtendHttpResponse {
    public func sseReader(maxLineBytes!: Int64, idleTimeout!: Duration): SseReader
}
```

使用：

```cj
resource(response.sseReader(maxLineBytes: 1 << 20, idleTimeout: Duration.second * 120)){reader =>
    while(let Some(event) <- reader.next()){
        // event.data 是原文；`[DONE]` 之类的业务语义由调用方判断
    }
}
```

实现要求（每条都有单测）：

| # | 规则 |
|---|---|
| 1 | 按字节读 `response.body`（8 KiB 缓冲循环），不先 `readToEnd()`——否则“流式”是假的 |
| 2 | 行分隔 `\n`，容忍行尾 `\r` |
| 3 | `:` 开头是注释/心跳，整行丢弃，不产生事件 |
| 4 | 空行 = 一条事件结束；只认 `event` / `data` / `id` / `retry`，其余字段丢弃 |
| 5 | `data` 多行以 `\n` 拼接；字段值去掉前导一个空格 |
| 6 | 单行超过 `maxLineBytes` 抛 `SseLineTooLongException` |
| 7 | `idleTimeout` 内没读到任何字节抛 `SseTimeoutException`（与连接超时区分） |
| 8 | **返回 `data` 原文**，不解释 `[DONE]`、不解析 JSON |
| 9 | `close()` 关闭底层流（能关的才关），`Resource` 保证 `resource(...)` 可用 |
| 10 | 不做自动重连、不消费 `Last-Event-ID`（LLM 的流断了只能重发请求） |