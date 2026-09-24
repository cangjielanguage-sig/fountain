## `AsyncEndExecutorGetter`
```cj
public interface AsyncEndExecutorGetter <: EndExecutorGetter {
    func tryGet(timeout!: Duration): ?EndExecutor
}
```
