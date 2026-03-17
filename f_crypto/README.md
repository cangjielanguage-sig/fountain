## STDX依赖
配置环境变量：`export CANGJIE_STDX_DYNAMIC_PATH=/path/to/dynamic_stdx`

```cj
/**
 * 实现这个接口的类可以辅助实例化枚举stdx.net.tls.common.CertificateVerifyMode的构造器CustomVerify
 */
public interface CertificateVerifier{
    func verify(certificate: Array<Certificate>): Bool
}
/**
 * 实现了这个接口且注册到IOC的类会注册到全局CryptoKit
 */
public interface GlobalCryptoKit <: CryptoKit & PostConstruct {}
```