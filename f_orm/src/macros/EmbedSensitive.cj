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
macro package fountain::f_orm.macros

import std.ast.*
import std.database.sql.SqlOption
import fountain::f_macros.*
import fountain::f_orm.wrap.{ORMConfig, SM4Conf}
import fountain::f_base.UnsafeBytes

public macro EmbedSensitive(_: Tokens): Tokens {
    var tokens = quote(
        private let _ = {=>
    )
    for(d in ORMConfig.getDriverNames()){
        let url = try{
            ORMConfig.getUrl(driverName: d)
        }catch(_){
            ''
        }
        if(url.size > 0){
            tokens += `nl` + str2bytesTokens(d, ORMConfig.connectionUrl, url)
        }
        if(let Some(u) <- ORMConfig.getUsername()){
            tokens += `nl` + str2bytesTokens(d, ORMConfig.genKey(ORMConfig.ormOption, SqlOption.Username).replace("__", '_'), u)
        }
        if(let Some(p) <- ORMConfig.getPassword()){
            tokens += `nl` + str2bytesTokens(d, ORMConfig.genKey(ORMConfig.ormOption, SqlOption.Password).replace("__", '_'), p)
        }
    }
    let sm4conf = ORMConfig.sm4conf
    quote(
        $tokens
            ORMConfig.registerSensitive(ORMConfig.sm4Operation, $(sm4conf.operation.toArray()))
            ORMConfig.registerSensitive(ORMConfig.sm4Padding, $(sm4conf.padding.toArray()))
            ORMConfig.registerSensitive(ORMConfig.sm4Key, $(sm4conf.key))
            ORMConfig.registerSensitive(ORMConfig.sm4Iv, $(sm4conf.iv))
            ORMConfig.registerSensitive(ORMConfig.sm4Aad, $(sm4conf.aad))
            ORMConfig.registerSensitive(ORMConfig.sm4TagSize, $(sm4conf.tagSize.toString().toArray()))
        }()
    )
}
private func str2bytesTokens(driver: String, key: String, value: String){
    var bytes = value.unsafeBytes()
    if(let Some(sm4) <- ORMConfig.getSM4()){
        bytes = sm4.encrypt(bytes)
    }
    quote(
            ORMConfig.registerSensitive(ORMConfig.genKey($driver, $key), $bytes)
    )
}