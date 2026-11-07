using TOML, SHA, Random, InteractiveUtils
include("circuits.jl")
using .SandpileCircuits: TRUTH_INPUTS, TRUTH_OUTPUTS

function lut_expression(imm, a, b, c)
    pieces=Any[]
    for j in 0:7
        iszero((imm>>j)&1) && continue
        aa=j&4!=0 ? a : :(~$a)
        bb=j&2!=0 ? b : :(~$b)
        cc=j&1!=0 ? c : :(~$c)
        push!(pieces,:( $aa & $bb & $cc ))
    end
    isempty(pieces) && return :(zero(UInt64))
    foldl((x,y)->:($x | $y),pieces)
end

@generated function compiled_lut(::Val{Net}, a::UInt64, b::UInt64, c::UInt64,
                                 d::UInt64, e::UInt64, f::UInt64) where Net
    nodes,outputs=Net;symbols=[:a,:b,:c,:d,:e,:f]
    body=Any[Expr(:meta,:inline)]
    for (x,y,z,imm) in nodes
        0<=imm<=255 && all(0<=i<length(symbols) for i in (x,y,z)) || error("invalid LUT DAG")
        gate=gensym(:lut)
        push!(body,:($gate=$(lut_expression(imm,symbols[x+1],symbols[y+1],symbols[z+1]))))
        push!(symbols,gate)
    end
    length(outputs)==3 && all(0<=i<length(symbols) for i in outputs) || error("invalid outputs")
    push!(body,Expr(:tuple,(symbols[i+1] for i in outputs)...))
    Expr(:block,body...)
end

function scalar_sum(inputs)
    outputs=zeros(UInt64,3)
    for bit in 0:63
        sumvalue=sum((inputs[i]>>bit)&1 for i in 1:5)+2*((inputs[6]>>bit)&1)
        for j in 1:3;outputs[j] |= ((sumvalue>>(j-1))&1)<<bit;end
    end
    Tuple(outputs)
end

function main(args)
    length(args)>=2 || error("output-prefix witness.toml...")
    prefix=args[1];rng=MersenneTwister(598);records=Dict{String,Any}[]
    for (index,path) in enumerate(args[2:end])
        data=TOML.parsefile(path)
        net=(Tuple(Tuple(Int.(node)) for node in data["nodes"]),Tuple(Int.(data["outputs"])))
        dna=Val(net)
        compiled_lut(dna,TRUTH_INPUTS...)==TRUTH_OUTPUTS || error("truth mismatch")
        for trial in 1:1024
            inputs=ntuple(_->rand(rng,UInt64),6)
            compiled_lut(dna,inputs...)==scalar_sum(inputs) || error("random-word mismatch")
        end
        depths=zeros(Int,6)
        for (a,b,c,_) in net[1];push!(depths,1+max(depths[a+1],depths[b+1],depths[c+1]));end
        signature=Tuple{typeof(dna),Vararg{UInt64,6}}
        for (kind,emit) in [("llvm",code_llvm),("native",code_native)]
            open(prefix*"-$(index)-$(kind).txt","w") do io
                emit(io,compiled_lut,signature;debuginfo=:none)
            end
        end
        push!(records,Dict("witness"=>path,"sha256"=>bytes2hex(sha256(read(path))),
            "nodes"=>length(net[1]),"output_depths"=>[depths[i+1] for i in net[2]],
            "truth_assignments"=>64,"random_word_cases"=>1024,"status"=>"PASS"))
        println("PASS solver to Julia ",path)
    end
    open(prefix*".toml","w") do io
        TOML.print(io,Dict("status"=>"PASS","julia_version"=>string(VERSION),"cases"=>records,
            "scope"=>"Exact arbitrary-LUT JIT round-trip; no performance or whole-sandpile claim."))
    end
end
if abspath(PROGRAM_FILE)==abspath(@__FILE__)
    main(ARGS)
end
