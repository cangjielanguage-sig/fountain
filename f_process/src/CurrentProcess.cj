/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.  
*/
package f_process

import std.io.InputStream
public import std.process.CurrentProcess
public import std.fs.{Path, canonicalize}

import charset4cj.charset.encoding.Charset
import charset4cj.charset.{Charsets, TextReader, TextWriter}
// import charset4cj.{Charset, Charsets, TextReader, TextWriter}

public interface ExtendCurrentProcess {
    func stdReader(charset!: Charset): TextReader
    func stdOutWriter(charset!: Charset): TextWriter
    func stdErrWriter(charset!: Charset): TextWriter
    prop absoluteCommand: Path
    prop absoluteCommandDir: Path
}
extend CurrentProcess <: ExtendCurrentProcess {
    public func stdReader(charset!: Charset = Charsets.UTF8): TextReader{
        TextReader(this.stdIn, charset: charset)
    }
    public func stdOutWriter(charset!: Charset = Charsets.UTF8): TextWriter{
        TextWriter(this.stdOut, charset: charset)
    }
    public func stdErrWriter(charset!: Charset = Charsets.UTF8): TextWriter{
        TextWriter(this.stdErr, charset: charset)
    }
    public prop absoluteCommand: Path {
        get(){
            canonicalize(this.command)
        }
    }
    public prop absoluteCommandDir: Path {
        get(){
            this.absoluteCommand.parent
        }
    }
}