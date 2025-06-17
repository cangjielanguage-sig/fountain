/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.  
*/
package f_aspect

public class InvocationFuncInfo {
    public InvocationFuncInfo(
        private let _funcInfo: QualifiedFuncInfo,
        private var _args: Array<Any>
    ){}
    public init(
        qualifiedName: String,
        funcName: String,
        args: Array<Any>
    ){
        this._args = args
        this._funcInfo = QualifiedFuncInfo(qualifiedName, funcName, Array<TypeInfo>(args.size){i => 
            TypeInfo.of(args[i])
        })
    }
    func setArgs(args: Array<Any>) {
        this._args = args
    }
    public prop args: Array<Any> {
        get(){
            _args
        }
    }
    public prop typeInfo: TypeInfo {
        get(){
            _funcInfo.typeInfo
        }
    }
    public prop funcInfo: InstanceFunctionInfo{
        get(){
            _funcInfo.funcInfo
        }
    }
    public prop qualifiedFuncInfo: QualifiedFuncInfo{
        get(){
            _funcInfo
        }
    }
}
public class QualifiedFuncInfo <: Hashable & Equatable<QualifiedFuncInfo> {
    private let hash: Int64
    public QualifiedFuncInfo(
        public let typeInfo: TypeInfo,
        public let funcInfo: InstanceFunctionInfo
    ){
        hash = doHash(typeInfo, funcInfo)
    }
    public init(
        qualifiedName: String,
        funcName: String,
        argTypes: Array<TypeInfo>
    ){
        this.typeInfo = TypeInfos.get(qualifiedName)
        this.funcInfo = typeInfo.getInstanceFunction(funcName, argTypes)
        this.hash = doHash(typeInfo, funcInfo)
    }
    private static func doHash(typeInfo: TypeInfo, funcInfo: InstanceFunctionInfo){
        HashBuilder().append(typeInfo).append(funcInfo).build()
    }
    public operator func ==(other: QualifiedFuncInfo){
        this.typeInfo == other.typeInfo && this.funcInfo == other.funcInfo
    }
    public func hashCode() {
        hash
    }
}