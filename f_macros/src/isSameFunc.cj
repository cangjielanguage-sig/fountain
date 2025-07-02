/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
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
            if (sourceParam.identifier.value != targetParam.identifier.value || sourceParam.not.kind != targetParam
                .not
                .kind || sourceParam.isMemberParam() != targetParam.isMemberParam() ||
                sourceParam.paramType.toTokens() != targetParam.paramType.toTokens()) {
                return false
            }
        }
        source.declType.toTokens() == target.declType.toTokens()
    }
    same
}
