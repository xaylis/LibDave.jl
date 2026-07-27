using libdave_jll: libdave_testutils

# test only stand-in for the MLS external sender that Discord's
# voice gateway provides in production
mutable struct ExternalSender
    handle::Ptr{Cvoid}

    function ExternalSender(group_id::Integer)
        h = @ccall libdave_testutils.daveExternalSenderCreate(group_id::UInt64)::Ptr{Cvoid}
        h == C_NULL && error("failed to create external sender")
        sender = new(h)
        finalizer(sender) do s
            @ccall libdave_testutils.daveExternalSenderDestroy(s.handle::Ptr{Cvoid})::Cvoid
        end
    end
end

function marshalled_external_sender(sender::ExternalSender)
    data = Ref(Ptr{UInt8}(C_NULL))
    len = Ref{Csize_t}(0)
    @ccall libdave_testutils.daveExternalSenderGetMarshalledExternalSender(
        sender.handle::Ptr{Cvoid}, data::Ptr{Ptr{UInt8}}, len::Ptr{Csize_t})::Cvoid
    LibDave.take_bytes(data, len)
end

function propose_add(sender::ExternalSender, epoch::Integer, key_package::Vector{UInt8})
    data = Ref(Ptr{UInt8}(C_NULL))
    len = Ref{Csize_t}(0)
    @ccall libdave_testutils.daveExternalSenderProposeAdd(sender.handle::Ptr{Cvoid},
        epoch::UInt32, key_package::Ptr{UInt8}, length(key_package)::Csize_t,
        data::Ptr{Ptr{UInt8}}, len::Ptr{Csize_t})::Cvoid
    LibDave.take_bytes(data, len)
end

function split_commit_welcome(sender::ExternalSender, commit_welcome::Vector{UInt8})
    commit = Ref(Ptr{UInt8}(C_NULL))
    commit_len = Ref{Csize_t}(0)
    welcome = Ref(Ptr{UInt8}(C_NULL))
    welcome_len = Ref{Csize_t}(0)
    @ccall libdave_testutils.daveExternalSenderSplitCommitWelcome(sender.handle::Ptr{Cvoid},
        commit_welcome::Ptr{UInt8}, length(commit_welcome)::Csize_t,
        commit::Ptr{Ptr{UInt8}}, commit_len::Ptr{Csize_t},
        welcome::Ptr{Ptr{UInt8}}, welcome_len::Ptr{Csize_t})::Cvoid
    LibDave.take_bytes(commit, commit_len), LibDave.take_bytes(welcome, welcome_len)
end
