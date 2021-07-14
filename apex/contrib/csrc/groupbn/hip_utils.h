#define __HIP_PLATFORM_HCC__
#include "hip/hip_runtime.h"
#ifndef CUDA_UTILS_H
#define CUDA_UTILS_H

typedef enum
{
    miopenTensorNCHW = 0 // NCHW is the only format supported by miopen
} miopenTensorFormat_t;

#define hipFuncAttributePreferredSharedMemoryCarveout 9
namespace at {
namespace cuda {

namespace utils {

static inline int MaxSharedMemoryPerMultiprocessor(int device_id) {
    return getDeviceProperties(device_id)->maxSharedMemoryPerMultiProcessor;
}


}
}
}


#endif
