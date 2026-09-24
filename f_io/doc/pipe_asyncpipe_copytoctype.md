# pipe / asyncPipe / copyToCType

## pipe

```cj
public func pipe<I, O>(input!: I, output!: O, bufferSize!: Int64 = 4096): Unit
    where I <: InputStream, O <: OutputStream
```

将 `input` 的所有数据通过缓冲区传输到 `output`。

## asyncPipe

```cj
public func asyncPipe<I, O>(input!: I, output!: O, bufferSize!: Int64 = 4096): Unit
    where I <: InputStream, O <: OutputStream
```

在新线程中执行 `pipe`。

## copyToCType

```cj
public func copyToCType<T>(input: InputStream): T where T <: CType
```

从 `InputStream` 读取 `sizeOf<T>()` 字节并解释为 CType 值。字节数不足时抛出 `IllegalSizeException`。
