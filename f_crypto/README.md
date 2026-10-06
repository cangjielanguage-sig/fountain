# f_crypto

## STDX依赖

配置环境变量：`export CANGJIE_STDX_DYNAMIC_PATH=/path/to/dynamic_stdx`

本模块把标准扩展库的加密套件转出，供fountain其他模块使用：

```cj
public import stdx.crypto.common.*   // CryptoKit、Certificate、PrivateKey、PublicKey、DerBlob、CryptoException ...
public import stdx.crypto.kit.*      // DefaultCryptoKit
```

## 全局CryptoKit

```cj
/**
 * 实现了这个接口且注册到IOC的类会注册到全局CryptoKit
 * 默认实现会在bean的PostConstruct阶段调用setGlobalCryptoKit(this)
 */
public interface GlobalCryptoKit <: CryptoKit & PostConstruct {
    func postConstruct(): Unit {
        setGlobalCryptoKit(this)
    }
}
```

```cj
@Bean
public class MyCryptoKit <: GlobalCryptoKit {
    // 实现 CryptoKit 的各个成员函数（可转发给 DefaultCryptoKit()）
}
```

只要加载了本模块，模块级初始化就会把全局CryptoKit设置为`DefaultCryptoKit()`，因此`getGlobalCryptoKit()`在正常情况下不会没有值。注册多个`GlobalCryptoKit`bean时，最后完成`postConstruct`的那个生效。

## 证书校验器

```cj
/**
 * 实现这个接口的类可以辅助实例化枚举stdx.net.tls.common.CertificateVerifyMode的构造器CustomVerify
 */
public interface CertificateVerifier{
    func verify(certificate: Array<Certificate>): Bool
}
```

本接口只定义契约、没有默认实现。`f_mvc` 用它实现TLS的`CustomVerify`：把实现类注册为bean，再用配置项`mvc_tlsVerifyBean`指定bean名。

## 使用示例

```cj
import fountain::f_crypto.*

// 未注册自定义CryptoKit时，这里是DefaultCryptoKit
let kit = getGlobalCryptoKit()
let certs = kit.certificateFromPem(pemText)
```
