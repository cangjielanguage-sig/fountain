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
package fountain::f_health

import std.runtime.*
import fountain::f_data.*
import fountain::f_data.macros.*

@DataAssist[fields]
public class HealthData {
    public prop allocatedHeapSize: Int64 {
        get(){
            getAllocatedHeapSize()
        }
    }
    public prop blockingThreadCount: Int64 {
        get(){
            getBlockingThreadCount()
        }
    }
    public prop gcCount: Int64 {
        get(){
            getGCCount()
        }
    }
    public prop gcFreedSize: Int64 {
        get(){
            getGCFreedSize()
        }
    }
    public prop gcTime: Int64 {
        get(){
            getGCTime()
        }
    }
    public prop maxHeapSize: Int64 {
        get(){
            getMaxHeapSize()
        }
    }
    public prop nativeThreadCount: Int64 {
        get(){
            getNativeThreadCount()
        }
    }
    public prop processorCount: Int64 {
        get(){
            getProcessorCount()
        }
    }
    public prop threadCount: Int64 {
        get(){
            getThreadCount()
        }
    }
    public prop usedHeapSize: Int64 {
        get(){
            getUsedHeapSize()
        }
    }
}