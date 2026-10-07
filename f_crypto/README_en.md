# f_crypto

## STDX dependency

Configure the environment variable: `export CANGJIE_STDX_DYNAMIC_PATH=/path/to/dynamic_stdx`

This module re-exports the crypto suite of the standard extension library for other fountain modules to use:

```cj
public import stdx.crypto.common.*   // CryptoKit, Certificate, PrivateKey, PublicKey, DerBlob, CryptoException ...
public import stdx.crypto.kit.*      // DefaultCryptoKit
```

## Global CryptoKit

```cj
/**
 * A class that implements this interface and is registered with the IOC will be registered as the global CryptoKit
 * The default implementation calls setGlobalCryptoKit(this) during the bean's PostConstruct phase
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
    // Implement the members of CryptoKit (they may forward to DefaultCryptoKit())
}
```

As long as this module is loaded, module-level initialization sets the global CryptoKit to `DefaultCryptoKit()`, so `getGlobalCryptoKit()` will not be valueless under normal circumstances. When multiple `GlobalCryptoKit` beans are registered, the one that finishes `postConstruct` last takes effect.

## Certificate verifier

```cj
/**
 * A class implementing this interface can help instantiate the CustomVerify constructor of the enum stdx.net.tls.common.CertificateVerifyMode
 */
public interface CertificateVerifier{
    func verify(certificate: Array<Certificate>): Bool
}
```

This interface only defines a contract and has no default implementation. `f_mvc` uses it to implement TLS `CustomVerify`: register the implementing class as a bean, then specify the bean name with the configuration item `mvc_tlsVerifyBean`.

## Usage example

```cj
import fountain::f_crypto.*

// When no custom CryptoKit is registered, this is DefaultCryptoKit
let kit = getGlobalCryptoKit()
let certs = kit.certificateFromPem(pemText)
```
