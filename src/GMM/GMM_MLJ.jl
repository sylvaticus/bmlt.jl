"Part of [BetaML](https://github.com/sylvaticus/BetaML.jl). Licence is MIT."

# MLJ interface for clustering models

import MLJModelInterface       # It seems that having done this in the top module is not enought
const MMI = MLJModelInterface  # We need to repeat it here

export  GMMClusterer, BetaMLGMMRegressor

# ------------------------------------------------------------------------------
# Model Structure declarations..


mutable struct GMMClusterer <: MMI.Unsupervised
  K::Int64
  p₀::AbstractArray{Float64,1}
  mixtures::Symbol
  tol::Float64
  minimum_variance::Float64
  minimum_covariance::Float64
  initialisation_strategy::String
  rng::AbstractRNG
end
GMMClusterer(;
    K             = 3,
    p₀            = Float64[],
    mixtures      = :diag_gaussian,
    tol           = 10^(-6),
    minimum_variance   = 0.05,
    minimum_covariance = 0.0,
    initialisation_strategy  = "kmeans",
    rng           = Random.GLOBAL_RNG,
) = GMMClusterer(K,p₀,mixtures, tol, minimum_variance, minimum_covariance,initialisation_strategy,rng)

mutable struct BetaMLGMMRegressor <: MMI.Deterministic
    n_classes::Int64 
    initial_probmixtures::Vector{Float64}
    mixtures::Symbol
    tol::Float64
    minimum_variance::Float64
    minimum_covariance::Float64
    initialisation_strategy::String
    maximum_iterations::Int64 
    verbosity::Verbosity
    rng::AbstractRNG
end
BetaMLGMMRegressor(;
    n_classes      = 3,
    initial_probmixtures  = [],
    mixtures      = :diag_gaussian,
    tol           = 10^(-6),
    minimum_variance   = 0.05,
    minimum_covariance = 0.0,
    initialisation_strategy  = "kmeans",
    maximum_iterations       = typemax(Int64),
    verbosity     = STD,
    rng           = Random.GLOBAL_RNG
   ) = BetaMLGMMRegressor(n_classes,initial_probmixtures,mixtures,tol,minimum_variance,minimum_covariance,initialisation_strategy,maximum_iterations,verbosity,rng)


# ------------------------------------------------------------------------------
# Fit functions...

function MMI.fit(m::GMMClusterer, verbosity, X)
    # X is nothing, y is the data: https://alan-turing-institute.github.io/MLJ.jl/dev/adding_models_for_general_use/#Models-that-learn-a-probability-distribution-1
    x          = MMI.matrix(X) # convert table to matrix
    if m.mixtures == :diag_gaussian
        mixtures = [DiagonalGaussian() for i in 1:m.K]
    elseif m.mixtures == :full_gaussian
        mixtures = [FullGaussian() for i in 1:m.K]
    elseif m.mixtures == :spherical_gaussian
        mixtures = [SphericalGaussian() for i in 1:m.K]
    else
        error("Usupported mixture. Supported mixtures are either `:diag_gaussian`, `:full_gaussian` or `:spherical_gaussian`.")
    end
    res        = gmm(x,m.K,p₀=deepcopy(m.p₀),mixtures=mixtures, minimum_variance=m.minimum_variance, minimum_covariance=m.minimum_covariance,initialisation_strategy=m.initialisation_strategy,verbosity=NONE,rng=m.rng)
    fitResults = (pₖ=res.pₖ,mixtures=res.mixtures) # res.pₙₖ
    cache      = nothing
    report     = (res.ϵ,res.lL,res.BIC,res.AIC)
    return (fitResults, cache, report)
end
MMI.fitted_params(model::GMMClusterer, fitresult) = (weights=fitesult.pₖ, mixtures=fitresult.mixtures)

function MMI.fit(m::BetaMLGMMRegressor, verbosity, X, y)
    x  = MMI.matrix(X) # convert table to matrix
    
    if typeof(y) <: AbstractMatrix
        y  = MMI.matrix(y)
    end
    
    if m.mixtures == :diag_gaussian
        mixtures = [DiagonalGaussian() for i in 1:m.n_classes]
    elseif m.mixtures == :full_gaussian
        mixtures = [FullGaussian() for i in 1:m.n_classes]
    elseif m.mixtures == :spherical_gaussian
        mixtures = [SphericalGaussian() for i in 1:m.n_classes]
    else
        error("Usupported mixture. Supported mixtures are either `:diag_gaussian`, `:full_gaussian` or `:spherical_gaussian`.")
    end
    betamod = GMMRegressor2(
        n_classes     = m.n_classes,
        initial_probmixtures = m.initial_probmixtures,
        mixtures     = mixtures,
        tol          = m.tol,
        minimum_variance  = m.minimum_variance,
        initialisation_strategy = m.initialisation_strategy,
        maximum_iterations      = m.maximum_iterations,
        verbosity    = m.verbosity,
        rng          = m.rng
    )
    fit!(betamod,x,y)
    cache      = nothing
    return (betamod, cache, info(betamod))
end



# ------------------------------------------------------------------------------
# Predict functions...

function MMI.predict(m::GMMClusterer, fitResults, X)
    x               = MMI.matrix(X) # convert table to matrix
    (N,D)           = size(x)
    (pₖ,mixtures)   = (fitResults.pₖ, fitResults.mixtures)
    nCl             = length(pₖ)
    # Compute the probabilities that maximise the likelihood given existing mistures and a single iteration (i.e. doesn't update the mixtures)
    thisOut         = gmm(x,nCl,p₀=pₖ,mixtures=mixtures,tol=m.tol,verbosity=NONE,minimum_variance=m.minimum_variance,minimum_covariance=m.minimum_covariance,initialisation_strategy="given",maximum_iterations=1,rng=m.rng)
    classes         = CategoricalArray(1:nCl)
    predictions     = MMI.UnivariateFinite(classes, thisOut.pₙₖ)
    return predictions
end

function MMI.predict(m::BetaMLGMMRegressor, fitResults, X)
    x               = MMI.matrix(X) # convert table to matrix
    betamod         = fitResults
    return predict(betamod,x)
end



# ------------------------------------------------------------------------------
# Model metadata for registration in MLJ...

MMI.metadata_model(GMMClusterer,
    input_scitype    = MMI.Table(Union{MMI.Continuous,MMI.Missing}),
    output_scitype   = AbstractArray{<:MMI.Multiclass},       # scitype of the output of `transform`
    target_scitype   = AbstractArray{<:MMI.Multiclass},       # scitype of the output of `predict`
    #prediction_type  = :probabilistic,  # option not added to metadata_model function, need to do it separately
    supports_weights = false,                                 # does the model support sample weights?
    descr            = "A Expectation-Maximisation clustering algorithm with customisable mixtures, from the Beta Machine Learning Toolkit (BetaML).",
	load_path        = "BetaML.GMM.GMMClusterer"
)
MMI.prediction_type(::Type{<:GMMClusterer}) = :probabilistic

MMI.metadata_model(BetaMLGMMRegressor,
    input_scitype    = MMI.Table(Union{MMI.Missing, MMI.Infinite}),
    target_scitype   = AbstractVector{<: MMI.Continuous},           # for a supervised model, what target?
    supports_weights = false,                                       # does the model support sample weights?
    descr            = "A non-linear regressor derived from fitting the data on a probabilistic model (Gaussian Mixture Model). Relatively fast.",
	load_path        = "BetaML.GMM.BetaMLGMMRegressor"
    )

