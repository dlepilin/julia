# This file is a part of Julia. License is MIT: https://julialang.org/license

abstract type AbstractCmd end

# libuv process option flags
const UV_PROCESS_WINDOWS_VERBATIM_ARGUMENTS = UInt8(1 << 2)
const UV_PROCESS_DETACHED = UInt8(1 << 3)
const UV_PROCESS_WINDOWS_HIDE = UInt8(1 << 4)

struct Cmd <: AbstractCmd
    exec::Vector{String}
    ignorestatus::Bool
    flags::UInt32 # libuv process flags
    env::Union{Array{String},Void}
    dir::String
    Cmd(exec::Vector{String}) =
        new(exec, false, 0x00, nothing, "")
    Cmd(cmd::Cmd, ignorestatus, flags, env, dir) =
        new(cmd.exec, ignorestatus, flags, env,
            dir === cmd.dir ? dir : cstr(dir))
    function Cmd(cmd::Cmd; ignorestatus::Bool=cmd.ignorestatus, env=cmd.env, dir::AbstractString=cmd.dir,
                 detach::Bool = 0 != cmd.flags & UV_PROCESS_DETACHED,
                 windows_verbatim::Bool = 0 != cmd.flags & UV_PROCESS_WINDOWS_VERBATIM_ARGUMENTS,
                 windows_hide::Bool = 0 != cmd.flags & UV_PROCESS_WINDOWS_HIDE)
        flags = detach*UV_PROCESS_DETACHED |
                windows_verbatim*UV_PROCESS_WINDOWS_VERBATIM_ARGUMENTS |
                windows_hide*UV_PROCESS_WINDOWS_HIDE
        new(cmd.exec, ignorestatus, flags, byteenv(env),
            dir === cmd.dir ? dir : cstr(dir))
    end
end

"""
    Cmd(cmd::Cmd; ignorestatus, detach, windows_verbatim, windows_hide, env, dir)

Construct a new `Cmd` object, representing an external program and arguments, from `cmd`,
while changing the settings of the optional keyword arguments:

* `ignorestatus::Bool`: If `true` (defaults to `false`), then the `Cmd` will not throw an
  error if the return code is nonzero.
* `detach::Bool`: If `true` (defaults to `false`), then the `Cmd` will be run in a new
  process group, allowing it to outlive the `julia` process and not have Ctrl-C passed to
  it.
* `windows_verbatim::Bool`: If `true` (defaults to `false`), then on Windows the `Cmd` will
  send a command-line string to the process with no quoting or escaping of arguments, even
  arguments containing spaces. (On Windows, arguments are sent to a program as a single
  "command-line" string, and programs are responsible for parsing it into arguments. By
  default, empty arguments and arguments with spaces or tabs are quoted with double quotes
  `"` in the command line, and `\\` or `"` are preceded by backslashes.
  `windows_verbatim=true` is useful for launching programs that parse their command line in
  nonstandard ways.) Has no effect on non-Windows systems.
* `windows_hide::Bool`: If `true` (defaults to `false`), then on Windows no new console
  window is displayed when the `Cmd` is executed. This has no effect if a console is
  already open or on non-Windows systems.
* `env`: Set environment variables to use when running the `Cmd`. `env` is either a
  dictionary mapping strings to strings, an array of strings of the form `"var=val"`, an
  array or tuple of `"var"=>val` pairs, or `nothing`. In order to modify (rather than
  replace) the existing environment, create `env` by `copy(ENV)` and then set
  `env["var"]=val` as desired.
* `dir::AbstractString`: Specify a working directory for the command (instead
  of the current directory).

For any keywords that are not specified, the current settings from `cmd` are used. Normally,
to create a `Cmd` object in the first place, one uses backticks, e.g.

    Cmd(`echo "Hello world"`, ignorestatus=true, detach=false)
"""
Cmd

hash(x::Cmd, h::UInt) = hash(x.exec, hash(x.env, hash(x.ignorestatus, hash(x.dir, hash(x.flags, h)))))
==(x::Cmd, y::Cmd) = x.exec == y.exec && x.env == y.env && x.ignorestatus == y.ignorestatus &&
                     x.dir == y.dir && isequal(x.flags, y.flags)

struct OrCmds <: AbstractCmd
    a::AbstractCmd
    b::AbstractCmd
    OrCmds(a::AbstractCmd, b::AbstractCmd) = new(a, b)
end

struct ErrOrCmds <: AbstractCmd
    a::AbstractCmd
    b::AbstractCmd
    ErrOrCmds(a::AbstractCmd, b::AbstractCmd) = new(a, b)
end

struct AndCmds <: AbstractCmd
    a::AbstractCmd
    b::AbstractCmd
    AndCmds(a::AbstractCmd, b::AbstractCmd) = new(a, b)
end

hash(x::AndCmds, h::UInt) = hash(x.a, hash(x.b, h))
==(x::AndCmds, y::AndCmds) = x.a == y.a && x.b == y.b

shell_escape(cmd::Cmd; special::AbstractString="") =
    shell_escape(cmd.exec..., special=special)

function show(io::IO, cmd::Cmd)
    print_env = cmd.env !== nothing
    print_dir = !isempty(cmd.dir)
    (print_env || print_dir) && print(io, "setenv(")
    esc = shell_escape(cmd, special=shell_special)
    print(io, '`')
    for c in esc
        if c == '`'
            print(io, '\\')
        end
        print(io, c)
    end
    print(io, '`')
    print_env && (print(io, ","); show(io, cmd.env))
    print_dir && (print(io, "; dir="); show(io, cmd.dir))
    (print_dir || print_env) && print(io, ")")
end

function show(io::IO, cmds::Union{OrCmds,ErrOrCmds})
    print(io, "pipeline(")
    show(io, cmds.a)
    print(io, ", ")
    print(io, isa(cmds, ErrOrCmds) ? "stderr=" : "stdout=")
    show(io, cmds.b)
    print(io, ")")
end

function show(io::IO, cmds::AndCmds)
    show(io, cmds.a)
    print(io, " & ")
    show(io, cmds.b)
end

const STDIN_NO  = 0
const STDOUT_NO = 1
const STDERR_NO = 2

struct FileRedirect
    filename::AbstractString
    append::Bool
    function FileRedirect(filename, append)
        if lowercase(filename) == (@static is_windows() ? "nul" : "/dev/null")
            warn_once("for portability use DevNull instead of a file redirect")
        end
        new(filename, append)
    end
end

uvhandle(::DevNullStream) = C_NULL
uvtype(::DevNullStream) = UV_STREAM

uvhandle(x::Ptr) = x
uvtype(::Ptr) = UV_STREAM

# Not actually a pointer, but that's how we pass it through the C API so it's fine
uvhandle(x::RawFD) = convert(Ptr{Void}, x.fd % UInt)
uvtype(x::RawFD) = UV_RAW_FD

const Redirectable = Union{IO, FileRedirect, RawFD}
const StdIOSet = NTuple{3, Union{Redirectable, Ptr{Void}}} # XXX: remove Ptr{Void} once libuv is refactored to use upstream release

struct CmdRedirect <: AbstractCmd
    cmd::AbstractCmd
    handle::Redirectable
    stream_no::Int
end

function show(io::IO, cr::CmdRedirect)
    print(io, "pipeline(")
    show(io, cr.cmd)
    print(io, ", ")
    if cr.stream_no == STDOUT_NO
        print(io, "stdout=")
    elseif cr.stream_no == STDERR_NO
        print(io, "stderr=")
    elseif cr.stream_no == STDIN_NO
        print(io, "stdin=")
    end
    show(io, cr.handle)
    print(io, ")")
end

"""
    ignorestatus(command)

Mark a command object so that running it will not throw an error if the result code is non-zero.
"""
ignorestatus(cmd::Cmd) = Cmd(cmd, ignorestatus=true)
ignorestatus(cmd::Union{OrCmds,AndCmds}) =
    typeof(cmd)(ignorestatus(cmd.a), ignorestatus(cmd.b))

"""
    detach(command)

Mark a command object so that it will be run in a new process group, allowing it to outlive the julia process, and not have Ctrl-C interrupts passed to it.
"""
detach(cmd::Cmd) = Cmd(cmd; detach=true)

# like String(s), but throw an error if s contains NUL, since
# libuv requires NUL-terminated strings
function cstr(s)
    if Base.containsnul(s)
        throw(ArgumentError("strings containing NUL cannot be passed to spawned processes"))
    end
    return String(s)
end

# convert various env representations into an array of "key=val" strings
byteenv(env::AbstractArray{<:AbstractString}) =
    String[cstr(x) for x in env]
byteenv(env::Associative) =
    String[cstr(string(k)*"="*string(v)) for (k,v) in env]
byteenv(env::Void) = nothing
byteenv{T<:AbstractString}(env::Union{AbstractVector{Pair{T}}, Tuple{Vararg{Pair{T}}}}) =
    String[cstr(k*"="*string(v)) for (k,v) in env]

"""
    setenv(command::Cmd, env; dir="")

Set environment variables to use when running the given `command`. `env` is either a
dictionary mapping strings to strings, an array of strings of the form `"var=val"`, or zero
or more `"var"=>val` pair arguments. In order to modify (rather than replace) the existing
environment, create `env` by `copy(ENV)` and then setting `env["var"]=val` as desired, or
use `withenv`.

The `dir` keyword argument can be used to specify a working directory for the command.
"""
setenv(cmd::Cmd, env; dir="") = Cmd(cmd; env=byteenv(env), dir=dir)
setenv(cmd::Cmd, env::Pair{<:AbstractString}...; dir="") =
    setenv(cmd, env; dir=dir)
setenv(cmd::Cmd; dir="") = Cmd(cmd; dir=dir)

(&)(left::AbstractCmd, right::AbstractCmd) = AndCmds(left, right)
redir_out(src::AbstractCmd, dest::AbstractCmd) = OrCmds(src, dest)
redir_err(src::AbstractCmd, dest::AbstractCmd) = ErrOrCmds(src, dest)
Base.mr_empty(f, op::typeof(&), T::Type{<:Base.AbstractCmd}) =
    throw(ArgumentError("reducing over an empty collection of type $T with operator & is not allowed"))

# Stream Redirects
redir_out(dest::Redirectable, src::AbstractCmd) = CmdRedirect(src, dest, STDIN_NO)
redir_out(src::AbstractCmd, dest::Redirectable) = CmdRedirect(src, dest, STDOUT_NO)
redir_err(src::AbstractCmd, dest::Redirectable) = CmdRedirect(src, dest, STDERR_NO)

# File redirects
redir_out(src::AbstractCmd, dest::AbstractString) = CmdRedirect(src, FileRedirect(dest, false), STDOUT_NO)
redir_out(src::AbstractString, dest::AbstractCmd) = CmdRedirect(dest, FileRedirect(src, false), STDIN_NO)
redir_err(src::AbstractCmd, dest::AbstractString) = CmdRedirect(src, FileRedirect(dest, false), STDERR_NO)
redir_out_append(src::AbstractCmd, dest::AbstractString) = CmdRedirect(src, FileRedirect(dest, true), STDOUT_NO)
redir_err_append(src::AbstractCmd, dest::AbstractString) = CmdRedirect(src, FileRedirect(dest, true), STDERR_NO)

"""
    pipeline(command; stdin, stdout, stderr, append=false)

Redirect I/O to or from the given `command`. Keyword arguments specify which of the
command's streams should be redirected. `append` controls whether file output appends to the
file. This is a more general version of the 2-argument `pipeline` function.
`pipeline(from, to)` is equivalent to `pipeline(from, stdout=to)` when `from` is a command,
and to `pipeline(to, stdin=from)` when `from` is another kind of data source.

**Examples**:

```julia
run(pipeline(`dothings`, stdout="out.txt", stderr="errs.txt"))
run(pipeline(`update`, stdout="log.txt", append=true))
```
"""
function pipeline(cmd::AbstractCmd; stdin=nothing, stdout=nothing, stderr=nothing, append::Bool=false)
    if append && stdout === nothing && stderr === nothing
        error("append set to true, but no output redirections specified")
    end
    if stdin !== nothing
        cmd = redir_out(stdin, cmd)
    end
    if stdout !== nothing
        cmd = append ? redir_out_append(cmd, stdout) : redir_out(cmd, stdout)
    end
    if stderr !== nothing
        cmd = append ? redir_err_append(cmd, stderr) : redir_err(cmd, stderr)
    end
    return cmd
end

pipeline(cmd::AbstractCmd, dest) = pipeline(cmd, stdout=dest)
pipeline(src::Union{Redirectable,AbstractString}, cmd::AbstractCmd) = pipeline(cmd, stdin=src)

"""
    pipeline(from, to, ...)

Create a pipeline from a data source to a destination. The source and destination can be
commands, I/O streams, strings, or results of other `pipeline` calls. At least one argument
must be a command. Strings refer to filenames. When called with more than two arguments,
they are chained together from left to right. For example `pipeline(a,b,c)` is equivalent to
`pipeline(pipeline(a,b),c)`. This provides a more concise way to specify multi-stage
pipelines.

**Examples**:

```julia
run(pipeline(`ls`, `grep xyz`))
run(pipeline(`ls`, "out.txt"))
run(pipeline("out.txt", `grep xyz`))
```
"""
pipeline(a, b, c, d...) = pipeline(pipeline(a,b), c, d...)

mutable struct Process <: AbstractPipe
    cmd::Cmd
    handle::Ptr{Void}
    in::IO
    out::IO
    err::IO
    exitcode::Int64
    termsignal::Int32
    exitnotify::Condition
    closenotify::Condition
    openstream::Symbol # for open(cmd) deprecation
    function Process(cmd::Cmd, handle::Ptr{Void},
                     in::Union{Redirectable, Ptr{Void}},
                     out::Union{Redirectable, Ptr{Void}},
                     err::Union{Redirectable, Ptr{Void}})
        if !isa(in, IO)
            in = DevNull
        end
        if !isa(out, IO)
            out = DevNull
        end
        if !isa(err, IO)
            err = DevNull
        end
        this = new(cmd, handle, in, out, err,
                   typemin(fieldtype(Process, :exitcode)),
                   typemin(fieldtype(Process, :termsignal)),
                   Condition(), Condition())
        finalizer(this, uvfinalize)
        return this
    end
end
pipe_reader(p::Process) = p.out
pipe_writer(p::Process) = p.in

struct ProcessChain <: AbstractPipe
    processes::Vector{Process}
    in::Redirectable
    out::Redirectable
    err::Redirectable
    openstream::Symbol # for open(cmd) deprecation
    ProcessChain(stdios::StdIOSet) = new(Process[], stdios[1], stdios[2], stdios[3])
    ProcessChain(chain::ProcessChain, openstream::Symbol) = new(chain.processes, chain.in, chain.out, chain.err, openstream) # for open(cmd) deprecation
end
pipe_reader(p::ProcessChain) = p.out
pipe_writer(p::ProcessChain) = p.in

function _jl_spawn(cmd, argv, loop::Ptr{Void}, pp::Process,
                   in, out, err)
    proc = Libc.malloc(_sizeof_uv_process)
    disassociate_julia_struct(proc)
    error = ccall(:jl_spawn, Int32,
        (Cstring, Ptr{Cstring}, Ptr{Void}, Ptr{Void}, Any, Int32,
         Ptr{Void}, Int32, Ptr{Void}, Int32, Ptr{Void}, Int32, Ptr{Cstring}, Cstring, Ptr{Void}),
        cmd, argv, loop, proc, pp, uvtype(in),
        uvhandle(in), uvtype(out), uvhandle(out), uvtype(err), uvhandle(err),
        pp.cmd.flags, pp.cmd.env === nothing ? C_NULL : pp.cmd.env, isempty(pp.cmd.dir) ? C_NULL : pp.cmd.dir,
        uv_jl_return_spawn::Ptr{Void})
    if error != 0
        ccall(:jl_forceclose_uv, Void, (Ptr{Void},), proc)
        throw(UVError("could not spawn "*string(pp.cmd), error))
    end
    associate_julia_struct(proc, pp)
    return proc
end

function uvfinalize(proc::Process)
    if proc.handle != C_NULL
        disassociate_julia_struct(proc.handle)
        ccall(:jl_close_uv, Void, (Ptr{Void},), proc.handle)
        proc.handle = C_NULL
    end
    nothing
end

function uv_return_spawn(p::Ptr{Void}, exit_status::Int64, termsignal::Int32)
    data = ccall(:jl_uv_process_data, Ptr{Void}, (Ptr{Void},), p)
    data == C_NULL && return
    proc = unsafe_pointer_to_objref(data)::Process
    proc.exitcode = exit_status
    proc.termsignal = termsignal
    ccall(:jl_close_uv, Void, (Ptr{Void},), proc.handle)
    notify(proc.exitnotify)
    nothing
end

function _uv_hook_close(proc::Process)
    proc.handle = C_NULL
    notify(proc.closenotify)
end

function spawn(redirect::CmdRedirect, stdios::StdIOSet; chain::Nullable{ProcessChain}=Nullable{ProcessChain}())
    spawn(redirect.cmd,
          (redirect.stream_no == STDIN_NO  ? redirect.handle : stdios[1],
           redirect.stream_no == STDOUT_NO ? redirect.handle : stdios[2],
           redirect.stream_no == STDERR_NO ? redirect.handle : stdios[3]),
           chain=chain)
end

function spawn(cmds::OrCmds, stdios::StdIOSet; chain::Nullable{ProcessChain}=Nullable{ProcessChain}())
    out_pipe = Libc.malloc(_sizeof_uv_named_pipe)
    in_pipe = Libc.malloc(_sizeof_uv_named_pipe)
    link_pipe(in_pipe, false, out_pipe, false)
    if isnull(chain)
        chain = Nullable(ProcessChain(stdios))
    end
    try
        spawn(cmds.a, (stdios[1], out_pipe, stdios[3]), chain=chain)
        spawn(cmds.b, (in_pipe, stdios[2], stdios[3]), chain=chain)
    finally
        close_pipe_sync(out_pipe)
        close_pipe_sync(in_pipe)
        Libc.free(out_pipe)
        Libc.free(in_pipe)
    end
    get(chain)
end

function spawn(cmds::ErrOrCmds, stdios::StdIOSet; chain::Nullable{ProcessChain}=Nullable{ProcessChain}())
    out_pipe = Libc.malloc(_sizeof_uv_named_pipe)
    in_pipe = Libc.malloc(_sizeof_uv_named_pipe)
    link_pipe(in_pipe, false, out_pipe, false)
    if isnull(chain)
        chain = Nullable(ProcessChain(stdios))
    end
    try
        spawn(cmds.a, (stdios[1], stdios[2], out_pipe), chain=chain)
        spawn(cmds.b, (in_pipe, stdios[2], stdios[3]), chain=chain)
    finally
        close_pipe_sync(out_pipe)
        close_pipe_sync(in_pipe)
        Libc.free(out_pipe)
        Libc.free(in_pipe)
    end
    get(chain)
end

function setup_stdio(stdio::PipeEndpoint, readable::Bool)
    closeafter = false
    if stdio.status == StatusUninit
        if readable
            link_pipe(io, false, stdio, true)
        else
            link_pipe(stdio, true, io, false)
        end
        closeafter = true
    end
    return (stdio.handle, closeafter)
end

function setup_stdio(stdio::Pipe, readable::Bool)
    if stdio.in.status == StatusUninit && stdio.out.status == StatusUninit
        link_pipe(stdio)
    end
    io = readable ? stdio.out : stdio.in
    return (io, false)
end

function setup_stdio(stdio::IOStream, readable::Bool)
    io = Filesystem.File(RawFD(fd(stdio)))
    return (io, false)
end

function setup_stdio(stdio::FileRedirect, readable::Bool)
    if readable
        attr = JL_O_RDONLY
        perm = zero(S_IRUSR)
    else
        attr = JL_O_WRONLY | JL_O_CREAT
        attr |= stdio.append ? JL_O_APPEND : JL_O_TRUNC
        perm = S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH
    end
    io = Filesystem.open(stdio.filename, attr, perm)
    return (io, true)
end

function setup_stdio(io, readable::Bool)
    # if there is no specialization,
    # assume that uvhandle and uvtype are defined for it
    return io, false
end

function setup_stdio(stdio::Ptr{Void}, readable::Bool)
    return (stdio, false)
end

function close_stdio(stdio::Ptr{Void})
    close_pipe_sync(stdio)
    Libc.free(stdio)
end

function close_stdio(stdio)
    close(stdio)
end

function setup_stdio(anon::Function, stdio::StdIOSet)
    in, close_in = setup_stdio(stdio[1], true)
    out, close_out = setup_stdio(stdio[2], false)
    err, close_err = setup_stdio(stdio[3], false)
    anon(in, out, err)
    close_in  && close_stdio(in)
    close_out && close_stdio(out)
    close_err && close_stdio(err)
end

function spawn(cmd::Cmd, stdios::StdIOSet; chain::Nullable{ProcessChain}=Nullable{ProcessChain}())
    if isempty(cmd.exec)
        throw(ArgumentError("cannot spawn empty command"))
    end
    loop = eventloop()
    pp = Process(cmd, C_NULL, stdios[1], stdios[2], stdios[3])
    setup_stdio(stdios) do in, out, err
        pp.handle = _jl_spawn(cmd.exec[1], cmd.exec, loop, pp,
                              in, out, err)
    end
    if !isnull(chain)
        push!(get(chain).processes, pp)
    end
    pp
end

function spawn(cmds::AndCmds, stdios::StdIOSet; chain::Nullable{ProcessChain}=Nullable{ProcessChain}())
    if isnull(chain)
        chain = Nullable(ProcessChain(stdios))
    end
    setup_stdio(stdios) do in, out, err
        spawn(cmds.a, (in,out,err), chain=chain)
        spawn(cmds.b, (in,out,err), chain=chain)
    end
    get(chain)
end

# INTERNAL
# returns stdios:
# A set of up to 256 stdio instructions, where each entry can be either:
#   | - An IO to be passed to the child
#   | - DevNull to pass /dev/null
#   | - An Filesystem.File object to redirect the output to
#   \ - A string specifying a filename to be opened

spawn_opts_swallow(stdios::StdIOSet) = (stdios,)
spawn_opts_swallow(in::Redirectable=DevNull, out::Redirectable=DevNull, err::Redirectable=DevNull, args...) =
    ((in, out, err), args...)
spawn_opts_inherit(stdios::StdIOSet) = (stdios,)
# pass original descriptors to child processes by default, because we might
# have already exhausted and closed the libuv object for our standard streams.
# this caused issue #8529.
spawn_opts_inherit(in::Redirectable=RawFD(0), out::Redirectable=RawFD(1), err::Redirectable=RawFD(2), args...) =
    ((in, out, err), args...)

spawn(cmds::AbstractCmd, args...; chain::Nullable{ProcessChain}=Nullable{ProcessChain}()) =
    spawn(cmds, spawn_opts_swallow(args...)...; chain=chain)

function eachline(cmd::AbstractCmd, stdin; chomp::Bool=true)
    stdout = Pipe()
    processes = spawn(cmd, (stdin,stdout,STDERR))
    close(stdout.in)
    out = stdout.out
    # implicitly close after reading lines, since we opened
    return EachLine(out, chomp=chomp,
        ondone=()->(close(out); success(processes) || pipeline_error(processes)))::EachLine
end
eachline(cmd::AbstractCmd; chomp::Bool=true) = eachline(cmd, DevNull, chomp=chomp)

# return a Process object to read-to/write-from the pipeline
"""
    open(command, mode::AbstractString="r", stdio=DevNull)

Start running `command` asynchronously, and return a tuple `(stream,process)`.  If `mode` is
`"r"`, then `stream` reads from the process's standard output and `stdio` optionally
specifies the process's standard input stream.  If `mode` is `"w"`, then `stream` writes to
the process's standard input and `stdio` optionally specifies the process's standard output
stream.
"""
function open(cmds::AbstractCmd, mode::AbstractString="r", other::Redirectable=DevNull)
    if mode == "r+" || mode == "w+"
        other === DevNull || throw(ArgumentError("no other stream for mode rw+"))
        in = Pipe()
        out = Pipe()
        processes = spawn(cmds, (in,out,STDERR))
        close(in.out)
        close(out.in)
    elseif mode == "r"
        in = other
        out = Pipe()
        processes = spawn(cmds, (in,out,STDERR))
        close(out.in)
        if isa(processes, ProcessChain) # for open(cmd) deprecation
            processes = ProcessChain(processes, :out)
        else
            processes.openstream = :out
        end
    elseif mode == "w"
        in = Pipe()
        out = other
        processes = spawn(cmds, (in,out,STDERR))
        close(in.out)
        if isa(processes, ProcessChain) # for open(cmd) deprecation
            processes = ProcessChain(processes, :in)
        else
            processes.openstream = :in
        end
    else
        throw(ArgumentError("mode must be \"r\" or \"w\", not \"$mode\""))
    end
    return processes
end

"""
    open(f::Function, command, mode::AbstractString="r", stdio=DevNull)

Similar to `open(command, mode, stdio)`, but calls `f(stream)` on the resulting process
stream, then closes the input stream and waits for the process to complete.
Returns the value returned by `f`.
"""
function open(f::Function, cmds::AbstractCmd, args...)
    P = open(cmds, args...)
    ret = try
        f(P)
    catch e
        kill(P)
        rethrow(e)
    finally
        close(P.in)
    end
    success(P) || pipeline_error(P)
    return ret
end

# TODO: deprecate this

"""
    readandwrite(command)

Starts running a command asynchronously, and returns a tuple (stdout,stdin,process) of the
output stream and input stream of the process, and the process object itself.
"""
function readandwrite(cmds::AbstractCmd)
    processes = open(cmds, "r+")
    return (processes.out, processes.in, processes)
end

function read(cmd::AbstractCmd, stdin::Redirectable=DevNull)
    procs = open(cmd, "r", stdin)
    bytes = read(procs.out)
    success(procs) || pipeline_error(procs)
    return bytes
end

function readstring(cmd::AbstractCmd, stdin::Redirectable=DevNull)
    return String(read(cmd, stdin))
end

function writeall(cmd::AbstractCmd, stdin::AbstractString, stdout::Redirectable=DevNull)
    open(cmd, "w", stdout) do io
        write(io, stdin)
    end
end

"""
    run(command, args...)

Run a command object, constructed with backticks. Throws an error if anything goes wrong,
including the process exiting with a non-zero status.
"""
function run(cmds::AbstractCmd, args...)
    ps = spawn(cmds, spawn_opts_inherit(args...)...)
    success(ps) ? nothing : pipeline_error(ps)
end

# some common signal numbers that are usually available on all platforms
# and might be useful as arguments to `kill` or testing against `Process.termsignal`
const SIGHUP  = 1
const SIGINT  = 2
const SIGQUIT = 3 # !windows
const SIGKILL = 9
const SIGPIPE = 13 # !windows
const SIGTERM = 15

function test_success(proc::Process)
    @assert process_exited(proc)
    if proc.exitcode < 0
        #TODO: this codepath is not currently tested
        throw(UVError("could not start process $(string(proc.cmd))", proc.exitcode))
    end
    proc.exitcode == 0 && (proc.termsignal == 0 || proc.termsignal == SIGPIPE)
end

function success(x::Process)
    wait(x)
    return test_success(x)
end
success(procs::Vector{Process}) = mapreduce(success, &, procs)
success(procs::ProcessChain) = success(procs.processes)

"""
    success(command)

Run a command object, constructed with backticks, and tell whether it was successful (exited
with a code of 0). An exception is raised if the process cannot be started.
"""
success(cmd::AbstractCmd) = success(spawn(cmd))

function pipeline_error(proc::Process)
    if !proc.cmd.ignorestatus
        error("failed process: ", proc, " [", proc.exitcode, "]")
    end
    nothing
end

function pipeline_error(procs::ProcessChain)
    failed = Process[]
    for p = procs.processes
        if !test_success(p) && !p.cmd.ignorestatus
            push!(failed, p)
        end
    end
    isempty(failed) && return nothing
    length(failed) == 1 && pipeline_error(failed[1])
    msg = "failed processes:"
    for proc in failed
        msg = string(msg, "\n  ", proc, " [", proc.exitcode, "]")
    end
    error(msg)
end

"""
    kill(p::Process, signum=SIGTERM)

Send a signal to a process. The default is to terminate the process.
"""
function kill(p::Process, signum::Integer)
    if process_running(p)
        @assert p.handle != C_NULL
        ccall(:uv_process_kill, Int32, (Ptr{Void}, Int32), p.handle, signum)
    else
        Int32(-1)
    end
end
kill(ps::Vector{Process}) = map(kill, ps)
kill(ps::ProcessChain) = map(kill, ps.processes)
kill(p::Process) = kill(p, SIGTERM)

function _contains_newline(bufptr::Ptr{Void}, len::Int32)
    return (ccall(:memchr, Ptr{Void}, (Ptr{Void},Int32,Csize_t), bufptr, '\n', len) != C_NULL)
end

## process status ##

"""
    process_running(p::Process)

Determine whether a process is currently running.
"""
process_running(s::Process) = s.exitcode == typemin(fieldtype(Process, :exitcode))
process_running(s::Vector{Process}) = any(process_running, s)
process_running(s::ProcessChain) = process_running(s.processes)

"""
    process_exited(p::Process)

Determine whether a process has exited.
"""
process_exited(s::Process) = !process_running(s)
process_exited(s::Vector{Process}) = all(process_exited, s)
process_exited(s::ProcessChain) = process_exited(s.processes)

process_signaled(s::Process) = (s.termsignal > 0)

#process_stopped (s::Process) = false #not supported by libuv. Do we need this?
#process_stop_signal(s::Process) = false #not supported by libuv. Do we need this?

function process_status(s::Process)
    process_running(s) ? "ProcessRunning" :
    process_signaled(s) ? "ProcessSignaled("*string(s.termsignal)*")" :
    #process_stopped(s) ? "ProcessStopped("*string(process_stop_signal(s))*")" :
    process_exited(s) ? "ProcessExited("*string(s.exitcode)*")" :
    error("process status error")
end

## implementation of `cmd` syntax ##

arg_gen()          = String[]
arg_gen(x::AbstractString) = String[cstr(x)]
arg_gen(cmd::Cmd)  = cmd.exec

function arg_gen(head)
    if applicable(start, head)
        vals = String[]
        for x in head
            push!(vals, cstr(string(x)))
        end
        return vals
    else
        return String[cstr(string(head))]
    end
end

function arg_gen(head, tail...)
    head = arg_gen(head)
    tail = arg_gen(tail...)
    vals = String[]
    for h = head, t = tail
        push!(vals, cstr(string(h,t)))
    end
    return vals
end

function cmd_gen(parsed)
    args = String[]
    for arg in parsed
        append!(args, arg_gen(arg...))
    end
    return Cmd(args)
end

macro cmd(str)
    return :(cmd_gen($(shell_parse(str, special=shell_special)[1])))
end

wait(x::Process)      = if !process_exited(x); stream_wait(x, x.exitnotify); end
wait(x::ProcessChain) = for p in x.processes; wait(p); end

show(io::IO, p::Process) = print(io, "Process(", p.cmd, ", ", process_status(p), ")")
