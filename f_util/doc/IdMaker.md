## IdMaker
```cj
public class IdMaker {
    /**
     * hostSerial 主机序列号
     */
    public IdMaker(private let hostSerial!: Int64)
    /**
     * 从配置项idMakerHostSerial获取主机序列化
     */
    public init()
    /**
     * 获取下一个ID
     */
    public func nextInt64(): Int64
}
```
