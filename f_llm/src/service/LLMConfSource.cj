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
package fountain::f_llm.service

import std.collection.ArrayList
import std.collection.HashMap
import std.fs.{File, Path}

import fountain::f_bean.*
import fountain::f_data.*

import fountain::f_llm.model.po.*

/**
 * 配置来源：数据库只是其中一种。
 *
 * 实现必须整体返回一份快照（不要返回内部可变结构），装载失败时抛异常，
 * 由调用方决定是否保留旧快照。
 */
public interface LLMConfSource {
    prop name: String
    func load(): ArrayList<LLMConf>
}

/** 数据库来源：唯一入口是 LLMConfService */
public class DatabaseConfSource <: LLMConfSource {
    public prop name: String {
        get() {
            'database'
        }
    }

    public func load(): ArrayList<LLMConf> {
        lookup<LLMConfService>().listEnabled()
    }
}

/** 代码内静态注册，用于测试与嵌入式场景 */
public class StaticConfSource <: LLMConfSource {
    private let confs: ArrayList<LLMConf>

    public init(confs: ArrayList<LLMConf>) {
        this.confs = confs
    }

    public prop name: String {
        get() {
            'static'
        }
    }

    public func load(): ArrayList<LLMConf> {
        let copy = ArrayList<LLMConf>()
        copy.add(all: confs)
        copy
    }
}

/**
 * 本地 JSON 文件来源。
 *
 * 文件内容是一个对象数组，字段名与 LLMConf 成员同名；`conf` 是字符串键值对象。
 */
public class FileConfSource <: LLMConfSource {
    private let path: String

    public init(path: String) {
        this.path = path
    }

    public prop name: String {
        get() {
            'file'
        }
    }

    public func load(): ArrayList<LLMConf> {
        let text = String.fromUtf8(File.readFrom(Path(path)))
        parseConfJson(text)
    }
}

/** 把 JSON 数组文本转成配置列表；解析失败抛异常，不返回半份配置 */
public func parseConfJson(text: String): ArrayList<LLMConf> {
    let root = JsonValue.fromStr(text)
    let confs = ArrayList<LLMConf>()
    for(item in root.asArray().getItems()){
        let obj = item.asObject()
        let conf = LLMConf()
        DataObject<LLMConf>.populate(obj.toData(), conf)
        if(let Some(rawConf) <- obj.get('conf')){
            if(let Some(map) <- fromJson<HashMap<String, String>>(rawConf.toString())){
                conf.setConf(map)
            }
        }
        confs.add(conf)
    }
    confs
}

/** 按名字创建来源；未知名字抛异常（启动阶段就该失败，而不是运行期才发现） */
public func createConfSource(name: String): LLMConfSource {
    match(name){
        case 'database' => DatabaseConfSource()
        case 'file' => throw IllegalArgumentException('file source requires a path: use llm_confSource=file:<path>')
        case _ => throw IllegalArgumentException('unknown llm conf source: ${name}')
    }
}
