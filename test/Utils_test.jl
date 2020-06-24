using Test, Statistics

using BetaML.Utils

println("*** Testing individual utility functions (module `Utils`)...")

# ==================================
# TEST 1: oneHotEncoder
println("Going through Test1 (oneHotEncoder)...")

a = [[1,3,4],[1,4,2,2,3],[2,3]]
b = [2,1,5,2,1]
c = 2
ae = oneHotEncoder(a,5,count=true)
be = oneHotEncoder(b,6,count=true)
ce = oneHotEncoder(c,6)
@test sum(ae*be*ce') == 4

# ==================================
# TEST 2: softMax
println("** Going through Test2 (softmax and other activation functions)...")
@test isapprox(softmax([2,3,4],β=0.1),[0.3006096053557272,0.3322249935333472,0.36716540111092544])

@test didentity(-1) == 1 && relu(-1) == 0 && drelu(-1) == 0 && celu(-1,α=0.1) == -0.09999546000702375 && dcelu(-1) == 0.36787944117144233 &&
      elu(-1,α=0.1) == -0.06321205588285576 && delu(-1) == 0.36787944117144233 && plu(-1) == -1 && dplu(-1) == 1

@test didentity(1) == 1 && relu(1) == 1 && drelu(1) == 1 && celu(1) == 1 && dcelu(1) == 1 &&
    elu(1) == 1 && delu(1) == 1 && plu(1) == 1 && dplu(1) == 1

@test dtanh(1) == 0.41997434161402614 && sigmoid(1) == 0.7310585786300049 == dsoftplus(1) && dsigmoid(1) == 0.19661193324148188 &&
      softplus(1) == 1.3132616875182228 && mish(1) == 0.8650983882673103 && dmish(1) == 1.0490362200997922

# ==================================
# TEST 3: autoJacobian
println("** Going through Test3 (autoJacobian)...")
@test isapprox(softmax([2,3,4],β=0.1),[0.3006096053557272,0.3322249935333472,0.36716540111092544])

#import BetaML.Utils: autoJacobian
@test autoJacobian(x -> (x[1]*2,x[2]*x[3]),[1,2,3]) == [2.0 0.0 0.0; 0.0 3.0 2.0]

b = softmax([2,3,4],β=1/2)
c = softmax([2,3.0000001,4],β=1/2)
softmax2(x) = softmax(x,β=1/2)
autoGrad = autoJacobian(softmax2,[2,3,4])
realG2 = [(c[1]-b[1])*10000000,(c[2]-b[2])*10000000,(c[3]-b[3])*10000000]
@test isapprox(autoGrad[:,2],realG2,atol=0.000001)
manualGrad = dsoftmax([2,3,4],β=1/2)
@test isapprox(manualGrad[:,2],realG2,atol=0.000001)

# Manual way is hundred of times faster
#@benchmark autoJacobian(softMax2,[2,3,4])
#@benchmark dSoftMax([2,3,4],β=1/2)

# ==================================
# New test
println("** Going through testing accuracy...")

x = [0.01 0.02 0.1 0.05 0.2 0.1  0.05 0.27  0.2;
     0.05 0.01 0.2 0.02 0.1 0.27 0.1  0.05  0.2]
y = [3,3]
@test [accuracy(x,y,tol=i) for i in 1:10] == [0.0, 0.5, 0.5, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0]
x = [0.3 0.2 0.5; 0.5 0.25 0.25; 0.1 0.1 0.9]
y = [1, 3, 1]
@test accuracy(x,y) == 0.0
@test accuracy(x,y, ignoreLabels=true) == 1.0

# ==================================
# New test
println("** Going through testing scaling...")

skip = [1,4,5]
x = [1.1 4.1 8.1 3 8; 2 4 9 7 2; 7 2 9 3 1]
scaleFactors = getScaleFactors(x,skip=skip)
y  = scale(x,scaleFactors)
y2 = scale(x)
x2 = copy(x)
scale!(x2)
@test y2 == x2
@test all((sum(mean(y,dims=1)), sum(var(y,corrected=false,dims=1)) ) .≈ (11.366666666666667, 21.846666666666668))
x3 = scale(y,scaleFactors,rev=true)
@test x3 == x

# ==================================
# New test
println("** Testing batch()...")

@test size.(batch(10,3),1) == [3,3,3]
@test size.(batch(10,12),1) == [10]

# ==================================
# New test
println("** Testing meanRelError()...")

ŷ = [22 142 328; 3 9 31; 5 10 32; 3 10 36]
y = [20 140 330; 1 11 33; 3 8 30; 5 12 38]
p=2
(n,d) = size(y)

# case 1 - average of the relative error (records and dimensions normalised)
avgϵRel = sum(abs.((ŷ-y)./ y).^p)^(1/p)/(n*d)
#avgϵRel = (norm((ŷ-y)./ y,p)/(n*d))
meanRelError(ŷ,y,normDim=true,normRec=true,p=p) == avgϵRel
# case 2 - normalised by dimensions (i.e.  all dimensions play the same)
avgϵRel_byDim = (sum(abs.(ŷ-y) .^ (1/p),dims=1).^(1/p) ./ n) ./   (sum(abs.(y) .^ (1/p) ,dims=1) ./n)
avgϵRel = mean(avgϵRel_byDim)
@test meanRelError(ŷ,y,normDim=true,normRec=false,p=p) == avgϵRel
# case 3
avgϵRel_byRec = (sum(abs.(ŷ-y) .^ (1/p),dims=2).^(1/p) ./ d) ./   (sum(abs.(y) .^ (1/p) ,dims=2) ./d)
avgϵRel = mean(avgϵRel_byRec)
@test meanRelError(ŷ,y,normDim=false,normRec=true,p=p) == avgϵRel
# case 4 - average error relativized
avgϵRel = (sum(abs.(ŷ-y).^p)^(1/p) / (n*d)) / (sum( abs.(y) .^p)^(1/p) / (n*d))
#avgϵRel = (norm((ŷ-y),p)/(n*d)) / (norm(y,p) / (n*d))
@test meanRelError(ŷ,y,normDim=false,normRec=false,p=p) == avgϵRel


# ==================================
# New test
println("** Testing pca()...")

X = [1 10 100; 1.1 15 120; 0.95 23 90; 0.99 17 120; 1.05 8 90; 1.1 12 95]
out = pca(X,error=0.05)
@test out.error ≈ 1.0556269747774571e-5
@test sum(out.X) ≈ 662.3492034128955
#X2 = out.X*out.P'
