include("circuits.jl")
using .SandpileCircuits, Random, TOML

function geometry(n)
    r = n ÷ 2
    [j <= max(i, n-1-i) && (i-r)^2 + (j-r)^2 <= r^2
     for i in 0:n-1 for j in 0:n-1]
end

function pack(values)
    result = BigInt(0)
    for (k, value) in enumerate(values)
        value && (result |= BigInt(1) << (k-1))
    end
    result
end

function giant_stabilize(initial, n, active)
    mask = pack(active)
    limit = (BigInt(1) << n^2) - 1
    left = pack([j == 0 for i in 0:n-1 for j in 0:n-1])
    right = left << (n-1)
    @assert all(0 <= initial[k] <= 7 for k in eachindex(initial) if active[k])
    planes = [pack([active[k] && !iszero((initial[k] >> p) & 1)
                    for k in eachindex(initial)]) for p in 0:2]
    receipts = BigInt[]
    dna = Val(seed_genome())
    rounds = 0
    while !iszero(planes[3])
        rounds += 1
        rounds <= 1_000_000 || error("round limit exceeded")
        q = planes[3]
        incoming = (q >> n, (q << n) & limit,
                    (q & ~left) >> 1, ((q & ~right) << 1) & limit)
        lo, mid, hi = compiled_circuit(dna, incoming..., planes[1], planes[2])
        planes = [lo & mask, mid & mask, hi & mask]
        for grains in incoming
            carry = grains & ~mask
            p = 1
            while !iszero(carry)
                p > length(receipts) && push!(receipts, BigInt(0))
                old = receipts[p]
                receipts[p] = xor(old, carry)
                carry &= old
                p += 1
            end
        end
    end
    result = copy(initial)
    for k in eachindex(result)
        if active[k]
            result[k] = sum(Int((planes[p] >> (k-1)) & 1) << (p-1) for p in 1:3)
        else
            for p in eachindex(receipts)
                result[k] += Int((receipts[p] >> (k-1)) & 1) << (p-1)
            end
        end
    end
    result, rounds
end

function scalar_stabilize(initial, n, active)
    heights = copy(initial)
    changed = true
    while changed
        changed = false
        for i in 0:n-1, j in 0:n-1
            k = i*n+j+1
            active[k] && heights[k] >= 4 || continue
            q = heights[k] ÷ 4
            heights[k] -= 4q
            i > 0 && (heights[k-n] += q)
            i+1 < n && (heights[k+n] += q)
            j > 0 && (heights[k-1] += q)
            j+1 < n && (heights[k+1] += q)
            changed = true
        end
    end
    heights
end

function main()
    rng = MersenneTwister(598)
    records = Dict{String,Any}[]
    for n in (1, 2, 3, 7, 8, 15, 16, 31, 32, 33)
        active = geometry(n)
        initial = fill(6, n^2)
        start = time_ns()
        first, rounds1 = giant_stabilize(initial, n, active)
        @assert first == scalar_stabilize(initial, n, active)
        second_input = 6 .- first
        second, rounds2 = giant_stabilize(second_input, n, active)
        @assert second == scalar_stabilize(second_input, n, active)
        for trial in 1:4
            random_input = rand(rng, 0:7, n^2)
            random_input[.!active] .-= 20
            got, _ = giant_stabilize(random_input, n, active)
            @assert got == scalar_stabilize(random_input, n, active)
        end
        push!(records, Dict("n"=>n, "bits_per_plane"=>n^2,
            "identity_phase_rounds"=>[rounds1, rounds2],
            "full_grid_comparisons"=>6, "status"=>"PASS",
            "validation_wall_seconds"=>(time_ns()-start)*1e-9))
    end
    TOML.print(stdout, Dict("status"=>"PASS", "seed"=>598,
        "julia_version"=>string(VERSION), "cases"=>records,
        "scope"=>"Small-grid BigInt exploration; both identity phases and signed sinks match an independent scalar schedule. Times include validation/JIT, not CLI benchmarks."))
end

if abspath(PROGRAM_FILE) == abspath(@__FILE__)
    main()
end
