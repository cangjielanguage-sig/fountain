## ThreadLocalRandom
```cj
/**
 * 为每个线程返回一个单独的SecureRandom实例，返回的SecureRandom使用默认的priv创建
 */
public class ThreadLocalRandom {
    public static prop current: SecureRandom 
}
```
