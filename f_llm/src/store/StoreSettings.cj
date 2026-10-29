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
package fountain::f_llm.store

import std.collection.ArrayList

import fountain::f_config.*
import fountain::f_log.*

/**
 * 存储选型配置（1.3）。
 *
 * 新键：`llm_contentStore` / `llm_metaStore` / `llm_metaStorePath` / `llm_contentStoreUrl`。
 * 旧键（`llm_memoryBackend` / `llm_characterBackend` / `llm_memoryPath`）只识别、不生效，
 * 启动时逐条 `warn`，避免「配了旧键以为切了后端」。
 */
public class StoreSettings {
    public static const CONTENT_KEY = 'llm_contentStore'
    public static const META_KEY = 'llm_metaStore'
    public static const META_PATH_KEY = 'llm_metaStorePath'
    public static const CONTENT_URL_KEY = 'llm_contentStoreUrl'

    public static const DEFAULT_CONTENT = 'postgres'
    public static const DEFAULT_META = 'postgres'
    public static const DEFAULT_META_PATH = './data/f_llm-meta'

    private static let log = LoggerFactory.getLogger<StoreSettings>()

    private static let DEPRECATED_KEYS = ['llm_memoryBackend', 'llm_characterBackend', 'llm_memoryPath']

    public let contentStore: String
    public let metaStore: String
    public let metaStorePath: String
    public let contentStoreUrl: String
    /** 检测到的废弃键（只用于告警与测试，不参与选型） */
    public let deprecated: ArrayList<String>

    private init(contentStore: String, metaStore: String, metaStorePath: String,
                 contentStoreUrl: String, deprecated: ArrayList<String>) {
        this.contentStore = contentStore
        this.metaStore = metaStore
        this.metaStorePath = metaStorePath
        this.contentStoreUrl = contentStoreUrl
        this.deprecated = deprecated
    }

    public static func load(): StoreSettings {
        let deprecated = ArrayList<String>()
        for(key in DEPRECATED_KEYS){
            if(Config.getString(key).isSome()){
                deprecated.add(key)
                log.warn{'deprecated config key ignored: ${key}'}
            }
        }
        StoreSettings(
            Config.getString(CONTENT_KEY) ?? DEFAULT_CONTENT,
            Config.getString(META_KEY) ?? DEFAULT_META,
            Config.getString(META_PATH_KEY) ?? DEFAULT_META_PATH,
            Config.getString(CONTENT_URL_KEY) ?? '',
            deprecated
        )
    }
}
