struct EncryptorStats
    passthroughs::UInt64
    successes::UInt64
    failures::UInt64
    duration::UInt64
    attempts::UInt64
    max_attempts::UInt64
    missing_key::UInt64
end

struct DecryptorStats
    passthroughs::UInt64
    successes::UInt64
    failures::UInt64
    duration::UInt64
    attempts::UInt64
    missing_key::UInt64
    invalid_nonce::UInt64
end

mutable struct Encryptor
    handle::Ptr{Cvoid}

    function Encryptor()
        h = @ccall libdave.daveEncryptorCreate()::Ptr{Cvoid}
        h == C_NULL && error("failed to create encryptor")
        encryptor = new(h)
        finalizer(encryptor) do e
            @ccall libdave.daveEncryptorDestroy(e.handle::Ptr{Cvoid})::Cvoid
        end
    end
end

mutable struct Decryptor
    handle::Ptr{Cvoid}

    function Decryptor()
        h = @ccall libdave.daveDecryptorCreate()::Ptr{Cvoid}
        h == C_NULL && error("failed to create decryptor")
        decryptor = new(h)
        finalizer(decryptor) do d
            @ccall libdave.daveDecryptorDestroy(d.handle::Ptr{Cvoid})::Cvoid
        end
    end
end

# the C api copies the ratchet, the KeyRatchet stays owned by the caller
function set_key_ratchet!(enc::Encryptor, ratchet::KeyRatchet)
    @ccall libdave.daveEncryptorSetKeyRatchet(enc.handle::Ptr{Cvoid},
        ratchet.handle::Ptr{Cvoid})::Cvoid
    enc
end

function set_passthrough!(enc::Encryptor, enabled::Bool)
    @ccall libdave.daveEncryptorSetPassthroughMode(enc.handle::Ptr{Cvoid},
        enabled::Bool)::Cvoid
    enc
end

has_key_ratchet(enc::Encryptor) =
    @ccall libdave.daveEncryptorHasKeyRatchet(enc.handle::Ptr{Cvoid})::Bool

is_passthrough(enc::Encryptor) =
    @ccall libdave.daveEncryptorIsPassthroughMode(enc.handle::Ptr{Cvoid})::Bool

protocol_version(enc::Encryptor) =
    @ccall libdave.daveEncryptorGetProtocolVersion(enc.handle::Ptr{Cvoid})::UInt16

function assign_ssrc!(enc::Encryptor, ssrc::Integer, codec::Codec)
    @ccall libdave.daveEncryptorAssignSsrcToCodec(enc.handle::Ptr{Cvoid},
        ssrc::UInt32, codec::Cint)::Cvoid
    enc
end

function encrypt(enc::Encryptor, media::MediaType, ssrc::Integer, frame::Vector{UInt8})
    capacity = @ccall libdave.daveEncryptorGetMaxCiphertextByteSize(enc.handle::Ptr{Cvoid},
        media::Cint, length(frame)::Csize_t)::Csize_t
    out = Vector{UInt8}(undef, capacity)
    written = Ref{Csize_t}(0)
    code = @ccall libdave.daveEncryptorEncrypt(enc.handle::Ptr{Cvoid}, media::Cint,
        ssrc::UInt32, frame::Ptr{UInt8}, length(frame)::Csize_t,
        out::Ptr{UInt8}, capacity::Csize_t, written::Ptr{Csize_t})::Cint
    code == 0 || throw(EncryptError(code))
    resize!(out, written[])
end

function stats(enc::Encryptor, media::MediaType)
    out = Ref{EncryptorStats}()
    @ccall libdave.daveEncryptorGetStats(enc.handle::Ptr{Cvoid}, media::Cint,
        out::Ptr{EncryptorStats})::Cvoid
    out[]
end

function transition_to_ratchet!(dec::Decryptor, ratchet::KeyRatchet)
    @ccall libdave.daveDecryptorTransitionToKeyRatchet(dec.handle::Ptr{Cvoid},
        ratchet.handle::Ptr{Cvoid})::Cvoid
    dec
end

function transition_to_passthrough!(dec::Decryptor, enabled::Bool)
    @ccall libdave.daveDecryptorTransitionToPassthroughMode(dec.handle::Ptr{Cvoid},
        enabled::Bool)::Cvoid
    dec
end

function decrypt(dec::Decryptor, media::MediaType, frame::Vector{UInt8})
    capacity = @ccall libdave.daveDecryptorGetMaxPlaintextByteSize(dec.handle::Ptr{Cvoid},
        media::Cint, length(frame)::Csize_t)::Csize_t
    out = Vector{UInt8}(undef, capacity)
    written = Ref{Csize_t}(0)
    code = @ccall libdave.daveDecryptorDecrypt(dec.handle::Ptr{Cvoid}, media::Cint,
        frame::Ptr{UInt8}, length(frame)::Csize_t,
        out::Ptr{UInt8}, capacity::Csize_t, written::Ptr{Csize_t})::Cint
    code == 0 || throw(DecryptError(code))
    resize!(out, written[])
end

function stats(dec::Decryptor, media::MediaType)
    out = Ref{DecryptorStats}()
    @ccall libdave.daveDecryptorGetStats(dec.handle::Ptr{Cvoid}, media::Cint,
        out::Ptr{DecryptorStats})::Cvoid
    out[]
end
