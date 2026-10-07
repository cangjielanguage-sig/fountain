# f_httpclient


## STDX dependency

Configure the environment variable: `export CANGJIE_STDX_DYNAMIC_PATH=/path/to/dynamic_stdx`

# `HttpClient`
An HTTP client implementation; this is a simple wrapper around stdx.net.http.Client


## Declarations

### `HttpClient`
```cj
public class HttpClient <: Resource {
    /**
     * Global read timeout
     */
    public static func globalReadTimeout(readTimeout: Duration): Unit 
    /**
     * Global write timeout
     */
    public static func globalWriteTimeout(writeTimeout: Duration): Unit 
    /**
     * @param url The URL to visit
     */
    public HttpClient(var url: String)
    /**
     * @param auto true - follow redirected URLs automatically, false - do not follow redirected URLs
     */
    public func autoRedirect(auto: Bool): This

    public func connector(c: (SocketAddress) -> StreamingSocket): This
    /**
     * Specify the cookie
     */
    public func cookieJar(cookieJar: ?CookieJar): This
    /**
     * Connection pool size
     */
    public func poolSize(size: Int64): This
    /**
     * Read timeout for this request
     */
    public func readTimeout(timeout: Duration): This
    /**
     * Write timeout for this request
     */
    public func writeTimeout(timeout: Duration): This
    /**
     * Set the tls configuration
     */
    public func tlsConfig(config: TlsClientConfig): This
    /**
     * Set a request header
     */
    public func header(key: String, value: String): This
    /**
     * Set a request header
     */
    public func header<T>(key: String, value: T): This where T <: ToString
    public func isClosed(): Bool
    public func close(): Unit
    /**
     * Perform a GET request
     */
    public func get(): HttpResponse
    /**
     * Perform a DELETE request
     */
    public func delete(): HttpResponse
    /**
     * Perform a PUT request
     */
    public func put(): HttpResponse
    /**
     * Perform a PUT request
     * @param body Request body
     */
    public func put(body: String): HttpResponse
    /**
     * Perform a PUT request
     * @param body Request body
     */
    public func put(body: InputStream): HttpResponse
    /**
     * Perform a PUT request
     * @param body Request body
     */
    public func put(body: Array<Byte>): HttpResponse
    /**
     * Perform a PUT request
     * @param contentType Data format of the request body
     * @param body Request body
     */
    public func put<T>(contentType: String, body: T): HttpResponse where T <: DataFields<T>
    /**
     * Perform a POST request
     */
    public func post(): HttpResponse
    /**
     * Perform a POST request
     * @param body Request body
     */
    public func post(body: String): HttpResponse
    /**
     * Perform a POST request
     * @param body Request body
     */
    public func post(body: InputStream): HttpResponse
    /**
     * Perform a POST request
     * @param body Request body
     */
    public func post(body: Array<Byte>): HttpResponse
    /**
     * Perform a POST request
     * @param contentType Data format of the request body
     * @param body Request body
     */
    public func post<T>(contentType: String, body: T): HttpResponse where T <: DataFields<T>
    /**
     * Initialize a form object; the current HttpClient instance is passed as the constructor argument of FormBuilder
     */
    public func form(): FormBuilder
    /**
     * Initialize an object of the multipart/form-data type; the current HttpClient instance is passed as the constructor argument of MultipartFormDataBuilder
     */
    public func multipartFormdata(): MultipartFormDataBuilder
}
```

### `FormBuilder`
```cj
public class FormBuilder {
    /**
     * Add a form parameter
     * @param key Parameter name
     * @param value Parameter value
     */
    public func add(key: String, value: String): This 
    /**
     * Modify a form parameter; if the form already holds a parameter with the same name, the original one is overwritten by the new value
     * @param key Parameter name
     * @param value Parameter value
     */
    public func set(key: String, value: String): This
    /**
     * Remove a form parameter
     * @param key Parameter name
     */
    public func remove(key: String): This 
    /**
     * Perform a GET request with the internally held HttpClient
     */
    public func get(): HttpResponse 
    /**
     * Perform a DELETE request with the internally held HttpClient
     */
    public func delete(): HttpResponse 
    /**
     * Perform a PUT request with the internally held HttpClient
     */
    public func put(): HttpResponse 
    /**
     * Perform a POST request with the internally held HttpClient
     */
    public func post(): HttpResponse 
}
```

### `MultipartFormDataBuilder`
Used to build the multipart/form-data data format
```cj
public class MultipartFormDataBuilder {
    public func newPart(): MultipartFileBuilder{
        data.newPart()
    }
    /**
     * Send a PUT request
     */
    public func put(){
        client.put(data.input())
    }
    /**
     * Send a POST request
     */
    public func post(){
        client.post(data.input())
    }
}
```

### http response extension
```cj
/**
 * Convert the response body into an instance of the function's generic type
 */
public interface ExtendHttpResponse {
    func convert<T>(): ?T where T <: DataFields<T>
}
extend HttpResponse <: ExtendHttpResponse
```
