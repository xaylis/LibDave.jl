# LibDave.jl

Julia bindings for [libdave](https://github.com/discord/libdave), Discord's implementation of the DAVE protocol (end to end encryption for audio and video). The native library is built with BinaryBuilder and wrapped through its C API.

## Layout

- `src/` and `test/` are the LibDave package.
- `builder/build_tarballs.jl` builds `libdave_jll`: mlspp, nlohmann_json and libdave itself, plus a `libdave_testutils` library that fakes the voice gateway's MLS external sender for testing. It is destined for Yggdrasil, at which point `libdave_jll` installs from the registry like any other package.

## Building the JLL

Supported platforms: Linux x86_64 and aarch64, macOS x86_64 and aarch64, Windows x86_64.

```
BINARYBUILDER_AUTOMATIC_APPLE=true julia --project=@binarybuilder builder/build_tarballs.jl \
    x86_64-linux-gnu,aarch64-linux-gnu,x86_64-apple-darwin,aarch64-apple-darwin,x86_64-w64-mingw32 \
    --deploy=local
```

This deploys `libdave_jll` to `~/.julia/dev/libdave_jll`. Then:

```
julia --project -e 'using Pkg; Pkg.develop(path=joinpath(homedir(), ".julia/dev/libdave_jll")); Pkg.test()'
```

## Usage

The session maps onto the DAVE opcodes of the voice gateway. Everything binary that arrives from the gateway goes into the session, everything the session returns goes back out.

```julia
using LibDave

session = Session(on_failure=(source, reason) -> @warn "MLS failure" source reason)

# voice gateway opcode 4 (select protocol ack) tells you the protocol version
init!(session, 1, guild_id, string(bot_user_id))

# opcode 25: external sender package for the call
set_external_sender!(session, external_sender_bytes)

# send your key package to the gateway (opcode 26)
package = key_package(session)

# opcode 27: proposals to append or revoke
commit_welcome = process_proposals(session, proposal_bytes, recognized_user_ids)
# if not nothing, send it back to the gateway (opcode 28)

# opcode 29: a commit accepted by the gateway
result = process_commit(session, commit_bytes)

# opcode 30: welcome when you join an established group
roster = process_welcome(session, welcome_bytes, recognized_user_ids)
```

Once the group is established, media flows through per sender key ratchets:

```julia
enc = Encryptor()
assign_ssrc!(enc, ssrc, LibDave.Opus)
set_key_ratchet!(enc, key_ratchet(session, string(bot_user_id)))
ciphertext = encrypt(enc, LibDave.Audio, ssrc, opus_frame)

dec = Decryptor()
transition_to_ratchet!(dec, key_ratchet(session, string(other_user_id)))
plaintext = decrypt(dec, LibDave.Audio, encrypted_frame)
```

Out of band identity verification:

```julia
pairwise_fingerprint(session, string(other_user_id))
```

Encryptors and decryptors start out rejecting everything. Use `set_passthrough!` and `transition_to_passthrough!` while the call has not yet upgraded to DAVE, and flip them off once it has.

## License

The bindings are MIT. libdave and mlspp are MIT licensed by Discord and Cisco.
