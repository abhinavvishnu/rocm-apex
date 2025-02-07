# Introduction

This repository holds NVIDIA-maintained utilities to streamline
mixed precision and distributed training in Pytorch.
Some of the code here will be included in upstream Pytorch eventually.
The intention of Apex is to make up-to-date utilities available to
users as quickly as possible.

## Full API Documentation: [https://nvidia.github.io/apex](https://nvidia.github.io/apex)

## [GTC 2019](https://github.com/mcarilli/mixed_precision_references/tree/master/GTC_2019) and [Pytorch DevCon 2019](https://github.com/mcarilli/mixed_precision_references/tree/master/Pytorch_Devcon_2019) Slides

# Contents

## 1. Amp:  Automatic Mixed Precision

`apex.amp` is a tool to enable mixed precision training by changing only 3 lines of your script.
Users can easily experiment with different pure and mixed precision training modes by supplying
different flags to `amp.initialize`.

[Webinar introducing Amp](https://info.nvidia.com/webinar-mixed-precision-with-pytorch-reg-page.html)
(The flag `cast_batchnorm` has been renamed to `keep_batchnorm_fp32`).

[API Documentation](https://nvidia.github.io/apex/amp.html)

[Comprehensive Imagenet example](https://github.com/NVIDIA/apex/tree/master/examples/imagenet)

[DCGAN example coming soon...](https://github.com/NVIDIA/apex/tree/master/examples/dcgan)

[Moving to the new Amp API](https://nvidia.github.io/apex/amp.html#transition-guide-for-old-api-users) (for users of the deprecated "Amp" and "FP16_Optimizer" APIs)

## 2. Distributed Training

`apex.parallel.DistributedDataParallel` is a module wrapper, similar to
`torch.nn.parallel.DistributedDataParallel`.  It enables convenient multiprocess distributed training,
optimized for NVIDIA's NCCL communication library.

[API Documentation](https://nvidia.github.io/apex/parallel.html)

[Python Source](https://github.com/NVIDIA/apex/tree/master/apex/parallel)

[Example/Walkthrough](https://github.com/NVIDIA/apex/tree/master/examples/simple/distributed)

The [Imagenet example](https://github.com/NVIDIA/apex/tree/master/examples/imagenet)
shows use of `apex.parallel.DistributedDataParallel` along with `apex.amp`.

### Synchronized Batch Normalization

`apex.parallel.SyncBatchNorm` extends `torch.nn.modules.batchnorm._BatchNorm` to
support synchronized BN.
It allreduces stats across processes during multiprocess (DistributedDataParallel) training.
Synchronous BN has been used in cases where only a small
local minibatch can fit on each GPU.
Allreduced stats increase the effective batch size for the BN layer to the
global batch size across all processes (which, technically, is the correct
formulation).
Synchronous BN has been observed to improve converged accuracy in some of our research models.

### Checkpointing

To properly save and load your `amp` training, we introduce the `amp.state_dict()`, which contains all `loss_scalers` and their corresponding unskipped steps,
as well as `amp.load_state_dict()` to restore these attributes.

In order to get bitwise accuracy, we recommend the following workflow:
```python
# Initialization
opt_level = 'O1'
model, optimizer = amp.initialize(model, optimizer, opt_level=opt_level)

# Train your model
...
with amp.scale_loss(loss, optimizer) as scaled_loss:
    scaled_loss.backward()
...

# Save checkpoint
checkpoint = {
    'model': model.state_dict(),
    'optimizer': optimizer.state_dict(),
    'amp': amp.state_dict()
}
torch.save(checkpoint, 'amp_checkpoint.pt')
...

# Restore
model = ...
optimizer = ...
checkpoint = torch.load('amp_checkpoint.pt')

model, optimizer = amp.initialize(model, optimizer, opt_level=opt_level)
model.load_state_dict(checkpoint['model'])
optimizer.load_state_dict(checkpoint['optimizer'])
amp.load_state_dict(checkpoint['amp'])

# Continue training
...
```

Note that we recommend restoring the model using the same `opt_level`. Also note that we recommend calling the `load_state_dict` methods after `amp.initialize`.

# Requirements

Python 3

CUDA 9 or newer

PyTorch 0.4 or newer.  The CUDA and C++ extensions require pytorch 1.0 or newer.

We recommend the latest stable release, obtainable from
[https://pytorch.org/](https://pytorch.org/).  We also test against the latest master branch, obtainable from [https://github.com/pytorch/pytorch](https://github.com/pytorch/pytorch).

It's often convenient to use Apex in Docker containers.  Compatible options include:
* [NVIDIA Pytorch containers from NGC](https://ngc.nvidia.com/catalog/containers/nvidia%2Fpytorch), which come with Apex preinstalled.  To use the latest Amp API, you may need to `pip uninstall apex` then reinstall Apex using the **Quick Start** commands below.
* [official Pytorch -devel Dockerfiles](https://hub.docker.com/r/pytorch/pytorch/tags), e.g. `docker pull pytorch/pytorch:nightly-devel-cuda10.0-cudnn7`, in which you can install Apex using the **Quick Start** commands.

See the [Docker example folder](https://github.com/NVIDIA/apex/tree/master/examples/docker) for details.

## On ROCm:
* Python 3.6
* Pytorch 1.5 or newer, The HIPExtensions require 1.5 or newer.
* We recommend follow the instructions from [ROCm-Pytorch](https://github.com/ROCmSoftwarePlatform/pytorch) to install pytorch on ROCm.
* Note: For pytorch versions < 1.8, building from source is no longer supported, please use the release package [ROCm-Apex v0.3](https://github.com/ROCmSoftwarePlatform/apex/releases/tag/v0.3) . 

# Quick Start

### Rocm
Apex on ROCm supports both python only build and extension build.
Note: Pytorch version recommended is >=1.5 for extension build.

### To install using python only build use the following command in apex folder:
```
python setup.py install
```

### To install using extensions enabled use the following command in apex folder:
```
python setup.py install --cpp_ext --cuda_ext
```
Note that using --cuda_ext flag to install Apex will also enable all the extensions supported on ROCm including "--distributed_adam", "--distributed_lamb", "--bnp", "--xentropy", "--deprecated_fused_adam", "--deprecated_fused_lamb", and "--fast_multihead_attn".

### To install Apex on ROCm using ninja and without cloning the source
```
pip install ninja
pip install -v --install-option="--cpp_ext" --install-option="--cuda_ext" 'git+https://github.com/ROCmSoftwarePlatform/apex.git'
```

### Linux

For performance and full functionality, we recommend installing Apex with
CUDA and C++ extensions via
```
git clone https://github.com/NVIDIA/apex
cd apex
pip install -v --disable-pip-version-check --no-cache-dir --global-option="--cpp_ext" --global-option="--cuda_ext" ./
```

Apex also supports a Python-only build (required with Pytorch 0.4) via
```
pip install -v --disable-pip-version-check --no-cache-dir ./
```
A Python-only build omits:
- Fused kernels required to use `apex.optimizers.FusedAdam`.
- Fused kernels required to use `apex.normalization.FusedLayerNorm`.
- Fused kernels that improve the performance and numerical stability of `apex.parallel.SyncBatchNorm`.
- Fused kernels that improve the performance of `apex.parallel.DistributedDataParallel` and `apex.amp`.
`DistributedDataParallel`, `amp`, and `SyncBatchNorm` will still be usable, but they may be slower.

Pyprof support has been moved to its own [dedicated repository](https://github.com/NVIDIA/PyProf).
The codebase is deprecated in Apex and will be removed soon.

### Windows support
Windows support is experimental, and Linux is recommended.  `pip install -v --no-cache-dir --global-option="--cpp_ext" --global-option="--cuda_ext" .` may work if you were able to build Pytorch from source
on your system.  `pip install -v --no-cache-dir .` (without CUDA/C++ extensions) is more likely to work.  If you installed Pytorch in a Conda environment, make sure to install Apex in that same environment.
