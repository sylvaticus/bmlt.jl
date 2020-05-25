using Test

using Bmlt.Utils

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
println("Going through Test2 (softMax)...")
@test isapprox(softMax([2,3,4],β=0.1),[0.3006096053557272,0.3322249935333472,0.36716540111092544])


# ==================================
# TEST 3: autoJacobian
println("Going through Test3 (softMax, dSoftMax and autoJacobian)...")
@test isapprox(softMax([2,3,4],β=0.1),[0.3006096053557272,0.3322249935333472,0.36716540111092544])

#import Bmlt.Utils: autoJacobian
@test autoJacobian(x -> (x[1]*2,x[2]*x[3]),[1,2,3]) == [2.0 0.0 0.0; 0.0 3.0 2.0]

b = softMax([2,3,4],β=1/2)
c = softMax([2,3.0000001,4],β=1/2)
softMax2(x) = softMax(x,β=1/2)
autoGrad = autoJacobian(softMax2,[2,3,4])
realG2 = [(c[1]-b[1])*10000000,(c[2]-b[2])*10000000,(c[3]-b[3])*10000000]
@test isapprox(autoGrad[:,2],realG2,atol=0.000001)
manualGrad = dSoftMax([2,3,4],β=1/2)
@test isapprox(manualGrad[:,2],realG2,atol=0.000001)