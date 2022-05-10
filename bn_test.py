import torch
import torch.nn as nn
import time
import numpy as np
import apex
import apex.contrib.groupbn as bn
#import apex-0.1-py3.7-linux-x86_64.contrib.groupbn as bn
assert torch.cuda.is_available()
N, H, W, C = 256, 56, 56, 1024
print("Running with APEX Batchnorm")
m = bn.BatchNorm2d_NHWC(num_features = C, fuse_relu=False).to(device="cuda:0")
num_iters = 100
#input = input.permute(0, 3, 1, 2)
input = torch.randn(N, H, W, C).half().to(device="cuda:0")
time1 = time.time()
for i in np.arange(num_iters):
    output2 = m(input)
torch.cuda.synchronize()
print("Time is", (((time.time() - time1)/num_iters) * 1000 * 1000))

#print(output1.shape, output2.shape)
#print(input)
#print(" ")
#print(output2)
