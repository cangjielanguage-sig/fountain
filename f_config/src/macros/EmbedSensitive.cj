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
macro package fountain::f_config.macros

import std.ast.*
import std.collection.HashSet
import stdx.crypto.crypto.*
import fountain::f_base.*
import fountain::f_config.*

public macro EmbedSensitive(input: Tokens): Tokens {
    let keys = HashSet<String>()
    for(k in input where k.kind == TokenKind.IDENTIFIER || k.kind == TokenKind.STRING_LITERAL || k.kind == TokenKind.SINGLE_QUOTED_STRING_LITERAL){
        keys.add(k.value)
    }
    var tokens = quote()
    for((k, v) in Config.getAll() where keys.contains(k)){
        let vbytes = v.unsafeBytes()
        tokens += if(let Some(sm4) <- Config.getSM4()){
            let cipher = sm4.encrypt(vbytes)
            quote(
                Config.registerSensitive($k, $cipher)
            )
        }else{
            quote(
                Config.registerSensitive($k, $vbytes)
            )
        }
    }
    let sm4conf = Config.sm4conf
    if(sm4conf.key.size > 0 && tokens.size > 0){
       tokens += quote(
            Config.registerSensitive(Config.sm4Operation, $(sm4conf.operation.toArray()))
            Config.registerSensitive(Config.sm4Padding, $(sm4conf.padding.toArray()))
            Config.registerSensitive(Config.sm4Key, $(sm4conf.key))
            Config.registerSensitive(Config.sm4Iv, $(sm4conf.iv))
            Config.registerSensitive(Config.sm4Aad, $(sm4conf.aad))
            Config.registerSensitive(Config.sm4TagSize, $(sm4conf.tagSize.toString().toArray()))
       )
    }
    quote(
        private let _ = {=>
            $tokens
        }()
    )
}