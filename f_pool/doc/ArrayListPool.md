## ArrayListPool
```cj
public ArrayPool(
        initSize!: Int64 = 0, 
        minSize!: Int64 = 0, 
        maxSize!: Int64 = Int64.Max,
        elementLife!: Duration = Duration.Max, 
        checkInterval!: Duration = Duration.Zero,
        clearOnReturning!: Bool = false,
        private let arraySize!: Int64 = 128, 
        private let creator!: () -> T = {=> unsafe { zeroValue<T>() }})
```
