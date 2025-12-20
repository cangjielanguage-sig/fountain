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
package f_io

import std.io.{ByteBuffer, ChainedInputStream, MultiOutputStream, BufferedInputStream, BufferedOutputStream, copy}
import std.fs.File
import std.net.TcpSocket
import std.net.UnixSocket

public interface BytesCopyTo {
    func copy(to!: OutputStream): Unit
}
public interface BytesCopyFrom {
    func copy(from!: InputStream): Unit
}

public interface BytesCopier <: BytesCopyTo & BytesCopyFrom {}
extend File <: BytesCopier {
    public func copy(to!: OutputStream): Unit {
        copy(this, to: to)
    }
    public func copy(from!: InputStream): Unit {
        copy(from, to: this)
    }
}
extend TcpSocket <: BytesCopier {
    public func copy(to!: OutputStream): Unit {
        copy(this, to: to)
    }
    public func copy(from!: InputStream): Unit {
        copy(from, to: this)
    }
}
extend UnixSocket <: BytesCopier {
    public func copy(to!: OutputStream): Unit {
        copy(this, to: to)
    }
    public func copy(from!: InputStream): Unit {
        copy(from, to: this)
    }
}
extend<T> ChainedInputStream<T> <: BytesCopyTo where T <: InputStream {
    public func copy(to!: OutputStream): Unit {
        copy(this, to: to)
    }
}
extend<T> MultiOutputStream<T> <: BytesCopyFrom where T <: OutputStream {
    public func copy(from!: InputStream): Unit {
        copy(from, to: this)
    }
}
extend<T> BufferedInputStream<T> <: BytesCopyTo where T <: InputStream {
    public func copy(to!: OutputStream): Unit {
        copy(this, to: to)
    }
}
extend<T> BufferedOutputStream<T> <: BytesCopyFrom where T <: OutputStream {
    public func copy(from!: InputStream): Unit {
        copy(from, to: this)
    }
}