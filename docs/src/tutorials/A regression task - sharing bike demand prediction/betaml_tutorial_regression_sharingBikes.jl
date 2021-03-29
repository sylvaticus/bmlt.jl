
# # A regression task: the prediction of  bike  sharing demand
# The task is to estimate the influence of several variables (like the weather, the season, the day of the week..) on the demand of shared bicycles, so that the authority in charge of the service can organise the service in the best way.
#
# Data origin:
# - original full dataset (by hour, not used here): [https://archive.ics.uci.edu/ml/datasets/Bike+Sharing+Dataset](https://archive.ics.uci.edu/ml/datasets/Bike+Sharing+Dataset)
# - simplified dataset (by day, with some simple scaling): [https://www.hds.utc.fr/~tdenoeux/dokuwiki/en/aec]( https://www.hds.utc.fr/~tdenoeux/dokuwiki/en/aec)
# - description: [https://www.hds.utc.fr/~tdenoeux/dokuwiki/_media/en/exam_2019_ace_.pdf](https://www.hds.utc.fr/~tdenoeux/dokuwiki/_media/en/exam_2019_ace_.pdf)
# - data: [https://www.hds.utc.fr/~tdenoeux/dokuwiki/_media/en/bike_sharing_day.csv.zip](https://www.hds.utc.fr/~tdenoeux/dokuwiki/_media/en/bike_sharing_day.csv.zip)

# Note that even if we are estimating a time serie, we are not using here a recurrent neural network as we assume the temporal dependence to be negligible (i.e. $Y_t = f(X_t)$ alone).

# ## Library and data loading

# We first load all the packages we are going to use
using  LinearAlgebra, Random, Statistics, DataFrames, CSV, Plots, Pipe, BenchmarkTools, BetaML
import Distributions: Uniform
import DecisionTree, Flux ## For comparisions
using  Test     #src


# Here we load the data from a csv provided by the BataML package
baseDir = joinpath(dirname(pathof(BetaML)),"..","docs","src","tutorials","A regression task - sharing bike demand prediction")
data    = CSV.File(joinpath(baseDir,"data","bike_sharing_day.csv"),delim=',') |> DataFrame
describe(data)

# The variable we want to learn to predict is `cnt`, the total demand of bikes for a given day. Even if it is indeed an integer, we treat it as a continuous variable, so each single prediction will be a scalar $Y \in \mathbb{R}$.
plot(data.cnt, title="Daily bike sharing rents (2Y)", label=nothing)

# ## Decision Trees

# We start our regression task with Decision Trees

# ### Data preparation
# The first step is to prepare the data for the analysis. This indeed depends already on the model we want to employ, as some models "accept" everything as input, no matter if the data is numerical or categorical, if it has missing values or not... while other models are instead much more exigents, and require more work to "clean up" our dataset.
# Here we start using  Decision Tree and Random Forest models that belong to the first group, so the only things we have to do is to select the variables in input (the "feature matrix", we wil lindicate it with "X") and those representing our output (the values we want to learn to predict, we call them "y"):

x    = convert(Matrix,hcat(data[:,[:instant,:season,:yr,:mnth,:holiday,:weekday,:workingday,:weathersit,:temp,:atemp,:hum,:windspeed]]))
y    = data[:,16];

# We can now split the dataset between the data we will use for training the algorithm (`xtrain`/`ytrain`), those for selecting the hyperparameters (`xval`/`yval`) and finally those for testing the quality of the algoritm with the optimal hyperparameters (`xtest`/`ytest`). We use the `partition` function specifying the share we want to use for these three different subsets, here 75%, 12.5% and 12.5 respectively. As our data represents indeed a time serie, we want our model to be able to predict _future_ demand of bike sharing from _past_, observed rented bikes, so we do not shuffle the datasets as it would be the default.

((xtrain,xval,xtest),(ytrain,yval,ytest)) = partition([x,y],[0.75,0.125,1-0.75-0.125],shuffle=false)
(ntrain, nval, ntest) = size.([ytrain,yval,ytest],1)

# We can now "tune" our model so-called hyperparameters, i.e. choose the best exogenous parameters of our algorithm, where "best" refers to some minimisation of a "loss" function between the true and the predicted value. To make the comparision we use a specific "validation" subset of data (`xval` and `yval`).

# BetaML doesn't have a dedicated function for hyperparameters optimisation, but it is easy to write some custom julia code, at least for a simple grid-based "search". Indeed one of the main reasons that a dedicated function exists in other Machine Learning libraries is that loops in other languages are slow, but this is not a problem in julia, so we can retain the flexibility to write the kind of hyperparameter tuning that best fits our needs.

# Below is an example of a possible such function. Note there are more "elegant" ways to code it, but this one does the job. We will see the various functions inside `tuneHyperParameters()` in a moment. For now let's going just to observe that `tuneHyperParameters` just loops over all the possible hyperparameters and selects the one where the error between `xval` and `yval` is minimised. For the meaning of the various hyperparameter, consult the documentation of the `buildTree` and `buildForest` functions.
# The function uses multiple threads, so we calls `generateParallelRngs()` (in the `BetaML.Utils` submodule) to generate thread-safe random number generators and locks the comparision step.
function tuneHyperParameters(model,xtrain,ytrain,xval,yval;maxDepthRange=15:15,maxFeaturesRange=size(xtrain,2):size(xtrain,2),nTreesRange=20:20,βRange=0:0,minRecordsRange=2:2,repetitions=5,rng=Random.GLOBAL_RNG)
    ## We start with an infinitely high error
    bestRme         = +Inf
    bestMaxDepth    = 1
    bestMaxFeatures = 1
    bestMinRecords  = 2
    bestNTrees      = 1
    bestβ           = 0
    compLock        = ReentrantLock()

    ## Generate one random number generator per thread
    masterSeed = rand(rng,100:9999999999999) ## Some RNG have problems with very small seed. Also, the master seed has to be computed _before_ generateParallelRngs
    rngs = generateParallelRngs(rng,Threads.nthreads())

    ## We loop over all possible hyperparameter combinations...
    parLengths = (length(maxDepthRange),length(maxFeaturesRange),length(minRecordsRange),length(nTreesRange),length(βRange))
    Threads.@threads for ij in CartesianIndices(parLengths) ## This to avoid many nested for loops
           (maxDepth,maxFeatures,minRecords,nTrees,β)   = (maxDepthRange[Tuple(ij)[1]], maxFeaturesRange[Tuple(ij)[2]], minRecordsRange[Tuple(ij)[3]], nTreesRange[Tuple(ij)[4]], βRange[Tuple(ij)[5]]) ## The specific hyperparameters of this nested loop
           tsrng = rngs[Threads.threadid()] ## The random number generator is specific for each thread..
           joinedIndx = LinearIndices(parLengths)[ij]
           ## And here we make the seeding depending on the id of the loop, not the thread: hence we get the same results indipendently of the number of threads
           Random.seed!(tsrng,masterSeed+joinedIndx*10)
           totAttemptError = 0.0
           ## We run several repetitions with the same hyperparameter combination to account for stochasticity...
           for r in 1:repetitions
              if model == "DecisionTree"
                 ## Here we train the Decition Tree model
                 myTrainedModel = buildTree(xtrain,ytrain, maxDepth=maxDepth,maxFeatures=maxFeatures,minRecords=minRecords,rng=tsrng)
              else
                 ## Here we train the Random Forest model
                 myTrainedModel = buildForest(xtrain,ytrain,nTrees,maxDepth=maxDepth,maxFeatures=maxFeatures,minRecords=minRecords,β=β,rng=tsrng)
              end
              ## Here we make prediciton with this trained model and we compute its error
              ŷval   = predict(myTrainedModel, xval,rng=tsrng)
              rmeVal = meanRelError(ŷval,yval,normRec=false)
              totAttemptError += rmeVal
           end
           avgAttemptedDepthError = totAttemptError / repetitions
           begin
               lock(compLock) ## This step can't be run in parallel...
               try
                   ## Select this specific combination of hyperparameters if the error is the lowest
                   if avgAttemptedDepthError < bestRme
                     bestRme         = avgAttemptedDepthError
                     bestMaxDepth    = maxDepth
                     bestMaxFeatures = maxFeatures
                     bestNTrees      = nTrees
                     bestβ           = β
                     bestMinRecords  = minRecords
                   end
               finally
                   unlock(compLock)
               end
           end
    end
    return (bestRme,bestMaxDepth,bestMaxFeatures,bestMinRecords,bestNTrees,bestβ)
end


# We can now run the hyperparameter optimisation function with some "reasonable" ranges. To obtain replicable results we call `tuneHyperParameters` with `rng=copy(FIXEDRNG)`, where `FIXEDRNG` is a fixed-seeded random number generator guaranteed to maintain the same stream of random numbers even between different julia versions. That's also what we use for our unit tests.
(bestRme,bestMaxDepth,bestMaxFeatures,bestMinRecords) = tuneHyperParameters("DecisionTree",xtrain,ytrain,xval,yval,
           maxDepthRange=3:7,maxFeaturesRange=10:12,minRecordsRange=2:6,repetitions=10,rng=copy(FIXEDRNG))
println("DT: $bestRme - $bestMaxDepth - $bestMaxFeatures - $bestMinRecords") #src

# Now that we have found the "optimal" hyperparameters we can build ("train") our model using them:
myTree = buildTree(xtrain,ytrain, maxDepth=bestMaxDepth, maxFeatures=bestMaxFeatures,minRecords=bestMinRecords,rng=copy(FIXEDRNG));

# Let's benchmark the time and memory usage of the training step of a decision tree:
@btime  buildTree(xtrain,ytrain, maxDepth=bestMaxDepth, maxFeatures=bestMaxFeatures,minRecords=bestMinRecords,rng=copy(FIXEDRNG));
# Individual decision trees are blazing fast, among the fastest algorithms we could use.

#-

# The above `buildTree`function produces a DecisionTree object that can be used to make predictions given some new features, i.e. given some X matrix of (number of observations x dimensions), predict the corresponding Y vector of scalers in R.
(ŷtrain,ŷval,ŷtest) = predict.([myTree], [xtrain,xval,xtest])

# Note that the above code uses the "dot syntax" to "broadcast" `predict()` over an array of label matrices. It is exactly equivalent to:
ŷtrain = predict(myTree, xtrain);
ŷval   = predict(myTree, xval);
ŷtest  = predict(myTree, xtest);

# We now compute the relative mean error for the training, the validation and the test set. The `meanRelError` is a very flexible error function. Without additional parameter, it computes, as the name says, the _mean relative error_, also known as the "mean absolute percentage error" (MAPE)](https://en.wikipedia.org/wiki/Mean_absolute_percentage_error)") between an estimated and a true vector.
# However it can also compute the _relative mean error_ (as we do here), or use a p-norm higher than 1.
# The _mean relative error_ enfatises the relativeness of the error, i.e. all observations and dimensions weigth the same, wether large or small. Conversly, in the _relative mean error_ the same relative error on larger observations (or dimensions) weights more.
# In this exercise we use the later, as our data has clearly some outlier days with very small rents, and we care more of avoiding our customers finding empty bike racks than having unrented bikes on the rack. Targeting a low mean average error would push all our predicitons down to try accomodate the low-level predicitons (to avoid a large relative error), and that's not what we want.

# For example let'c consider the following example:
y     = [30,28,27,3,32,38];
ŷpref = [32,30,28,10,31,40;]
ŷbad  = [29,25,24,5,28,35];

# Here ŷpref is an ipotetical output of a model that minimise the relative mean error, while ŷbad minimise the mean realative error
meanRelError.([ŷbad, ŷpref],[y,y],normRec=true) ## Mean relative error
#-
meanRelError.([ŷbad, ŷpref],[y,y],normRec=false) ## Relative mean error
#-
plot([y ŷbad ŷpref], colour=[:black :red :green], label=["obs" "bad est" "good est"])

# We can then compute the relative mean error for the decision tree
(rmeTrain, rmeVal, rmeTest) = meanRelError.([ŷtrain,ŷval,ŷtest],[ytrain,yval,ytest],normRec=false)
#src (0.12659039939672598, 0.0937634812419113, 0.22233930540215602)
#-
@test rmeTest <= 0.24 #src


# We can plot the true labels vs the estimated one for the three subsets...
scatter(ytrain,ŷtrain,xlabel="daily rides",ylabel="est. daily rides",label=nothing,title="Est vs. obs in training period (DT)")
#-
scatter(yval,ŷval,xlabel="daily rides",ylabel="est. daily rides",label=nothing,title="Est vs. obs in validation period (DT)")
#-
scatter(ytest,ŷtest,xlabel="daily rides",ylabel="est. daily rides",label=nothing,title="Est vs. obs in testing period (DT)")


# Or we can visualise the true vs estimated bike shared on a temporal base.
# First on the full period (2 years) ...
ŷtrainfull = vcat(ŷtrain,fill(missing,nval+ntest))
ŷvalfull   = vcat(fill(missing,ntrain), ŷval, fill(missing,ntest))
ŷtestfull  = vcat(fill(missing,ntrain+nval), ŷtest)
plot(data[:,:dteday],[data[:,:cnt] ŷtrainfull ŷvalfull ŷtestfull], label=["obs" "train" "val" "test"], legend=:topleft, ylabel="daily rides", title="Daily bike sharing demand observed/estimated across the\n whole 2-years period (DT)")

# ..and then focusing on the testing period
stc = 620
endc = size(x,1)
plot(data[stc:endc,:dteday],[data[stc:endc,:cnt] ŷvalfull[stc:endc] ŷtestfull[stc:endc]], label=["obs" "val" "test"], legend=:bottomleft, ylabel="Daily rides", title="Focus on the testing period (DT)")

# The predictions aren't so bad in this case, however decision trees are highly instable, and the output could have depended just from the specific initial random seed.

# ## Random Forests
# Rather than trying to solve this problem using a single Decision Tree model, let's not try to use a _Random Forest_ model. Random forests average the results of many different decision trees and provide a more "stable" result.
# Being made of many decision trees, random forests are hovever more computationally expensive to train, but luckily they tend to self-tune (or self-regularise). In particular the default `maxDepth and `maxFeatures` shouldn't need tuning.
# We still tune however the model for other parameters, and in particular the β parameter, a prerogative of BetaML Random Forests that allows to assign more weigth to the best performing trees in the forest. It may be particularly important if there are many outliers in the data we don't want to "learn" from.
minRecordsRange=[2,4,5]; nTreesRange=60:10:80; βRange=100:100:300
(bestRme,bestMaxDepth,bestMaxFeatures,bestMinRecords,bestNTrees,bestβ) = tuneHyperParameters("RandomForest",xtrain,ytrain,xval,yval,
        maxDepthRange=size(xtrain,1):size(xtrain,1),maxFeaturesRange=Int(round(sqrt(size(xtrain,2)))):Int(round(sqrt(size(xtrain,2)))),
        minRecordsRange=minRecordsRange,nTreesRange=nTreesRange,βRange=βRange,repetitions=5,rng=copy(FIXEDRNG))
println("RF: $bestRme $bestMinRecords $bestNTrees $bestβ") #src

# As for decision trees, once the hyper-parameters of the model are tuned we wan refit the model using the optimal parameters.
#src  bestNTrees=80; bestMinRecords=5; bestβ=100
#src bestNTrees=60; bestMinRecords=5; bestβ=200
myForest = buildForest(xtrain,ytrain, bestNTrees, maxDepth=bestMaxDepth,maxFeatures=bestMaxFeatures,minRecords=bestMinRecords,β=bestβ,oob=true,rng=copy(FIXEDRNG));

# Let's now benchmark of the training of BetaML Random Forest model
@btime buildForest(xtrain,ytrain, bestNTrees, maxDepth=bestMaxDepth,maxFeatures=bestMaxFeatures,minRecords=bestMinRecords,β=bestβ,oob=true,rng=copy(FIXEDRNG));
# Random forests are evidently slower than individual decision trees (approximatly by a factor  number of trees/number of threads), but are still relativly fast

#-

# Random forests support the so-called "out-of-bag" error, an estimation of the error that we would have when the model is applied on a testing sample.
# However in this case the oob reported is much smaller than the testing error we will find. This is due to the fact that the division between training/validation and testing in this exercise is not random, but has a temporal basis. It seems that in this example the data in validation/testing follows a different pattern/variance than those in training (in probabilistic terms, they are not i.i.d.).
oobError, trueTestMeanRelativeError  = myForest.oobError,meanRelError(ŷtest,ytest,normRec=true)
#+
(ŷtrain,ŷval,ŷtest)         = predict.([myForest], [xtrain,xval,xtest])
(rmeTrain, rmeVal, rmeTest) = meanRelError.([ŷtrain,ŷval,ŷtest],[ytrain,yval,ytest],normRec=false)

@test rmeTest <= 0.23 #src

# In this case we found an error very similar to the one employing a single decision tree. Let's print the observed data vs the estimated one using the random forest and then along the temporal axis:
scatter(ytrain,ŷtrain,xlabel="daily rides",ylabel="est. daily rides",label=nothing,title="Est vs. obs in training period (RF)")
#-
scatter(yval,ŷval,xlabel="daily rides",ylabel="est. daily rides",label=nothing,title="Est vs. obs in validation period (RF)")
#-
scatter(ytest,ŷtest,xlabel="daily rides",ylabel="est. daily rides",label=nothing,title="Est vs. obs in testing period (RF)")

# Full period plot (2 years):
ŷtrainfull = vcat(ŷtrain,fill(missing,nval+ntest))
ŷvalfull   = vcat(fill(missing,ntrain), ŷval, fill(missing,ntest))
ŷtestfull  = vcat(fill(missing,ntrain+nval), ŷtest)
plot(data[:,:dteday],[data[:,:cnt] ŷtrainfull ŷvalfull ŷtestfull], label=["obs" "train" "val" "test"], legend=:topleft, ylabel="daily rides", title="Daily bike sharing demand observed/estimated across the\n whole 2-years period (RF)")

# Focus on the testing period:
stc = 620
endc = size(x,1)
plot(data[stc:endc,:dteday],[data[stc:endc,:cnt] ŷvalfull[stc:endc] ŷtestfull[stc:endc]], label=["obs" "val" "test"], legend=:bottomleft, ylabel="Daily rides", title="Focus on the testing period (RF)")

# ### Comparison with DecisionTree.jl random forest
# We now compare our results with those obtained employing the same model in the [DecisionTree package](https://github.com/bensadeghi/DecisionTree.jl), using the default suggested hyperparameters:

# Hyperparameters of the DecisionTree.jl random forest model
n_subfeatures=-1; n_trees=bestNTrees; partial_sampling=1; max_depth=26
min_samples_leaf=bestMinRecords; min_samples_split=bestMinRecords; min_purity_increase=0.0; seed=3

# We train the model..
model = DecisionTree.build_forest(ytrain, convert(Matrix,xtrain),
                     n_subfeatures,
                     n_trees,
                     partial_sampling,
                     max_depth,
                     min_samples_leaf,
                     min_samples_split,
                     min_purity_increase;
                     rng = seed)

# And we generate predictions and measure their error
(ŷtrain,ŷval,ŷtest) = DecisionTree.apply_forest.([model],[xtrain,xval,xtest]);

# Let's benchmark the DecisionTrees.jl Random Forest training
@btime DecisionTree.apply_forest.([model],[xtrain,xval,xtest]);
# Nothing to say, DecisionTrees.jl makes a unbelivable good job in optimising the algorithm. It is several order of magnitude faster than BetaML Random forests

(rmeTrain, rmeVal, rmeTest) = meanRelError.([ŷtrain,ŷval,ŷtest],[ytrain,yval,ytest],normRec=false)
# However the error on the test set remains relativly high. The very low error level on the training set is a sign that it overspecialised on the training set, and we should have instead running a dedicated hyperparameter optimisation for the model.

@test rmeTest <= 0.36 #src

# Finally we plot the DecisionTree.jl predictions alongside the observed value:
ŷtrainfull = vcat(ŷtrain,fill(missing,nval+ntest))
ŷvalfull   = vcat(fill(missing,ntrain), ŷval, fill(missing,ntest))
ŷtestfull  = vcat(fill(missing,ntrain+nval), ŷtest)
plot(data[:,:dteday],[data[:,:cnt] ŷtrainfull ŷvalfull ŷtestfull], label=["obs" "train" "val" "test"], legend=:topleft, ylabel="daily rides", title="Daily bike sharing demand observed/estimated across the\n whole 2-years period (DT.jl RF)")

# Again, focusing on the testing data:
stc  = 620
endc = size(x,1)
plot(data[stc:endc,:dteday],[data[stc:endc,:cnt] ŷvalfull[stc:endc] ŷtestfull[stc:endc]], label=["obs" "val" "test"], legend=:bottomleft, ylabel="Daily rides", title="Focus on the testing period (DT.jl RF)")

# ### Conclusions of Decision Trees / Random Forests methods
# The error obtained employing DecisionTree.jl is significantly larger than those obtained with the BetaML random forest model, altought to be fair with DecisionTrees.jl we didn't tuned its hyper-parameters. Also, DecisionTree.jl random forest model is much faster.
# This is partially due by the fact that internally DecisionTree.jl models optimise the algorithm by sorting the observations. BetaML trees/forests don't employ this optimisation and hence it can work with true categorical data for which ordering is not defined. An other explanation of this difference in speed is that BetaML Ransom Forest models accept `missing` values within the feature matrix.
# To sum up, BetaML random forests are ideal algorithms when we want to obtain good predictions in the most simpler way, even without tuning the hyperparameters, and without spending time in cleaning ("munging") the feature matrix, as they accept almost "any kind" of data as it is.

# ## Neural Networks

# BetaML provides only _deep forward neural networks_, artificial neural network units where the individual "nodes" are arranged in _layers_, from the _input layer_, where each unit holds the input coordinate, through various _hidden layer_ transformations, until the actual _output_ of the model:

# ![Neural Networks](https://raw.githubusercontent.com/sylvaticus/MITx_6.86x/master/Unit 03%20-%20Neural%20networks/assets/nn_scheme.png "Neural networks conceptual scheme")

# In this layerwise computation, each unit in a particular layer takes input from _all_ the preceding layer units and it has its own parameters that are adjusted to perform the overall computation. The _training_ of the network consists in retrieving the coefficients that minimise a _loss_ function betwenn the output of the model and the known data.
# In particular, a _deep_ (feedforward) neural network refers to a neural network that contains not only the input and output layers, but also hidden layers in between.

# Neural networks accept only numerical inputs. We hence need to convert all categorical data in numerical units. A common approach is to use the so-called "one-hot-encoding" where the catagorical values are converted into indicator variables (0/1), one for each possible value. This can be done in BetaML using the `oneHotEncoder` function:
seasonDummies  = convert(Array{Float64,2},oneHotEncoder(data[:,:season]))
weatherDummies = convert(Array{Float64,2},oneHotEncoder(data[:,:weathersit]))
wdayDummies    = convert(Array{Float64,2},oneHotEncoder(data[:,:weekday] .+ 1 ))

## We compose the feature matrix with the new dimensions obtained from the oneHotEncoder functions
x = hcat(Matrix{Float64}(data[:,[:instant,:yr,:mnth,:holiday,:workingday,:temp,:atemp,:hum,:windspeed]]),
         seasonDummies,
         weatherDummies,
         wdayDummies)
y = data[:,16];


# As usual, we split the data in training, validation and testing sets
((xtrain,xval,xtest),(ytrain,yval,ytest)) = partition([x,y],[0.75,0.125,1-0.75-0.125],shuffle=false)
(ntrain, nval, ntest) = size.([ytrain,yval,ytest],1)

# An other common operation with neural networks is to scale the feature vectors (X) and the labels (Y). The BetaML `scale()` function, by default, scale the data such that each dimension has mean 0 and variance 1.
# Note that we can provide the function with different scale factors or specify the columns not to scale (e.g. those resulting from the one-hot encoding). Finally we can reverse the scaling (this is useful to retrieve the unscaled features from a model trained with scaled ones).
colsNotToScale = [2;4;5;10:23]
xScaleFactors   = getScaleFactors(xtrain,skip=colsNotToScale)
yScaleFactors   = ([0],[0.001]) # getScaleFactors(ytrain) # This just divide by 1000. Using full scaling of Y we may get negative demand.
xtrainScaled    = scale(xtrain,xScaleFactors)
xvalScaled      = scale(xval,xScaleFactors)
xtestScaled     = scale(xtest,xScaleFactors)
ytrainScaled    = scale(ytrain,yScaleFactors)
yvalScaled      = scale(yval,yScaleFactors)
ytestScaled     = scale(ytest,yScaleFactors)
D               = size(xtrain,2)

#-

# As before, we select the best hyperparameters by using the validation set (it may take a while)...
function tuneHyperParameters(xtrain,ytrain,xval,yval;epochRange=50:50,hiddenLayerSizeRange=12:12,repetitions=5,rng=Random.GLOBAL_RNG)
    ## We start with an infinititly high error
    bestRme         = +Inf
    bestEpoch       = 0
    bestSize        = 0
    compLock        = ReentrantLock()

    ## Generate one random number generator per thread
    masterSeed = rand(rng,100:9999999999999) ## Some RNG have problems with very small seed. Also, the master seed has to be computed _before_ generateParallelRngs
    rngs       = generateParallelRngs(rng,Threads.nthreads())

    ## We loop over all possible hyperparameter combinations...
    parLengths = (length(epochRange),length(hiddenLayerSizeRange))
    Threads.@threads for ij in CartesianIndices(parLengths)
       (epoch,hiddenLayerSize)   = (epochRange[Tuple(ij)[1]], hiddenLayerSizeRange[Tuple(ij)[2]])
       tsrng = rngs[Threads.threadid()]
       joinedIndx = LinearIndices(parLengths)[ij]
       ## And here we make the seeding depending on the i of the loop, not the thread: hence we get the same results indipendently of the number of threads
       Random.seed!(tsrng,masterSeed+joinedIndx*10)
       totAttemptError = 0.0
       println("Testing epochs $epoch, layer size $hiddenLayerSize ...")
       ## We run several repetitions with the same hyperparameter combination to account for stochasticity...
       for r in 1:repetitions
           l1   = DenseLayer(D,hiddenLayerSize,f=relu,rng=tsrng) # Activation function is ReLU
           l2   = DenseLayer(hiddenLayerSize,hiddenLayerSize,f=identity,rng=tsrng)
           l3   = DenseLayer(hiddenLayerSize,1,f=relu,rng=tsrng)
           mynn = buildNetwork([l1,l2,l3],squaredCost,name="Bike sharing regression model") # Build the NN and use the squared cost (aka MSE) as error function
           ## Training it (default to ADAM)
           res  = train!(mynn,xtrain,ytrain,epochs=epoch,batchSize=8,optAlg=ADAM(),verbosity=NONE, rng=tsrng) # Use optAlg=SGD() to use Stochastic Gradient Descent
           ŷval = predict(mynn,xval)
           rmeVal  = meanRelError(ŷval,yval,normRec=false)
           totAttemptError += rmeVal
       end
       avgRme = totAttemptError / repetitions
       begin
           lock(compLock) ## This step can't be run in parallel...
           try
               ## Select this specific combination of hyperparameters if the error is the lowest
               if avgRme < bestRme
                 bestRme    = avgRme
                 bestEpoch  = epoch
                 bestSize   = hiddenLayerSize
               end
           finally
               unlock(compLock)
           end
       end
    end
    return (bestRme=bestRme,bestEpoch=bestEpoch,bestSize=bestSize)
end

epochsToTest     = [100,400]
hiddenLayerSizes = [5,15,30]
(bestRme,bestEpoch,bestSize) = tuneHyperParameters(xtrainScaled,ytrainScaled,xvalScaled,yvalScaled;epochRange=epochsToTest,hiddenLayerSizeRange=hiddenLayerSizes,repetitions=3,rng=copy(FIXEDRNG))
println("NN: $bestRme $bestEpoch $bestSize") #src
#src NN: 0.12631777965957725 100 5

# We now build our feed-forward neaural network. We create three layers, the first layers will always have a input size equal to the dimensions of our data (the number of columns), and the output layer, for a simple regression where the predictions are scalars, it will always be one.
# There are already several kind of layers available (and you can build your own kind by defining a new `struct` and implementing a few functions. See the `Nn` module documentation for details). Here we use only _dense_ layers, those found in typycal feed-fordward neural networks.
# For each layer, on top of its size (in "neurons") we can specify an _activation_ function. Here we use the `relu` for the two terminal layers (this will guarantee that our predictions are always positive) and `identity` for the hidden layer. Again, consult the `Nn` module documentation for other activation layers already defined, or use any function of your choice.
# Initial weight parameters can also be specified if needed. By default `DenseLayer` use the so-called _Xavier initialisation_.
l1   = DenseLayer(D,bestSize,f=relu,rng=copy(FIXEDRNG)) # Activation function is ReLU
l2   = DenseLayer(bestSize,bestSize,f=identity,rng=copy(FIXEDRNG))
l3   = DenseLayer(bestSize,1,f=relu,rng=copy(FIXEDRNG))
# Finally we "chain" the layer together and we assign a final loss function (agian, you can provide your own, if those available in BetaML don't suit your needs) in order to compose the "neural network" object.
mynn = buildNetwork([l1,l2,l3],squaredCost,name="Bike sharing regression model") ## Build the NN and use the squared cost (aka MSE) as error function

# The above neural network will use automatic differentiation (using the [Zygote]() package) to compute the gradient to minimise in the training step.
# Using manual differentiaiton, for the layers that support it, is however really simple. The network below is exactly equivalent to the one above, except it avoids automatic differentiation:
mynnManual = buildNetwork([
        DenseLayer(D,bestSize,f=relu,df=drelu,rng=copy(FIXEDRNG)),
        DenseLayer(bestSize,bestSize,f=identity,df=didentity,rng=copy(FIXEDRNG)),
        DenseLayer(bestSize,1,f=relu,df=drelu,rng=copy(FIXEDRNG))
    ], squaredCost, name="Bike sharing regression model", dcf=dSquaredCost)


# We can now re-do the training with the best hyperparameters.
# Several optimisation algorithms are available, and each accepts different parameters, like the _learning rate_ for the Stochastic Gradient Descent algorithm (used by default) or the exponential decay rates for the  moments estimates for the ADAM algorithm (that we use here, with the default parameters).
println("Final training of $bestEpoch epochs, with layer size $bestSize ...")
res  = train!(mynn,xtrainScaled,ytrainScaled,epochs=bestEpoch,batchSize=8,optAlg=ADAM(),rng=copy(FIXEDRNG)) ## Use optAlg=SGD() to use Stochastic Gradient Descent

# Let's benchmark the BetaML neural network training
@btime train!(mynnManual,xtrainScaled,ytrainScaled,epochs=bestEpoch,batchSize=8,optAlg=ADAM(),rng=copy(FIXEDRNG), verbosity=NONE);
# As we can see the model training is one order of magnitude slower than random forests, altought the memory requirement is approximatly the same

#-

# To obtain the neural network predictions we apply the function `predict` to the feature matrix X for which we want to generate previsions, and then, in order to obtain the _unscaled_ unscaled estimates we use the `scale` function applied to the scaled values with the original scaling factors and the parameter `rev` set to `true`.
# Note the usage of the _pipe_ operator to avoid ugly `function1(function2(function3(...)))` nested calls:

ŷtrain = @pipe predict(mynn,xtrainScaled) |> scale(_, yScaleFactors,rev=true);
ŷval   = @pipe predict(mynn,xvalScaled)   |> scale(_, yScaleFactors,rev=true);
ŷtest  = @pipe predict(mynn,xtestScaled)  |> scale(_ ,yScaleFactors,rev=true);

#-
(mreTrain, mreVal, mreTest) = meanRelError.([ŷtrain,ŷval,ŷtest],[ytrain,yval,ytest],normRec=false)
# The error is much lower. Let's plot our predictions:
@test mreTest < 0.18 #src

# Again, we can start by plotting the estimated vs the observed value:
scatter(ytrain,ŷtrain,xlabel="daily rides",ylabel="est. daily rides",label=nothing,title="Est vs. obs in training period (NN)")
#-
scatter(yval,ŷval,xlabel="daily rides",ylabel="est. daily rides",label=nothing,title="Est vs. obs in validation period (NN)")
#-
scatter(ytest,ŷtest,xlabel="daily rides",ylabel="est. daily rides",label=nothing,title="Est vs. obs in testing period (NN)")
#-

# We now plot across the time dimension, first plotting the whole period (2 years):
ŷtrainfull = vcat(ŷtrain,fill(missing,nval+ntest))
ŷvalfull   = vcat(fill(missing,ntrain), ŷval, fill(missing,ntest))
ŷtestfull  = vcat(fill(missing,ntrain+nval), ŷtest)
plot(data[:,:dteday],[data[:,:cnt] ŷtrainfull ŷvalfull ŷtestfull], label=["obs" "train" "val" "test"], legend=:topleft, ylabel="daily rides", title="Daily bike sharing demand observed/estimated across the\n whole 2-years period  (NN)")

# ...and then focusing on the testing data
stc  = 620
endc = size(x,1)
plot(data[stc:endc,:dteday],[data[stc:endc,:cnt] ŷvalfull[stc:endc] ŷtestfull[stc:endc]], label=["obs" "val" "test"], legend=:bottomleft, ylabel="Daily rides", title="Focus on the testing period (NN)")


# ### Comparison with Flux

# We now to apply the same Neural Network model using the [Flux](https://fluxml.ai/) framework, a dedicated neural network library.
# reusing the optimal parameters that we did found in `tuneHyperParameters`

# We fix the default random number generator so that the Flux example gives a reproducible output
Random.seed!(123)

# We define the Flux neural network model and load it with data...
l1         = Flux.Dense(D,bestSize,Flux.relu)
l2         = Flux.Dense(bestSize,bestSize,identity)
l3         = Flux.Dense(bestSize,1,Flux.relu)
Flux_nn    = Flux.Chain(l1,l2,l3)
loss(x, y) = Flux.mse(Flux_nn(x), y)
ps         = Flux.params(Flux_nn)
nndata     = Flux.Data.DataLoader((xtrainScaled', ytrainScaled'), batchsize=8,shuffle=true)

Flux_nn2   = deepcopy(Flux_nn)      ## A copy for the time benchmarking
ps2        = Flux.params(Flux_nn2)  ## A copy for the time benchmarking

# We do the training of the Flux model...
Flux.@epochs bestEpoch Flux.train!(loss, ps, nndata, Flux.ADAM(0.001, (0.9, 0.8)))

# ..and we benchmark it..
@btime begin for i in 1:bestEpoch Flux.train!(loss, ps2, nndata, Flux.ADAM(0.001, (0.9, 0.8))) end end
#src # Quite surprisling, Flux training seems a bit slow. The actual results seems to depend from the actual hardware and by default Flux seems not to use multi-threading. While I suspect Flux scales better with larger networks and/or data, for these small examples on my laptop it is still a bit slower than BetaML even on a single thread.
# On this small example the speed of Flux is on the same order than BetaML (the actual difference seems to depend on the specific RNG seed), however I suspect that Flux scales much better with larger networks and/or data.

# We obtain the estimates...
ŷtrainf = @pipe Flux_nn(xtrainScaled')' |> scale(_,yScaleFactors,rev=true);
ŷvalf   = @pipe Flux_nn(xvalScaled')'   |> scale(_,yScaleFactors,rev=true);
ŷtestf  = @pipe Flux_nn(xtestScaled')'  |> scale(_,yScaleFactors,rev=true);

# ..and we compute the mean relative errors..
(mreTrain, mreVal, mreTest) = meanRelError.([ŷtrainf,ŷvalf,ŷtestf],[ytrain,yval,ytest],normRec=false)
# .. finding an error not significantly different than the one obtained from BetaML.Nn.

#-
@test mreTest < 0.18 #src

# Plots:
scatter(ytrain,ŷtrainf,xlabel="daily rides",ylabel="est. daily rides",label=nothing,title="Est vs. obs in training period (Flux.NN)")
#-
scatter(yval,ŷvalf,xlabel="daily rides",ylabel="est. daily rides",label=nothing,title="Est vs. obs in validation period (Flux.NN)")
#-
scatter(ytest,ŷtestf,xlabel="daily rides",ylabel="est. daily rides",label=nothing,title="Est vs. obs in testing period (Flux.NN)")
#-
ŷtrainfullf = vcat(ŷtrainf,fill(missing,nval+ntest))
ŷvalfullf   = vcat(fill(missing,ntrain), ŷvalf, fill(missing,ntest))
ŷtestfullf  = vcat(fill(missing,ntrain+nval), ŷtestf)
plot(data[:,:dteday],[data[:,:cnt] ŷtrainfullf ŷvalfullf ŷtestfullf], label=["obs" "train" "val" "test"], legend=:topleft, ylabel="daily rides", title="Daily bike sharing demand observed/estimated across the\n whole 2-years period (Flux.NN)")
#-
stc = 620
endc = size(x,1)
plot(data[stc:endc,:dteday],[data[stc:endc,:cnt] ŷvalfullf[stc:endc] ŷtestfullf[stc:endc]], label=["obs" "val" "test"], legend=:bottomleft, ylabel="Daily rides", title="Focus on the testing period (Flux.NN)")


# ### Conclusions of Neural Network models

# If we strive for the most accurate predictions, deep neural networks uysually offer the best solution. However they are computationally expensive, so with limited resourses we may get better results by fine tuning and running many repetitions of "simpler" decision trees or even random forest models than a large naural network with insufficient hyperparameter tuning.
# Also, we shoudl consider that decision trees/random forests are much simple to work with.

# That said, specialised neural network libraries, like Flux, allow to use GPU and specialised hardware letting neural networks to scale with very big datasets.

# Still, for small and medium datasets, BetaML provides simpler yet customisable solutions that are accurate and fast.
