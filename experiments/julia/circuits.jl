module SandpileCircuits
using Random
export compiled_circuit, interpret, valid, seed_genome, mutant, catalogue, describe,
       TRUTH_INPUTS, TRUTH_OUTPUTS
function truth_tables()
    inputs=ntuple(_->zero(UInt64),6);outputs=(zero(UInt64),zero(UInt64),zero(UInt64))
    for bits in 0:63
        inputs=ntuple(i->inputs[i]|(UInt64((bits>>>(i-1))&1)<<bits),6)
        value=sum((bits>>>i)&1 for i in 0:4)+2*((bits>>>5)&1)
        outputs=ntuple(i->outputs[i]|(UInt64((value>>>(i-1))&1)<<bits),3)
    end
    inputs,outputs
end
const TRUTH_INPUTS,TRUTH_OUTPUTS=truth_tables()

@inline function operation(op,a,b,c)
    op==1 && return xor(xor(a,b),c)
    op==2 && return (a&b)|(a&c)|(b&c)
    op==3 && return (a&b)|(xor(a,b)&c)
    op==4 && return (a&b)|((a|b)&c)
    op==5 && return xor(a&b,xor(a,b)&c)
    op==6 && return xor(xor(a,c)&xor(b,c),c)
    op==7 && return ~a
    op==8 && return a&b&c
    op==9 && return a|b|c
    op==10 && return (a&b)|(~a&c)
    error("unknown circuit opcode")
end
function structural(genome)
    nodes,outputs=genome
    length(nodes)==6 && length(outputs)==3 || return false
    for (i,node) in enumerate(nodes)
        1<=node[1]<=10 && all(1<=p<i+6 for p in node[2:4]) || return false
    end
    all(1<=p<=12 for p in outputs)
end
function interpret(genome,inputs)
    structural(genome) || error("malformed circuit")
    values=Vector{UInt64}(undef,12)
    for i in 1:6;values[i]=inputs[i];end
    for (i,(op,a,b,c)) in enumerate(genome[1])
        values[i+6]=operation(op,values[a],values[b],values[c])
    end
    ntuple(i->values[genome[2][i]],3)
end
valid(genome)=structural(genome) && interpret(genome,TRUTH_INPUTS)==TRUTH_OUTPUTS

function expression(op,a,b,c)
    op==1 && return :(xor(xor($a,$b),$c))
    op==2 && return :(($a&$b)|($a&$c)|($b&$c))
    op==3 && return :(($a&$b)|(xor($a,$b)&$c))
    op==4 && return :(($a&$b)|(($a|$b)&$c))
    op==5 && return :(xor($a&$b,xor($a,$b)&$c))
    op==6 && return :(xor(xor($a,$c)&xor($b,$c),$c))
    op==7 && return :(~$a)
    op==8 && return :($a&$b&$c)
    op==9 && return :($a|$b|$c)
    op==10 && return :(($a&$b)|(~$a&$c))
    error("unknown circuit opcode")
end
@generated function compiled_circuit(::Val{Genome},a::T,b::T,c::T,d::T,e::T,f::T) where {Genome,T}
    structural(Genome) || error("malformed circuit genotype")
    symbols=[:a,:b,:c,:d,:e,:f];body=Any[Expr(:meta,:inline)]
    for (op,x,y,z) in Genome[1]
        symbol=gensym(:gate)
        push!(body,:($symbol=$(expression(op,symbols[x],symbols[y],symbols[z]))))
        push!(symbols,symbol)
    end
    push!(body,Expr(:tuple,(symbols[i] for i in Genome[2])...))
    Expr(:block,body...)
end

function seed_genome(triple=(1,2,3),forms=(2,2,2))
    length(unique(triple))==3 && all(1<=p<=5 for p in triple) || error("invalid first adder")
    rest=Tuple(i for i in 1:5 if !(i in triple))
    nodes=((1,triple...),(forms[1],triple...),(1,7,rest...),
           (forms[2],7,rest...),(1,8,10,6),(forms[3],8,10,6))
    (nodes,(9,11,12))
end
function catalogue()
    [seed_genome((a,b,c),(x,y,z)) for a in 1:3 for b in a+1:4 for c in b+1:5 for x in 2:6 for y in 2:6 for z in 2:6]
end
function mutant(rng,genome)
    nodes=collect(genome[1]);index=rand(rng,1:6);node=collect(nodes[index])
    field=rand(rng,1:4);node[field]=field==1 ? rand(rng,1:10) : rand(rng,1:index+5)
    nodes[index]=Tuple(node)
    (Tuple(nodes),genome[2])
end
function describe(genome)
    names=("xor3","majority-and","majority-xor-or","majority-or","majority-xor","majority-inverted","not","and3","or3","select")
    join(["$(i+6)=$(names[node[1]])($(node[2]),$(node[3]),$(node[4]))" for (i,node) in enumerate(genome[1])],"; ")*"; outputs=$(genome[2])"
end
end
