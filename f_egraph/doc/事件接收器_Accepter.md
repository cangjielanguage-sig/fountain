## 事件接收器`Accepter`
事件执行器、事件调度器都是它的子类型
```cj
public interface Accepter {
    func accept(event: Event): Unit
}
```
