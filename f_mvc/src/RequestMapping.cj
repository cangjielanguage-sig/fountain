/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.  
*/
package f_mvc

public open class RequestMapping {
    public const RequestMapping(
        public let path!: String,
        public let method!: RequestMethod,
        public let produces!: String = 'application/json',
        public let consumes!: String = 'application/json',
        public let params!: String = '',
        public let headers!: String = '',
        public let ignoreAuth!: Bool = false,
        public let ignorePrivilege!: Bool = false
    ){}
}
@Annotation[target: [MemberFunction]]
public class PostMapping <: RequestMapping{
    public const init(
        path!: String,
        produces!: String = 'application/json',
        consumes!: String = 'application/json',
        params!: String = '',
        headers!: String = '',
        ignoreAuth!: Bool = false,
        ignorePrivilege!: Bool = false
    ){
        super(path: path, method: RequestMethod.POST, 
              produces: produces, consumes: consumes, 
              params: params, headers: headers,
              ignoreAuth: ignoreAuth, ignorePrivilege: ignorePrivilege)
    }
}
@Annotation[target: [MemberFunction]]
public class GetMapping <: RequestMapping{
    public const init(
        path!: String,
        produces!: String = 'application/json',
        consumes!: String = 'application/json',
        params!: String = '',
        headers!: String = '',
        ignoreAuth!: Bool = false,
        ignorePrivilege!: Bool = false
    ){
        super(path: path, method: RequestMethod.GET, 
              produces: produces, consumes: consumes, 
              params: params, headers: headers,
              ignoreAuth: ignoreAuth, ignorePrivilege: ignorePrivilege)
    }
}
@Annotation[target: [MemberFunction]]
public class PutMapping <: RequestMapping{
    public const init(
        path!: String,
        produces!: String = 'application/json',
        consumes!: String = 'application/json',
        params!: String = '',
        headers!: String = '',
        ignoreAuth!: Bool = false,
        ignorePrivilege!: Bool = false
    ){
        super(path: path, method: RequestMethod.PUT, 
              produces: produces, consumes: consumes, 
              params: params, headers: headers,
              ignoreAuth: ignoreAuth, ignorePrivilege: ignorePrivilege)
    }
}
@Annotation[target: [MemberFunction]]
public class DeleteMapping <: RequestMapping{
    public const init(
        path!: String,
        produces!: String = 'application/json',
        consumes!: String = 'application/json',
        params!: String = '',
        headers!: String = '',
        ignoreAuth!: Bool = false,
        ignorePrivilege!: Bool = false
    ){
        super(path: path, method: RequestMethod.DELETE, 
              produces: produces, consumes: consumes, 
              params: params, headers: headers,
              ignoreAuth: ignoreAuth, ignorePrivilege: ignorePrivilege)
    }
}
@Annotation[target: [MemberFunction]]
public class PatchMapping <: RequestMapping{
    public const init(
        path!: String,
        produces!: String = 'application/json',
        consumes!: String = 'application/json',
        params!: String = '',
        headers!: String = '',
        ignoreAuth!: Bool = false,
        ignorePrivilege!: Bool = false
    ){
        super(path: path, method: RequestMethod.PATCH, 
              produces: produces, consumes: consumes, 
              params: params, headers: headers,
              ignoreAuth: ignoreAuth, ignorePrivilege: ignorePrivilege)
    }
}