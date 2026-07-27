using Test
using LibDave

include("external_sender.jl")

set_log_handler!((severity, file, line, message) -> nothing)

const GROUP_ID = 1234567890
const USER_A = "1234123412341234"
const USER_B = "5678567856785678"

function establish_group()
    sender = ExternalSender(GROUP_ID)
    a = Session()
    b = Session()

    external = marshalled_external_sender(sender)
    set_external_sender!(a, external)
    set_external_sender!(b, external)
    init!(a, 1, GROUP_ID, USER_A)
    init!(b, 1, GROUP_ID, USER_B)

    proposal = propose_add(sender, 0, key_package(b))
    recognized = [USER_A, USER_B]
    commit_welcome = process_proposals(a, proposal, recognized)
    @test commit_welcome !== nothing

    commit, welcome = split_commit_welcome(sender, commit_welcome)
    commit_result = process_commit(a, commit)
    welcome_roster = process_welcome(b, welcome, recognized)

    sender, a, b, commit_result, welcome_roster
end

@testset "LibDave" begin
    @testset "version" begin
        @test max_protocol_version() >= 1
    end

    @testset "passthrough roundtrip" begin
        frame = rand(UInt8, 480)

        enc = Encryptor()
        assign_ssrc!(enc, 0, LibDave.Opus)
        set_passthrough!(enc, true)
        @test is_passthrough(enc)
        @test !has_key_ratchet(enc)
        encrypted = encrypt(enc, LibDave.Audio, 0, frame)
        @test encrypted == frame

        dec = Decryptor()
        transition_to_passthrough!(dec, true)
        @test decrypt(dec, LibDave.Audio, encrypted) == frame
    end

    @testset "handshake" begin
        _, a, b, commit_result, welcome_roster = establish_group()

        @test !commit_result.failed
        @test !commit_result.ignored
        @test welcome_roster !== nothing

        expected = Set([parse(UInt64, USER_A), parse(UInt64, USER_B)])
        @test Set(keys(commit_result.roster)) == expected
        @test Set(keys(welcome_roster)) == expected
        @test all(!isempty, values(commit_result.roster))
        @test all(!isempty, values(welcome_roster))

        auth_a = last_epoch_authenticator(a)
        auth_b = last_epoch_authenticator(b)
        @test !isempty(auth_a)
        @test auth_a == auth_b

        @test pairwise_fingerprint(a, USER_B) == pairwise_fingerprint(b, USER_A)
    end

    @testset "media roundtrip" begin
        _, a, b, _, _ = establish_group()

        ratchet_a = key_ratchet(a, USER_A)
        ratchet_a_at_b = key_ratchet(b, USER_A)
        @test ratchet_a !== nothing
        @test ratchet_a_at_b !== nothing

        enc = Encryptor()
        assign_ssrc!(enc, 0, LibDave.Opus)
        set_passthrough!(enc, false)
        set_key_ratchet!(enc, ratchet_a)
        @test has_key_ratchet(enc)

        dec = Decryptor()
        transition_to_passthrough!(dec, false)
        transition_to_ratchet!(dec, ratchet_a_at_b)

        frame = rand(UInt8, 160)
        encrypted = encrypt(enc, LibDave.Audio, 0, frame)
        @test length(encrypted) > length(frame)
        @test encrypted[1:length(frame)] != frame
        @test decrypt(dec, LibDave.Audio, encrypted) == frame

        enc_stats = stats(enc, LibDave.Audio)
        @test enc_stats.successes == 1
        @test enc_stats.failures == 0
        dec_stats = stats(dec, LibDave.Audio)
        @test dec_stats.successes == 1
        @test dec_stats.failures == 0

        wrong = Decryptor()
        transition_to_passthrough!(wrong, false)
        wrong_ratchet = key_ratchet(b, USER_B)
        @test wrong_ratchet !== nothing
        transition_to_ratchet!(wrong, wrong_ratchet)
        @test_throws DecryptError decrypt(wrong, LibDave.Audio, encrypted)
    end

    @testset "video codec roundtrip" begin
        _, a, b, _, _ = establish_group()

        enc = Encryptor()
        assign_ssrc!(enc, 7, LibDave.H264)
        set_key_ratchet!(enc, key_ratchet(a, USER_A))

        dec = Decryptor()
        transition_to_ratchet!(dec, key_ratchet(b, USER_A))

        # fake NAL unit so the codec aware frame processor has something to parse
        frame = vcat(UInt8[0x00, 0x00, 0x00, 0x01, 0x65], rand(UInt8, 1200))
        encrypted = encrypt(enc, LibDave.Video, 7, frame)
        @test decrypt(dec, LibDave.Video, encrypted) == frame
    end

    @testset "session lifecycle" begin
        s = Session()
        init!(s, 1, GROUP_ID, USER_A)
        @test protocol_version(s) == 1
        @test !isempty(key_package(s))
        reset!(s)

        failures = String[]
        cb = Session(on_failure=(source, reason) -> push!(failures, source))
        init!(cb, 1, GROUP_ID, USER_A)
        garbage = process_commit(cb, rand(UInt8, 32))
        @test garbage.failed || garbage.ignored || !isempty(failures)

        for _ in 1:50
            init!(Session(), 1, GROUP_ID, USER_A)
        end
        GC.gc()
        GC.gc()
        @test true
    end
end
