/*
Copyright (c) 2026 WuJingrun（吴京润）

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/
package fountain::f_crypto

public import stdx.crypto.common.*
public import stdx.crypto.kit.*

import fountain::f_bean.*

public interface CertificateVerifier{
    func verify(certificate: Array<Certificate>): Bool
}
public interface GlobalCryptoKit <: CryptoKit {}

private let _ = {=>
    try{
        getGlobalCryptoKit()
    }catch(_){
        let kits = lookupList<CryptoKit>()
        var set = false
        for (kit in kits where kit is GlobalCryptoKit) {
            setGlobalCryptoKit(kit)
            set = true
            break
        }
        if(!set){
            setGlobalCryptoKit(DefaultCryptoKit())
        }
    }
}()