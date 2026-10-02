# ToMMap

> `@When[os == "Linux"]`

```cj
@When[os == "Linux"]
public interface ToMMap
```

## 方法

| 方法 | 签名 |
|------|------|
| mmap | `func mmap(offset: Int64, mapLength: Int64, flag!: MMapFlag): MMapFile` |

## 扩展

```cj
@When[os == "Linux"]
extend File <: ToMMap
```

`std.fs.File` 扩展了 `ToMMap`，根据 `canRead()`/`canWrite()` 确定 prots。
