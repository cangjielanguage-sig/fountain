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
package dbtest.controller

import fountain.bean.*
import fountain.bean.macros.*
import fountain.mvc.*
import fountain.mvc.macros.*
import dbtest.service.DbTestService
import dbtest.model.dataAssist.*
import dbtest.model.mvc.ListResponse
import dbtest.model.mvc.UserPageRes
import dbtest.model.mvc.BaseResponse
import dbtest.model.mvc.QueryResponse
import dbtest.model.po.*

@Controller
public class DbController {

    private let userService = lookup<DbTestService>()

    // select first
    @PostMapping[path:'/api/db/first']
    @IgnoreSecurity
    public func firstDemo(@RequestBody user: UserReq): QueryResponse<UserPO> {
        QueryResponse.success(userService.firstDemo(user.username, user.password))
    }

    // select first 2
    @PostMapping[path:'/api/db/singleFirstDemo']
    @IgnoreSecurity
    public func singleFirstDemo(@RequestBody user: UserReq): BaseResponse {
        let userRes = UserPO()
        userRes.username = userService.singleFirstDemo(user.username, user.password)
        QueryResponse.success(userRes)
    }

    // select page
    @PostMapping[path:'/api/db/page']
    @IgnoreSecurity
    public func pageDemo(@RequestBody user: UserReq): UserPageRes {
        let res = UserPageRes()
        res.items = userService.pageDemo(user.username, user.password)
        res
    }

    // 复杂条件
    @PostMapping[path:'/api/db/pageWithSubCondition']
    @IgnoreSecurity
    public func pageWithSubCondition(@RequestBody user: UserReq): UserPageRes {
        let res = UserPageRes()
        res.items = userService.pageWithSubCondition(user.username, user.password)
        res
    }


    //     更新密码
    @PutMapping[path:'/api/db/updatePassword']
    @IgnoreSecurity
    public func updatePassword(@RequestBody user: UserPO): BaseResponse {
        userService.updatePassword(user.id, user.password)
        BaseResponse.success("更新密码成功")
    }

    //     更新信息-map
    @PutMapping[path:'/api/db/updateMap']
    @IgnoreSecurity
    public func updateMap(@RequestBody user: UserPO): BaseResponse {
        let map = HashMap<String, Any>([("username", user.username), ("password", user.password)])
        let res = userService.updateMap(user.id, map)
        BaseResponse.success("更新${res}条数据")
    }

    //     更新信息-map
    @PostMapping[path:'/api/db/updateMapDemo']
    @IgnoreSecurity
    public func updateMapDemo(@RequestBody user: UserPO): BaseResponse {
        let map2 = HashMap<String, Any>()
        map2["password"] = "123"
        map2["username"] = "admin"
        let res = userService.updateMapDemo(user.id, map2)
        BaseResponse.success("更新${res}条数据")
    }

    //     更新信息-map
    @PostMapping[path:'/api/db/updateMapDemo2']
    @IgnoreSecurity
    public func updateMapDemo2(@RequestBody user: UserPO): BaseResponse {
        let map2 = HashMap<String, Any>()
        map2["password"] = "123"
        let res = userService.updateMapDemo2(map2)
        BaseResponse.success("更新${res}条数据")
    }

    //     更新信息-map
    @PostMapping[path:'/api/db/updateMapDemo3']
    @IgnoreSecurity
    public func updateMapDemo3(@RequestBody user: UserPO): BaseResponse {
        let map2 = HashMap<String, Any>()
        map2["password"] = "123"
        map2["username"] = "admin"
        let res = userService.updateMapDemo3(user.id)
        BaseResponse.success("更新${res}条数据")
    }

    //     更新信息-使用 sql 语句
    @PutMapping[path:'/api/db/updateSql']
    @IgnoreSecurity
    public func updateSql(@RequestBody user: UserPO): BaseResponse {
        let res = userService.updateSql(user.id, user.username, user.password)
        BaseResponse.success("更新${res}条数据")
    }

    // select list
    @PostMapping[path:'/api/db/listDemo']
    @IgnoreSecurity
    public func listDemo(@RequestBody user: UserReq): ListResponse<UserPO> {
        ListResponse.success(userService.listDemo(user.username, user.password))
    }

    // select list demo 2
    @PostMapping[path:'/api/db/listDemo2']
    @IgnoreSecurity
    public func listDemo2(@RequestBody user: UserReq): ListResponse<UserPO> {
        ListResponse.success(userService.listDemo2(user.username, user.password))
    }


    @PostMapping[path:'/api/db/updateNull']
    @IgnoreSecurity
    public func updateSaveTimeNull(@RequestBody user: UserReq): BaseResponse {
        userService.updateSaveTimeNull(user.username, user.password)
        BaseResponse.success("更新成功")
    }


    @PostMapping[path:'/api/db/inDemo1']
    @IgnoreSecurity
    public func inDemo1(@RequestBody request: IdsReq): ListResponse<UserPO> {
        ListResponse.success(userService.inDemo1(request.ids))
    }

    @PostMapping[path:'/api/db/inDemo2']
    @IgnoreSecurity
    public func inDemo2(@RequestBody request: IdsReq): ListResponse<UserPO> {
        ListResponse.success(userService.inDemo2(request.ids))
    }

    @PostMapping[path:'/api/db/inDemo3']
    @IgnoreSecurity
    public func inDemo3(@RequestBody request: IdsReq): ListResponse<UserPO> {
        ListResponse.success(userService.inDemo3(request.ids))
    }

    @PostMapping[path:'/api/db/whereDemo']
    @IgnoreSecurity
    public func whereDemo(@RequestBody user: UserReq): ListResponse<UserPO> {
        ListResponse.success(userService.whereDemo(user.username, user.password))
    }


    @PostMapping[path:'/api/db/likeDemo1']
    @IgnoreSecurity
    public func likeDemo1(@RequestBody user: UserReq): ListResponse<UserPO> {
        ListResponse.success(userService.likeDemo1(user.username))
    }

    @PostMapping[path:'/api/db/likeDemo2']
    @IgnoreSecurity
    public func likeDemo2(@RequestBody user: UserReq): ListResponse<UserPO> {
        ListResponse.success(userService.likeDemo2(user.username))
    }

    @PostMapping[path:'/api/db/notLikeDemo1']
    @IgnoreSecurity
    public func notLikeDemo1(@RequestBody user: UserReq): ListResponse<UserPO> {
        ListResponse.success(userService.notLikeDemo1(user.username))
    }

    @PostMapping[path:'/api/db/meetDemo']
    @IgnoreSecurity
    public func meetDemo(@RequestBody user: UserReq): ListResponse<UserPO> {
        ListResponse.success(userService.meetDemo(user.username, user.password))
    }

    @PostMapping[path:'/api/db/meetDemo2']
    @IgnoreSecurity
    public func meetDemo2(@RequestBody user: UserReq): ListResponse<UserPO> {
        ListResponse.success(userService.meetDemo2(user.username, user.password))
    }


    @PostMapping[path:'/api/db/transaction']
    @IgnoreSecurity
    public func transactionDemo(@RequestBody user: UserReq): BaseResponse {
        let username = "transactionDemo"
        userService.deleteDemo(username, user.password) // 清空数据
        userService.insertDemo(username, user.password) // 新增数据
        try {
            // 事务会尝试删除此 username，抛出异常
            userService.transactionDemo(username, user.password)
        } catch (e:Exception) {
            // 数据库中如果还存在此 username，证明事务回滚成功
            let res = userService.firstDemo(username, user.password)
            try {
                res.getOrThrow()
                return BaseResponse.success("事务-回滚成功")
            } catch (e: NoneValueException) {
                return BaseResponse.error("事务-未查询到数据")
            }
        }
        BaseResponse.error("事务-不符合预期")
    }


    @PostMapping[path:'/api/db/transactionDemo2']
    @IgnoreSecurity
    public func transactionDemo2(@RequestBody user: UserReq): BaseResponse {
        userService.transactionDemo2(user.username, user.password)
        BaseResponse.success("事务操作成功")
    }

    @PostMapping[path:'/api/db/transactionDemo3']
    @IgnoreSecurity
    public func transactionDemo3(@RequestBody user: UserReq): BaseResponse {
        let username = "transactionDemo3"
        userService.deleteDemo(username, user.password) // 清空数据
        userService.insertDemo(username, user.password) // 新增数据
        try {
            // 事务会尝试删除此 username，抛出异常
            userService.changeTransactionDemo3(username, user.password)
        } catch (e:Exception) {
            // 数据库中如果还存在此 username，证明事务回滚成功
            let res = userService.firstDemo(username, user.password)
            try {
                res.getOrThrow()
                return BaseResponse.success("事务-回滚成功")
            } catch (e: NoneValueException) {
                return BaseResponse.error("事务-未查询到数据")
            }
        }
        BaseResponse.error("事务-不符合预期")

    }

    @PostMapping[path:'/api/db/expectExceptionDemo']
    @IgnoreSecurity
    public func expectExceptionDemo(@RequestBody user: UserReq): BaseResponse {
        userService.expectExceptionDemo(user.username, user.password)
        BaseResponse.success("这里返回成功信息，是不对的")
    }

    @PostMapping[path:'/api/db/insert']
    @IgnoreSecurity
    public func insertDemo(@RequestBody user: UserReq): BaseResponse {
        userService.insertDemo(user.username, user.password)
        BaseResponse.success("新增操作成功")
    }

    @PostMapping[path:'/api/db/insertDemo2']
    @IgnoreSecurity
    public func insertDemo2(@RequestBody user: UserReq): BaseResponse {
        userService.insertDemo2(user.username, user.password)
        BaseResponse.success("新增操作成功")
    }

    @PostMapping[path:'/api/db/delete']
    @IgnoreSecurity
    public func deleteDemo(@RequestBody user: UserReq): BaseResponse {
        let res = userService.deleteDemo(user.username, user.password)
        BaseResponse.success("删除成功，${res}条数据")
    }

    @PostMapping[path:'/api/db/deleteDemo2']
    @IgnoreSecurity
    public func deleteDemo2(@RequestBody user: UserReq): BaseResponse {
        let res = userService.deleteDemo2(user.username, user.password)
        BaseResponse.success("删除成功，${res}条数据")
    }

    // delete 请求，必须指定 produces consumes
    @DeleteMapping[path:'/api/db/deleteDemo3',produces:'application/json',consumes:'application/json']
    @IgnoreSecurity
    public func deleteDemo3(@RequestBody user: UserReq): BaseResponse {
        let res = userService.deleteDemo2(user.username, user.password)
        BaseResponse.success("删除成功，${res}条数据")
    }

    @DeleteMapping[path:'/api/db/deleteDemo4']
    @IgnoreSecurity
    public func deleteDemo4(): String {
        "hello delete"
    }

    @DeleteMapping[path:'/api/db/deleteDemo5/{id}',produces:'application/json',consumes:'application/x-www-form-urlencoded']
    @IgnoreSecurity
    public func deleteDemo5(@PathVariable id: Int64): JsonValue {
        let json = '''
        {
            "code": 0,
            "status": 1,
            "fields": {
                "deleted": 1
            }
        }'''
        JsonValue.fromStr(json)
    }

    @DeleteMapping[path:'/api/db/deleteDemo6/{id}',produces:'text/plain',consumes:'application/x-www-form-urlencoded']
    @IgnoreSecurity
    public func deleteDemo6(@PathVariable id: Int64): String {
        "hello 6"
    }

    @DeleteMapping[path:'/api/db/deleteDemo7/{id}',produces:'application/json',consumes:'application/json']
    @IgnoreSecurity
    public func deleteDemo7(@PathVariable id: Int64): JsonValue {
        let json = '''
        {
            "code": 0,
            "status": 1,
            "fields": {
                "deleted": 1
            }
        }'''
        JsonValue.fromStr(json)
    }


}
