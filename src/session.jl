mutable struct KeyRatchet
    handle::Ptr{Cvoid}

    function KeyRatchet(handle::Ptr{Cvoid})
        ratchet = new(handle)
        finalizer(ratchet) do r
            r.handle == C_NULL ||
                @ccall libdave.daveKeyRatchetDestroy(r.handle::Ptr{Cvoid})::Cvoid
        end
    end
end

# libdave invokes this synchronously from inside our own ccalls, so the
# session behind userdata is always rooted while it runs
function mls_failure_trampoline(source::Cstring, reason::Cstring, userdata::Ptr{Cvoid})
    session = unsafe_pointer_to_objref(userdata)
    if session.on_failure !== nothing
        session.on_failure(unsafe_string(source), unsafe_string(reason))
    end
    nothing
end

mutable struct Session
    handle::Ptr{Cvoid}
    on_failure::Union{Nothing,Function}

    function Session(; auth_session_id=nothing, on_failure=nothing)
        session = new(C_NULL, on_failure)
        cb = @cfunction(mls_failure_trampoline, Cvoid, (Cstring, Cstring, Ptr{Cvoid}))
        id = auth_session_id === nothing ? Cstring(C_NULL) : auth_session_id
        session.handle = @ccall libdave.daveSessionCreate(
            C_NULL::Ptr{Cvoid}, id::Cstring, cb::Ptr{Cvoid},
            pointer_from_objref(session)::Ptr{Cvoid})::Ptr{Cvoid}
        session.handle == C_NULL && error("failed to create DAVE session")
        finalizer(session) do s
            s.handle == C_NULL ||
                @ccall libdave.daveSessionDestroy(s.handle::Ptr{Cvoid})::Cvoid
        end
    end
end

function init!(s::Session, version::Integer, group_id::Integer, user_id::AbstractString)
    @ccall libdave.daveSessionInit(s.handle::Ptr{Cvoid}, version::UInt16,
        group_id::UInt64, user_id::Cstring)::Cvoid
    s
end

function reset!(s::Session)
    @ccall libdave.daveSessionReset(s.handle::Ptr{Cvoid})::Cvoid
    s
end

protocol_version(s::Session) =
    @ccall libdave.daveSessionGetProtocolVersion(s.handle::Ptr{Cvoid})::UInt16

set_protocol_version!(s::Session, version::Integer) =
    @ccall libdave.daveSessionSetProtocolVersion(s.handle::Ptr{Cvoid}, version::UInt16)::Cvoid

function set_external_sender!(s::Session, sender::Vector{UInt8})
    @ccall libdave.daveSessionSetExternalSender(s.handle::Ptr{Cvoid},
        sender::Ptr{UInt8}, length(sender)::Csize_t)::Cvoid
    s
end

function key_package(s::Session)
    data = Ref(Ptr{UInt8}(C_NULL))
    len = Ref{Csize_t}(0)
    @ccall libdave.daveSessionGetMarshalledKeyPackage(s.handle::Ptr{Cvoid},
        data::Ptr{Ptr{UInt8}}, len::Ptr{Csize_t})::Cvoid
    take_bytes(data, len)
end

function last_epoch_authenticator(s::Session)
    data = Ref(Ptr{UInt8}(C_NULL))
    len = Ref{Csize_t}(0)
    @ccall libdave.daveSessionGetLastEpochAuthenticator(s.handle::Ptr{Cvoid},
        data::Ptr{Ptr{UInt8}}, len::Ptr{Csize_t})::Cvoid
    take_bytes(data, len)
end

function process_proposals(s::Session, proposals::Vector{UInt8}, recognized_user_ids)
    ids = String[string(id) for id in recognized_user_ids]
    data = Ref(Ptr{UInt8}(C_NULL))
    len = Ref{Csize_t}(0)
    @ccall libdave.daveSessionProcessProposals(s.handle::Ptr{Cvoid},
        proposals::Ptr{UInt8}, length(proposals)::Csize_t,
        ids::Ptr{Cstring}, length(ids)::Csize_t,
        data::Ptr{Ptr{UInt8}}, len::Ptr{Csize_t})::Cvoid
    data[] == C_NULL ? nothing : take_bytes(data, len)
end

struct CommitResult
    failed::Bool
    ignored::Bool
    roster::Dict{UInt64,Vector{UInt8}}
end

function process_commit(s::Session, commit::Vector{UInt8})
    h = @ccall libdave.daveSessionProcessCommit(s.handle::Ptr{Cvoid},
        commit::Ptr{UInt8}, length(commit)::Csize_t)::Ptr{Cvoid}
    h == C_NULL && error("processing commit produced no result")
    failed = @ccall libdave.daveCommitResultIsFailed(h::Ptr{Cvoid})::Bool
    ignored = @ccall libdave.daveCommitResultIsIgnored(h::Ptr{Cvoid})::Bool
    roster = commit_roster(h)
    @ccall libdave.daveCommitResultDestroy(h::Ptr{Cvoid})::Cvoid
    CommitResult(failed, ignored, roster)
end

function process_welcome(s::Session, welcome::Vector{UInt8}, recognized_user_ids)
    ids = String[string(id) for id in recognized_user_ids]
    h = @ccall libdave.daveSessionProcessWelcome(s.handle::Ptr{Cvoid},
        welcome::Ptr{UInt8}, length(welcome)::Csize_t,
        ids::Ptr{Cstring}, length(ids)::Csize_t)::Ptr{Cvoid}
    h == C_NULL && return nothing
    roster = welcome_roster(h)
    @ccall libdave.daveWelcomeResultDestroy(h::Ptr{Cvoid})::Cvoid
    roster
end

function roster_ids(ids::Ref{Ptr{UInt64}}, len::Ref{Csize_t})
    p = ids[]
    n = Int(len[])
    (p == C_NULL || n == 0) && return UInt64[]
    members = copy(unsafe_wrap(Array, p, n))
    @ccall libdave.daveFree(p::Ptr{Cvoid})::Cvoid
    members
end

function commit_roster(h::Ptr{Cvoid})
    ids = Ref(Ptr{UInt64}(C_NULL))
    len = Ref{Csize_t}(0)
    @ccall libdave.daveCommitResultGetRosterMemberIds(h::Ptr{Cvoid},
        ids::Ptr{Ptr{UInt64}}, len::Ptr{Csize_t})::Cvoid
    roster = Dict{UInt64,Vector{UInt8}}()
    for id in roster_ids(ids, len)
        sig = Ref(Ptr{UInt8}(C_NULL))
        siglen = Ref{Csize_t}(0)
        @ccall libdave.daveCommitResultGetRosterMemberSignature(h::Ptr{Cvoid},
            id::UInt64, sig::Ptr{Ptr{UInt8}}, siglen::Ptr{Csize_t})::Cvoid
        roster[id] = take_bytes(sig, siglen)
    end
    roster
end

function welcome_roster(h::Ptr{Cvoid})
    ids = Ref(Ptr{UInt64}(C_NULL))
    len = Ref{Csize_t}(0)
    @ccall libdave.daveWelcomeResultGetRosterMemberIds(h::Ptr{Cvoid},
        ids::Ptr{Ptr{UInt64}}, len::Ptr{Csize_t})::Cvoid
    roster = Dict{UInt64,Vector{UInt8}}()
    for id in roster_ids(ids, len)
        sig = Ref(Ptr{UInt8}(C_NULL))
        siglen = Ref{Csize_t}(0)
        @ccall libdave.daveWelcomeResultGetRosterMemberSignature(h::Ptr{Cvoid},
            id::UInt64, sig::Ptr{Ptr{UInt8}}, siglen::Ptr{Csize_t})::Cvoid
        roster[id] = take_bytes(sig, siglen)
    end
    roster
end

function key_ratchet(s::Session, user_id::AbstractString)
    h = @ccall libdave.daveSessionGetKeyRatchet(s.handle::Ptr{Cvoid},
        user_id::Cstring)::Ptr{Cvoid}
    h == C_NULL ? nothing : KeyRatchet(h)
end

mutable struct FingerprintRequest
    done::Bool
    bytes::Vector{UInt8}
end

const fingerprint_lock = ReentrantLock()
const fingerprint_pending = Dict{UInt,FingerprintRequest}()
const fingerprint_token = Ref{UInt}(0)

# runs on a short lived thread spawned by libdave, not on a Julia thread
function fingerprint_trampoline(data::Ptr{UInt8}, len::Csize_t, userdata::Ptr{Cvoid})
    request = lock(fingerprint_lock) do
        pop!(fingerprint_pending, UInt(userdata), nothing)
    end
    request === nothing && return nothing
    bytes = copy(unsafe_wrap(Array, data, Int(len)))
    lock(fingerprint_lock) do
        request.bytes = bytes
        request.done = true
    end
    nothing
end

function pairwise_fingerprint(s::Session, user_id::AbstractString;
                              version::Integer=protocol_version(s), timeout::Real=30)
    request = FingerprintRequest(false, UInt8[])
    token = lock(fingerprint_lock) do
        t = fingerprint_token[] += 1
        fingerprint_pending[t] = request
        t
    end
    cb = @cfunction(fingerprint_trampoline, Cvoid, (Ptr{UInt8}, Csize_t, Ptr{Cvoid}))
    @ccall libdave.daveSessionGetPairwiseFingerprint(s.handle::Ptr{Cvoid},
        version::UInt16, user_id::Cstring, cb::Ptr{Cvoid}, Ptr{Cvoid}(token)::Ptr{Cvoid})::Cvoid
    status = timedwait(float(timeout); pollint=0.01) do
        lock(() -> request.done, fingerprint_lock)
    end
    if status != :ok
        lock(fingerprint_lock) do
            pop!(fingerprint_pending, token, nothing)
        end
        error("pairwise fingerprint for $user_id did not complete, is the MLS group established?")
    end
    request.bytes
end
