include("circuits.jl")
using .SandpileCircuits, Random, Statistics, SHA, TOML, InteractiveUtils

@noinline function kernel!(dna::Val, inputs, outputs)
    a,b,c,d,e,f = inputs
    x,y,z = outputs
    @inbounds @simd for i in eachindex(a)
        x[i],y[i],z[i] = compiled_circuit(dna,a[i],b[i],c[i],d[i],e[i],f[i])
    end
    nothing
end

@noinline function trial!(dna, inputs, outputs, wanted)
    start = time_ns()
    kernel!(dna, inputs, outputs)
    seconds = (time_ns()-start)*1e-9
    outputs == wanted || error("compiled circuit output mismatch")
    seconds
end

function scalar_sum(values)
    result = zeros(UInt64,3)
    for bit in 0:63
        value = sum((values[i]>>bit)&1 for i in 1:5) + 2*((values[6]>>bit)&1)
        for p in 1:3
            result[p] |= ((value>>(p-1))&1)<<bit
        end
    end
    Tuple(result)
end

function main(args)
    length(args) <= 1 || error("usage: roulette.jl [output-prefix]")
    prefix = isempty(args) ? "build/roulette" : args[1]
    mkpath(dirname(prefix))
    rng = MersenneTwister(598)
    inputs = ntuple(_->rand(rng,UInt64,65536),6)
    outputs = ntuple(_->zeros(UInt64,65536),3)
    wanted = ntuple(_->zeros(UInt64,65536),3)
    baseline = seed_genome()
    for i in eachindex(inputs[1])
        values = ntuple(p->inputs[p][i],6)
        expected = interpret(baseline,values)
        i <= 64 && expected != scalar_sum(values) && error("scalar oracle mismatch")
        for p in 1:3
            wanted[p][i] = expected[p]
        end
    end

    seeds = catalogue()
    survivors = typeof(baseline)[]
    for attempt in 1:2000
        child = mutant(rng,rand(rng,seeds))
        valid(child) && push!(survivors,child)
    end
    choices = filter(child -> child != baseline, unique(survivors))
    length(choices) >= 7 || error("not enough distinct valid circuits")
    candidates = vcat([baseline], shuffle(rng, choices)[1:7])
    records = Dict{String,Any}[]
    for genome in candidates
        valid(genome) || error("invalid genome reached JIT")
        dna = Val(genome)
        start = time_ns()
        Base.invokelatest(kernel!,dna,inputs,outputs)
        first = (time_ns()-start)*1e-9
        outputs == wanted || error("first JIT invocation mismatch")
        samples = [trial!(dna,inputs,outputs,wanted) for _ in 1:7]
        allocated = @allocated kernel!(dna,inputs,outputs)
        allocated == 0 && outputs == wanted || error("allocation/output gate failed")
        id = bytes2hex(sha256(repr(genome)))[1:12]
        push!(records,Dict("id"=>id,"description"=>describe(genome),
            "nodes"=>[collect(n) for n in genome[1]],"outputs"=>collect(genome[2]),
            "first_invocation_seconds"=>first,"warm_seconds"=>samples,
            "warm_median_seconds"=>median(samples),"warm_allocated_bytes"=>allocated))
        println("PASS JIT candidate ",id," warm=",median(samples));flush(stdout)
    end
    best = argmin([r["warm_median_seconds"] for r in records])
    base_times,best_times = Float64[],Float64[]
    for repeat in 1:21
        order = isodd(repeat) ? [(1,base_times),(best,best_times)] : [(best,best_times),(1,base_times)]
        for (index,samples) in order
            push!(samples,trial!(Val(candidates[index]),inputs,outputs,wanted))
        end
    end
    dna = Val(candidates[best])
    signature = Tuple{typeof(dna),typeof(inputs),typeof(outputs)}
    open(prefix*".native.txt","w") do io
        code_native(io,kernel!,signature;debuginfo=:none,syntax=:intel)
    end
    open(prefix*".llvm.txt","w") do io
        code_llvm(io,kernel!,signature;debuginfo=:none)
    end
    report = Dict("status"=>"PASS","seed"=>598,"julia_version"=>string(VERSION),
        "cpu_name"=>Sys.CPU_NAME,"words_per_trial"=>length(inputs[1]),
        "mutation_attempts"=>2000,"accepted_mutants"=>length(survivors),
        "jit_candidates"=>length(candidates),"candidates"=>records,
        "winner_id"=>records[best]["id"],"baseline_confirmation_seconds"=>base_times,
        "winner_confirmation_seconds"=>best_times,
        "baseline_confirmation_median_seconds"=>median(base_times),
        "winner_confirmation_median_seconds"=>median(best_times),
        "scalar_random_word_checks"=>64,"truth_assignments_per_candidate"=>64,
        "scope"=>"Standalone circuit-word microbenchmark, not a full sandpile CLI speedup. First invocation includes JIT/dispatch/execution; warm times exclude validation. A tournament winner may be noise; inspect the separate alternating confirmation.")
    open(prefix*".toml","w") do io
        TOML.print(io,report)
    end
end

if abspath(PROGRAM_FILE) == abspath(@__FILE__)
    main(ARGS)
end
