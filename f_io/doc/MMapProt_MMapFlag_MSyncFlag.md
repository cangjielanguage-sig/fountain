# MMapProt / MMapFlag / MSyncFlag / DEFAULT_MMAP_BYTES

> 所有声明仅 Linux 可用：`@When[os == "Linux"]`

## MMapProt

```cj
@When[os == "Linux"]
public enum MMapProt
```

内存映射保护标志。

### 构造器

`Read` | `Write` | `Exec` | `None`

### 操作符

| 操作符 | 签名 | 说明 |
|--------|------|------|
| & | `operator func &(prot: IntNative): Bool` | 检查标志位 |
| \| | `operator func \|(other: MMapProt): Array<MMapProt>` | 组合两个标志 |
| \| | `operator func \|(others: Array<MMapProt>): Array<MMapProt>` | 组合数组 |

## MMapFlag

```cj
@When[os == "Linux"]
public enum MMapFlag <: Equatable<MMapFlag> & Equatable<IntNative>
```

### 构造器

`Shared` | `Private` | `Anonymous`

## MSyncFlag

```cj
@When[os == "Linux"]
public enum MSyncFlag
```

### 构造器

`Sync` | `Async` | `Invalidate`

## DEFAULT_MMAP_BYTES

```cj
@When[os == "Linux"]
public const DEFAULT_MMAP_BYTES = 1 * 1024 * 1024 * 1024  // 1 GiB
```

默认映射字节数。
