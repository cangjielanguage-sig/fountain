/*
Copyright (c) 2025 WuJingrun（吴京润）

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
package f_macros

public func isSameFuncDecl(source: FuncDecl, target: FuncDecl): Bool {
    let sourceModifiers = source.modifiers
    let targetModifiers = target.modifiers
    var same: Bool = if (sourceModifiers.size != targetModifiers.size) {
        return false
    } else if (sourceModifiers.size == 1) {
        match ((sourceModifiers[0].keyword.kind, targetModifiers[0].keyword.kind)) {
            case (PUBLIC, PUBLIC) | (PROTECTED, PROTECTED) | (PRIVATE, PRIVATE) | (STATIC, STATIC) => true
            case _ => return false
        }
    } else if (sourceModifiers.size == 2) {
        match ((sourceModifiers[0].keyword.kind, sourceModifiers[0].keyword.kind, targetModifiers[1].keyword.kind, targetModifiers[1]
                .keyword
                .kind)) {
            case (PUBLIC, STATIC, PUBLIC, STATIC) | (STATIC, PUBLIC, STATIC, PUBLIC) | (PUBLIC, STATIC, STATIC, PUBLIC)
                | (STATIC, PUBLIC, PUBLIC, STATIC) | (PROTECTED, STATIC, PROTECTED, STATIC)
                | (STATIC, PROTECTED, STATIC, PROTECTED) | (PROTECTED, STATIC, STATIC, PROTECTED)
                | (STATIC, PROTECTED, PROTECTED, STATIC) | (PRIVATE, STATIC, PRIVATE, STATIC)
                | (STATIC, PRIVATE, STATIC, PRIVATE) | (PRIVATE, STATIC, STATIC, PRIVATE)
                | (STATIC, PRIVATE, PRIVATE, STATIC) => true
            case _ => return false
        }
    } else {
        return false
    }
    same = if (!same || source.identifier.value != target.identifier.value) {
        false
    } else {
        let sourceParams = source.funcParams
        let targetParams = target.funcParams
        if (sourceParams.size != targetParams.size) {
            return false
        }
        for (i in 0..sourceParams.size) {
            let sourceParam = sourceParams[i]
            let targetParam = targetParams[i]
            if (sourceParam.identifier.value != targetParam.identifier.value || 
                sourceParam.not.kind != targetParam.not.kind || 
                sourceParam.isMemberParam() != targetParam.isMemberParam() ||
                sourceParam.paramType.toTokens() != targetParam.paramType.toTokens()) {
                return false
            }
        }
        source.declType.toTokens() == target.declType.toTokens()
    }
    same
}
