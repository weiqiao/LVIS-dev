__precompile__()

module Nets

export Net, Params, predict, predict_sensitivity

using Parameters: @with_kw
import ReverseDiff
import StochasticOptimization
using CoordinateTransformations: AffineMap, UniformScaling, transform_deriv
using MLDataPattern: batchview, shuffleobs

head(t::Tuple) = tuple(t[1])

function viewblocks{T <: NTuple}(data::AbstractArray, shapes::AbstractVector{T})
    starts = cumsum(vcat([1], prod.(shapes)))
    [reshape(view(data, starts[i]:(starts[i+1] - 1)), shapes[i]) for i in 1:length(shapes)]
end

struct Params{T, D <: AbstractVector{T}, M<:AbstractMatrix{T}, V<:AbstractVector{T}}
    data::D
    weights::Vector{M}
    biases::Vector{V}
    shapes::Vector{NTuple{2, Int}}

    Params{T, D, M, V}(data::D, weights::Vector{M}, biases::Vector{V}) where {T, D, M, V} =
        new{T, D, M, V}(data, weights, biases, size.(weights))
end

Params{T, D<:AbstractVector{T}, M<:AbstractMatrix{T}, V<:AbstractVector{T}}(
    data::D, weights::Vector{M}, biases::Vector{V}) =
    Params{T, D, M, V}(data, weights, biases)

function Params(shapes::Vector{<:NTuple}, data::AbstractVector)
    weights = viewblocks(data, shapes)
    biases = viewblocks(@view(data[(nweights(shapes) + 1):end]), head.(shapes))
    Params(data, weights, biases)
end

Params(widths::AbstractVector{<:Integer}, data::AbstractVector) =
    Params(collect(zip(widths[2:end], widths[1:end-1])), data)

ninputs(p::Params) = size(p.weights[1], 2)
noutputs(p::Params) = size(p.weights[end], 1)
shapes(p::Params) = p.shapes
nparams(widths::AbstractVector{<:Integer}) = nparams(collect(zip(widths[2:end], widths[1:end-1])))
nweights(shapes::AbstractVector{<:NTuple{2, Integer}}) = sum(prod, shapes)
nbiases(shapes::AbstractVector{<:NTuple{2, Integer}}) = sum(first, shapes)
nparams(shapes::AbstractVector{<:NTuple{2, Integer}}) = nweights(shapes) + nbiases(shapes)

Base.zeros(::Type{Params{T}}, widths::AbstractVector{<:Integer}) where {T} =
    Params(widths, zeros(T, nparams(widths))) 
Base.rand(::Type{Params{T}}, widths::AbstractVector{<:Integer}) where {T} =
    Params(widths, rand(T, nparams(widths)))
Base.randn(::Type{Params{T}}, widths::AbstractVector{<:Integer}) where {T} =
    Params(widths, randn(T, nparams(widths)))

struct Net{P <: Params, T <: AffineMap} <: Function
    params::P
    input_tform::T
    output_tform::T
end

Net(params::Params) = 
    Net(params,
        AffineMap(UniformScaling(1.0), zeros(ninputs(params))),
        AffineMap(UniformScaling(1.0), zeros(noutputs(params))))

nweights(net::Net) = nweights(net.params)
nbiases(net::Net) = nbiases(net.params)
nparams(net::Net) = nparams(net.params)
ninputs(net::Net) = ninputs(net.params)
noutput(net::Net) = noutputs(net.params)
params(net::Net) = net.params
(net::Net)(x) = predict(net, x)

Base.rand(net::Net) = rand(nparams(net))
Base.randn(net::Net) = randn(nparams(net))

Base.similar(net::Net, data::AbstractVector) =
    Net(Params(shapes(params(net)), data),
        net.input_tform,
        net.output_tform)

const relu_x = 1
@ReverseDiff.forward hat_relu(y) = begin
    if y >= relu_x
        -(0.1/relu_x) * (y - relu_x)
    elseif y >= 0
        -(1/relu_x) * y + 1
    elseif y >= -relu_x
        (1/relu_x) * y + 1
    else
        (0.1/relu_x) * (y + relu_x)
    end
end

@ReverseDiff.forward hat_relu_sensitivity(y, j) = begin
    if y >= relu_x
        -(0.1/relu_x) * j
    elseif y >= 0
        -(1/relu_x) * j
    elseif y >= -relu_x
        (1/relu_x) * j
    else
        (0.1/relu_x) * j
    end
end


@ReverseDiff.forward leaky_relu(y) = y >= 0 ? y : 0.1 * y
@ReverseDiff.forward leaky_relu_sensitivity(y, j) = y >= 0 ? j : 0.1 * j

@ReverseDiff.forward elu(y) = y >= 0 ? y : exp(y) - 1
@ReverseDiff.forward elu_sensitivity(y, j) = y >= 0 ? j : exp(y) * j

@ReverseDiff.forward gaussian(y) = exp(-y^2)
@ReverseDiff.forward gaussian_sensitivity(y, j) = -2 * y * exp(-y^2) * j

function predict(net::Net, x::AbstractVector)
    params = net.params
    y = params.weights[1] * net.input_tform(x) + params.biases[1]
    for i in 2:length(params.weights)
        y = gaussian.(y)
        y = params.weights[i] * y + params.biases[i]
    end
    net.output_tform(y)
end

function predict_sensitivity(net::Net, x::AbstractVector)
    params = net.params
    y = params.weights[1] * net.input_tform(x) + params.biases[1]
    J = params.weights[1] * transform_deriv(net.input_tform, x)
    for i in 2:length(params.weights)
        J = gaussian_sensitivity.(y, J)
        y = gaussian.(y)
        y = params.weights[i] * y + params.biases[i]
        J = params.weights[i] * J
    end
    hcat(net.output_tform(y), transform_deriv(net.output_tform, y) * J)
end


include("Explicit.jl")
include("optimization.jl")
include("scaling.jl")

end