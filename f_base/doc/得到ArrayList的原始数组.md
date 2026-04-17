## 得到ArrayList的原始数组
```cj
import std.collection.ArrayList

public interface UnsafeData<T> {
    func unsafeData(): Array<T>
}

extend<T> ArrayList<T> <: UnsafeData<T>{...}
```
