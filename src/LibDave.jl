module LibDave

using libdave_jll: libdave

export Session, KeyRatchet, Encryptor, Decryptor, CommitResult,
       Codec, MediaType, EncryptError, DecryptError,
       EncryptorStats, DecryptorStats,
       max_protocol_version, init!, reset!,
       protocol_version, set_protocol_version!,
       set_external_sender!, key_package, last_epoch_authenticator,
       process_proposals, process_commit, process_welcome,
       key_ratchet, pairwise_fingerprint,
       set_key_ratchet!, set_passthrough!, has_key_ratchet, is_passthrough,
       assign_ssrc!, encrypt, decrypt,
       transition_to_ratchet!, transition_to_passthrough!,
       stats, set_log_handler!

@enum Codec::Cint begin
    CodecUnknown = 0
    Opus = 1
    VP8 = 2
    VP9 = 3
    H264 = 4
    H265 = 5
    AV1 = 6
end

@enum MediaType::Cint begin
    Audio = 0
    Video = 1
end

struct EncryptError <: Exception
    code::Cint
end

struct DecryptError <: Exception
    code::Cint
end

const encrypt_failures = Dict{Cint,String}(
    1 => "encryption failure",
    2 => "missing key ratchet",
    3 => "missing cryptor",
    4 => "too many attempts",
)

const decrypt_failures = Dict{Cint,String}(
    1 => "decryption failure",
    2 => "missing key ratchet",
    3 => "invalid nonce",
    4 => "missing cryptor",
)

Base.showerror(io::IO, e::EncryptError) =
    print(io, "EncryptError: ", get(encrypt_failures, e.code, "code $(e.code)"))
Base.showerror(io::IO, e::DecryptError) =
    print(io, "DecryptError: ", get(decrypt_failures, e.code, "code $(e.code)"))

max_protocol_version() = @ccall libdave.daveMaxSupportedProtocolVersion()::UInt16

function take_bytes(data::Ref{Ptr{UInt8}}, len::Ref{Csize_t})
    p = data[]
    n = Int(len[])
    (p == C_NULL || n == 0) && return UInt8[]
    bytes = copy(unsafe_wrap(Array, p, n))
    @ccall libdave.daveFree(p::Ptr{Cvoid})::Cvoid
    bytes
end

function log_trampoline(severity::Cint, file::Cstring, line::Cint, message::Cstring)
    handler = log_handler[]
    if handler !== nothing
        handler(Int(severity), unsafe_string(file), Int(line), unsafe_string(message))
    end
    nothing
end

const log_handler = Ref{Union{Nothing,Function}}(nothing)

function set_log_handler!(handler)
    log_handler[] = handler
    cb = handler === nothing ? Ptr{Cvoid}(C_NULL) :
        @cfunction(log_trampoline, Cvoid, (Cint, Cstring, Cint, Cstring))
    @ccall libdave.daveSetLogSinkCallback(cb::Ptr{Cvoid})::Cvoid
    nothing
end

include("session.jl")
include("frames.jl")

end
