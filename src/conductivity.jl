using ApproxTools
using PyPlot
using PyCall;
@pyimport matplotlib.colors as mplcolors;
using DataStructures

"""
    rationalfactor(β,η)

One-dimensional function with simple poles at all the singularities
of the Fermi-Dirac function in the Bernstein ellipse through `1+η`.
"""
function rationalfactor(β,η)
    T = promote_type(typeof.((β,η))...)
    return rationalfactor(convert(real(T),β),convert(T,η))
end
function rationalfactor(β::T,η::Union{T,Complex{T}}) where {T <: Real}
    b = semiminor(1+η)
    k = nfermipoles(b,β)
    return x->(x^2+b^2)^k/mapreduce(b->(x^2+b^2),*,one(T),π/β*(1:2:2k-1))
end

"""
   approx_conductivity(β,η, npoly, nrat)

Approximate the conductivity function using the ansatz `f(x1,x2) ≈ p(x1,x2) q(x1) q(x2)`
where `q` is the polynomial interpolant to `rationalfactor(β,η)` and `p` is the
polynomial interpolant of the remainder.
"""
function approx_conductivity(β::Number,η::Number, npoly::Integer,nrat::Integer)
    T = promote_type(typeof.((β,η))...)
    return approx_conductivity(convert(real(T),β),convert(T,η), npoly,nrat)
end
function approx_conductivity(
    β::T,
    η::Union{T,Complex{T}},
    npoly::Integer,
    nrat::Integer
) where {T <: Real}
    q = interpolate(rationalfactor(β,η), Chebyshev(nrat))
    p = interpolate(
        Semiseparated((x1,x2)->fermidiff(x1,x2,β)/(x1-x2+η), (x->1/q(x),x->1/q(x))),
        Chebyshev.((npoly,npoly))
    )
    return Semiseparated(p,(q,q))
end


mutable struct Stateful{Iter,State}
    iter::Iter
    state::State
end
"""
    Stateful(iter)

A stateful wrapper around the iterable `iter`.

# Example
```
julia> a = Stateful(1:5);

julia> collect(Base.Iterators.take(a,2))
2-element Array{Int64,1}:
 1
 2

julia> collect(Base.Iterators.take(a,2))
2-element Array{Int64,1}:
 3
 4
```
"""
Stateful(iter) = Stateful(iter,start(iter))
Base.eltype(::Type{Stateful{Iter,State}}) where {Iter,State} = eltype(Iter)
Base.iteratorsize(::Type{<:Stateful}) = Base.SizeUnknown()
Base.start(s::Stateful) = ()
Base.next(s::Stateful, _) = next(s),()
Base.next(s::Stateful) = ((_,s.state) = next(s.iter,s.state))[1]
Base.done(s::Stateful, _) = done(s)
Base.done(s::Stateful) = done(s.iter,s.state)


"""
    eval_sparse(f, H, Da, Db, bwidth)

Evaluate the conductivity formula based on the approximation
`f(x1,x2) ≈ p(x1,x2) q(x1) q(x2)` where `p` and `q` are polynomials
in Chebyshev basis.

Terms further than `bwidth` away from the diagonal are ignored in the
expansion of `p`.
"""
function eval_sparse(f::Semiseparated,H,Da,Db,bwidth)
    N = size(H,1)
    p = f.core::LinearCombination
    q = f.factors[1]
    b = p.basis[1]::Chebyshev
    c = p.coefficients
    n = size(p.coefficients,1)

    @assert size(H) == size(Da) == size(Db) == (N,N)
    @assert f.factors == (q,q)
    @assert p.basis == (b,b)

    v1 = zeros(N); v1[1] = 1
    v1 = q(H,v1)
    v2 = full(Db[:,1])
    v2 = q(H,v2)

    Tv1_iter = Stateful(b(H,v1))
    Tv1_cache = CircularDeque{typeof(v1)}(min(n,2*bwidth+1))
    for Tv1k in Base.Iterators.take(Tv1_iter, bwidth)
        push!(Tv1_cache, Tv1k)
    end

    σ = zero(complex(eltype(H)))
    for (i2,Tv2) in enumerate(b(H,v2))
        if i2 > bwidth+1
            shift!(Tv1_cache)
        end
        if i2 <= n - bwidth
            push!(Tv1_cache, next(Tv1_iter))
        end

        for (i1,Tv1) in enumerate(Tv1_cache)
            σ += c[max(i2-bwidth,1)+i1-1,i2]*(Tv1'*Da*Tv2)
        end
    end
    return σ/N
end

"""
    eval_diag(f,H,Da,Db)

Evaluate the conductivity formula via diagonalising the Hamiltonian.
"""
function eval_diag(f,H,Da,Db)
    N = size(H,1)
    E,Ψ = eig(full(H))
    D̃a = Ψ'*Da*Ψ
    D̃b = Ψ'*Db[:,1]
    F = grideval(f,(E,E))
    M = Diagonal(Ψ[1,:])*D̃a*Diagonal(D̃b)
    return dot(vec(M),vec(F))/N
end


function plot_convergence()
    β = 100
    η = 1/β*im

    f = (x1,x2)->fermidiff(x1,x2,β)/(x1-x2+η)

    n = 1:50:2000
    @time err = [begin
        p = approx_conductivity(β,η, n,n)
        fnorm(f,p)/fnorm(f)
    end
    for n = n]

    fig = figure(figsize=(6,4.5))
    try
        semilogy(n, err, label="relative error");
        semilogy(n, abs(ijouk(η/2)).^(-2n), "k--", label="theoretical convergence rate")
        xlabel("polynomial degree")
        legend(loc="best")

        savefig("convergence.png")
        println("Plot saved at $(pwd())/convergence.png")
    finally
        close(fig)
    end
end

function plot_coeffs()
    β = 100
    η = 1/β*im
    n = 2001

    @time p = approx_conductivity(β,η,n,n)
    C = abs.(coeffs(p.core))
    C ./= maximum(C)

    fig = figure(figsize=(6,4.5))
    try
        imshow(C, norm=mplcolors.LogNorm(), vmin=1e-14)
        colorbar()
        savefig("coefficients.png")
        println("Plot saved at $(pwd())/coefficients.png")
    finally
        close(fig)
    end
end
