#include <iostream>
#include <math.h>
#include <vector>

#include <cuda.h>
#include <cuda_fp16.h>
//#include <cuda_profiler_api.h>
#include <cuda_runtime.h>

#include <ATen/ATen.h>
#include <ATen/cuda/CUDAContext.h>
#include <torch/extension.h>

#include "dropout.cuh"
#include "layer_norm.cuh"
#include "softmax.cuh"
#include "strided_batched_gemm.cuh"

namespace multihead_attn {
namespace self_norm_add {
namespace rocblas_gemmex {

std::vector<torch::Tensor> fwd_cuda(bool use_time_mask, bool is_training,
                                    int heads, torch::Tensor const &inputs,
                                    torch::Tensor const &lyr_nrm_gamma_weights,
                                    torch::Tensor const &lyr_nrm_beta_weights,
                                    torch::Tensor const &input_weights,
                                    torch::Tensor const &output_weights,
                                    const uint8_t *pad_mask,
                                    float dropout_prob) {
  const int embed_dim = inputs.size(2);
  const int sequences = inputs.size(1);
  const int q_seq_len = inputs.size(0);
  const int k_seq_len = q_seq_len;
  const int batches = sequences * q_seq_len;
  const int total_tokens = batches * embed_dim;
  const int head_dim = embed_dim / heads;
  const int output_lin_dim = 3 * embed_dim;
  const int attn_batches = heads * sequences;
  const int lead_dim = attn_batches * 3 * head_dim;
  const int batch_stride = 3 * head_dim;
  const int dropout_elems = attn_batches * q_seq_len * k_seq_len;
  const float alpha = 1.0;
  const float beta = 0.0;
  const float scale = 1.0 / sqrt(static_cast<float>(head_dim));

  // There is no reason to use more than one stream as every kernel is
  // sequentially dependent
  cublasHandle_t handle = at::cuda::getCurrentCUDABlasHandle();
  cudaStream_t stream = at::cuda::getCurrentCUDAStream().stream();
  cublasSetStream(handle, stream);

  // 3 Intermediate Results + Output (Note: dropout intermediates are generated
  // by ATen library code)
  auto act_options = inputs.options().requires_grad(false);
  auto lyr_nrm_options = act_options.dtype(torch::kFloat32);
  auto mask_options = act_options.dtype(torch::kUInt8);

  torch::Tensor lyr_nrm_mean = torch::empty({batches}, lyr_nrm_options);
  torch::Tensor lyr_nrm_invvar = torch::empty({batches}, lyr_nrm_options);
  torch::Tensor lyr_nrm_results = torch::empty_like(inputs, act_options);

  torch::Tensor input_lin_results =
      torch::empty({q_seq_len, sequences, output_lin_dim}, act_options);
  torch::Tensor softmax_results =
      torch::empty({attn_batches, q_seq_len, k_seq_len}, act_options);
  torch::Tensor dropout_results =
      torch::empty({attn_batches, q_seq_len, k_seq_len}, act_options);
  torch::Tensor dropout_mask =
      torch::empty({attn_batches, q_seq_len, k_seq_len}, mask_options);
  torch::Tensor matmul2_results =
      torch::empty({q_seq_len, attn_batches, head_dim}, act_options);
  torch::Tensor output_lin_results = torch::empty_like(inputs, act_options);
  torch::Tensor dropout_add_mask = torch::empty_like(inputs, mask_options);
  torch::Tensor outputs = torch::empty_like(inputs, act_options);

  // Input Linear Results Pointers to Q, K, and V of interviewed activations
  void *q_lin_results_ptr = static_cast<void *>(input_lin_results.data_ptr());
  void *k_lin_results_ptr = static_cast<void *>(
      static_cast<half *>(input_lin_results.data_ptr()) + head_dim);
  void *v_lin_results_ptr = static_cast<void *>(
      static_cast<half *>(input_lin_results.data_ptr()) + 2 * head_dim);

  // Softmax Intermediate Result Ptr (used by Matmul1 -> Softmax)
  void *softmax_results_ptr = static_cast<void *>(softmax_results.data_ptr());

  char a_layout_t{'t'};
  char a_layout_n{'n'};
  char b_layout_n{'n'};

  rocblas_int flags = 0;

  //THCublasCheck(cublasSetMathMode(handle, CUBLAS_TENSOR_OP_MATH));
  // Layer Norm
  HostApplyLayerNorm<at::Half, float>(
      static_cast<at::Half *>(lyr_nrm_results.data_ptr()),
      static_cast<float *>(lyr_nrm_mean.data_ptr()),
      static_cast<float *>(lyr_nrm_invvar.data_ptr()),
      static_cast<const at::Half *>(inputs.data_ptr()),
      static_cast<int>(batches),   // n1
      static_cast<int>(embed_dim), // n2
      1.0e-5, static_cast<const at::Half *>(lyr_nrm_gamma_weights.data_ptr()),
      static_cast<const at::Half *>(lyr_nrm_beta_weights.data_ptr()));

  // Input Linear Fwd
  TORCH_CUDABLAS_CHECK(rocblas_gemm_ex(handle,
                             CUBLAS_OP_T, 
                             CUBLAS_OP_N,
                             output_lin_dim, 
                             batches, 
                             embed_dim,
                             static_cast<const void*>(&alpha),
                             static_cast<const void*>(input_weights.data_ptr()),
                             rocblas_datatype_f16_r /*a_type*/, 
                             embed_dim,
                             //static_cast<const void*>(inputs.data_ptr()),
                             static_cast<const void*>(lyr_nrm_results.data_ptr()),
                             rocblas_datatype_f16_r /*b_type*/, 
                             embed_dim, 
                             static_cast<const void*>(&beta),
                             q_lin_results_ptr,
                             rocblas_datatype_f16_r /*c_type*/, 
                             output_lin_dim,
                             q_lin_results_ptr,
                             rocblas_datatype_f16_r /*d_type*/,
                             output_lin_dim,
                             rocblas_datatype_f32_r /*compute_type*/,
                             rocblas_gemm_algo_standard /*algo*/,
                             0 /*solution_index*/,
                             flags));

  // MatMul1 of Dot-Product Attention Plus scaling by 1/Sqrt(head size)
  gemm_switch_fp32accum(     a_layout_t, 
                             b_layout_n, 
                             k_seq_len,
                             q_seq_len,
                             head_dim,
                             scale, 
                             static_cast<const half*>(k_lin_results_ptr), 
                             lead_dim, 
                             batch_stride, 
                             static_cast<const half*>(q_lin_results_ptr),
                             lead_dim, 
                             batch_stride, 
                             beta, 
                             static_cast<half*>(softmax_results_ptr), 
                             k_seq_len, 
                             k_seq_len*q_seq_len, 
                             static_cast<half*>(softmax_results_ptr),
                             k_seq_len,
                             k_seq_len*q_seq_len,
                             attn_batches,
                             flags);

  // Padded Softmax
  bool softmax_success = false;
  if (pad_mask == nullptr) {
    softmax_success = dispatch_softmax<half, half, float>(
        reinterpret_cast<half *>(softmax_results_ptr),
        reinterpret_cast<const half *>(softmax_results_ptr), k_seq_len,
        k_seq_len, attn_batches * q_seq_len);
  } else {
    if (use_time_mask) {
      softmax_success = dispatch_time_masked_softmax<half, half, float>(
          reinterpret_cast<half *>(softmax_results_ptr),
          reinterpret_cast<const half *>(softmax_results_ptr), pad_mask,
          k_seq_len, k_seq_len, attn_batches * q_seq_len, q_seq_len);
    } else {
      softmax_success = dispatch_masked_softmax<half, half, float>(
          reinterpret_cast<half *>(softmax_results_ptr),
          reinterpret_cast<const half *>(softmax_results_ptr), pad_mask,
          k_seq_len, k_seq_len, attn_batches * q_seq_len,
          attn_batches * q_seq_len / sequences);
    }
  }
  assert(softmax_success);

  if (is_training) {
    apex_fused_dropout_cuda<at::Half, float, uint32_t>(
        static_cast<at::Half const *>(softmax_results.data_ptr()),
        static_cast<at::Half *>(dropout_results.data_ptr()),
        static_cast<uint8_t *>(dropout_mask.data_ptr()), dropout_elems,
        (1.0f - dropout_prob));
  }

  // Matmul2
  gemm_switch_fp32accum(     a_layout_n, 
                             b_layout_n, 
                             head_dim, 
                             q_seq_len, 
                             k_seq_len, 
                             alpha, 
                             static_cast<const half*>(v_lin_results_ptr), 
                             lead_dim, 
                             batch_stride, 
                             (is_training) ? static_cast<const half*>(dropout_results.data_ptr()) : static_cast<const half*>(softmax_results.data_ptr()) , 
                             //static_cast<const half*>(dropout_results.data_ptr()), 
                             k_seq_len,  
                             k_seq_len*q_seq_len, 
                             beta, 
                             static_cast<half*>(matmul2_results.data_ptr()),  
                             head_dim*attn_batches,  
                             head_dim,
                             static_cast<half*>(matmul2_results.data_ptr()),
                             head_dim*attn_batches,
                             head_dim,
                             attn_batches,
                             flags);

  // Output Linear
  TORCH_CUDABLAS_CHECK(rocblas_gemm_ex(handle,
                             CUBLAS_OP_T, 
                             CUBLAS_OP_N,
                             embed_dim, 
                             batches, 
                             embed_dim,
                             static_cast<const void*>(&alpha),
                             static_cast<const void*>(output_weights.data_ptr()),
                             rocblas_datatype_f16_r /*a_type*/, 
                             embed_dim,
                             static_cast<const void*>(matmul2_results.data_ptr()),
                             rocblas_datatype_f16_r /*b_type*/, 
                             embed_dim, 
                             static_cast<const void*>(&beta),
                             static_cast<void*>(output_lin_results.data_ptr()),
                             rocblas_datatype_f16_r /*c_type*/, 
                             embed_dim,
                             static_cast<void*>(output_lin_results.data_ptr()),
                             rocblas_datatype_f16_r /*d_type*/,
                             embed_dim,
                             rocblas_datatype_f32_r /*compute_type*/,
                             rocblas_gemm_algo_standard /*algo*/,
                             0 /*solution_index*/,
                             flags));
  

  // End-of-block Dropout-Add 
  if (is_training) {
    apex_dropout_add_cuda<at::Half, float, uint32_t>(
        static_cast<at::Half const *>(output_lin_results.data_ptr()),
        static_cast<at::Half const *>(inputs.data_ptr()),
        static_cast<at::Half *>(outputs.data_ptr()),
        static_cast<uint8_t *>(dropout_add_mask.data_ptr()), total_tokens,
        (1.0f - dropout_prob));
  } else {
    apex_add_cuda<at::Half, float, uint32_t>(
        static_cast<at::Half const *>(output_lin_results.data_ptr()),
        static_cast<at::Half const *>(inputs.data_ptr()),
        static_cast<at::Half *>(outputs.data_ptr()), total_tokens);
  }

  //TORCH_CUDABLAS_CHECK(cublasSetMathMode(handle, CUBLAS_DEFAULT_MATH));

  return {lyr_nrm_results,  lyr_nrm_mean,    lyr_nrm_invvar, input_lin_results,
          softmax_results,  dropout_results, dropout_mask,   matmul2_results,
          dropout_add_mask, outputs};
}

std::vector<torch::Tensor> bwd_cuda(
    int heads, torch::Tensor const &output_grads,
    torch::Tensor const &matmul2_results, torch::Tensor const &dropout_results,
    torch::Tensor const &softmax_results,
    torch::Tensor const &input_lin_results,
    torch::Tensor const &lyr_nrm_results, torch::Tensor const &lyr_nrm_mean,
    torch::Tensor const &lyr_nrm_invvar, torch::Tensor const &inputs,
    torch::Tensor const &lyr_nrm_gamma_weights,
    torch::Tensor const &lyr_nrm_beta_weights,
    torch::Tensor const &input_weights, torch::Tensor const &output_weights,
    torch::Tensor const &dropout_mask, torch::Tensor const &dropout_add_mask,
    float dropout_prob) {
  const int embed_dim = inputs.size(2);
  const int sequences = inputs.size(1);
  const int q_seq_len = inputs.size(0);
  const int k_seq_len = q_seq_len;
  const int batches = sequences * q_seq_len;
  const int total_tokens = batches * embed_dim;
  const int head_dim = embed_dim / heads;
  const int output_lin_dim = 3 * embed_dim;
  const int attn_batches = heads * sequences;
  const int lead_dim = attn_batches * 3 * head_dim;
  const int batch_stride = 3 * head_dim;
  const int dropout_elems = attn_batches * q_seq_len * k_seq_len;
  const float alpha = 1.0;
  const float beta = 0.0;
  const float scale = 1.0 / sqrt(static_cast<float>(head_dim));

  // TODO: Streams can be used in Backprop but I haven't added more than one
  // in my first attempt to create the code
  cublasHandle_t handle = at::cuda::getCurrentCUDABlasHandle();
  cudaStream_t stream = at::cuda::getCurrentCUDAStream().stream();
  cublasSetStream(handle, stream);

  // Output Tensor Allocations
  torch::Tensor input_grads = torch::empty_like(inputs);
  torch::Tensor lyr_nrm_gamma_grads = torch::empty_like(lyr_nrm_gamma_weights);
  torch::Tensor lyr_nrm_beta_grads = torch::empty_like(lyr_nrm_beta_weights);
  torch::Tensor input_weight_grads = torch::empty_like(input_weights);
  torch::Tensor output_weight_grads = torch::empty_like(output_weights);
  // Intermediate Tensor Allocations
  torch::Tensor dropout_add_grads = torch::empty_like(output_grads);
  torch::Tensor output_lin_grads = torch::empty_like(matmul2_results);
  torch::Tensor matmul2_grads = torch::empty_like(dropout_results);
  torch::Tensor input_lin_output_grads = torch::empty_like(input_lin_results);
  torch::Tensor input_lin_grads = torch::empty_like(inputs);

  auto q_lin_results_ptr = static_cast<half *>(input_lin_results.data_ptr());
  auto k_lin_results_ptr =
      static_cast<half *>(input_lin_results.data_ptr()) + head_dim;
  auto v_lin_results_ptr =
      static_cast<half *>(input_lin_results.data_ptr()) + 2 * head_dim;

  auto q_lin_grads_ptr = static_cast<half *>(input_lin_output_grads.data_ptr());
  auto k_lin_grads_ptr =
      static_cast<half *>(input_lin_output_grads.data_ptr()) + head_dim;
  auto v_lin_grads_ptr =
      static_cast<half *>(input_lin_output_grads.data_ptr()) + 2 * head_dim;

  char a_layout_n{'n'};
  char a_layout_t{'t'};
  char b_layout_n{'n'};
  char b_layout_t{'t'}; 

  rocblas_int flags = 0;
  
  //TORCH_CUDABLAS_CHECK(cublasSetMathMode(handle, CUBLAS_TENSOR_OP_MATH));
  #ifdef __HIP_PLATFORM_HCC__
    #define PYTORCH_ROCBLAS_VERSION_DECIMAL (ROCBLAS_VERSION_MAJOR * 100 + ROCBLAS_VERSION_MINOR)
    #define USE_GEMM_FLAGS_FP16_ALT_IMPL (PYTORCH_ROCBLAS_VERSION_DECIMAL >= 242)
    #if USE_GEMM_FLAGS_FP16_ALT_IMPL
      #ifdef ROCM_BACKWARD_PASS_GUARD
        flags = at::BackwardPassGuard::is_backward_pass() ? rocblas_gemm_flags_fp16_alt_impl : 0;
      #endif
    #endif
  #endif

  // Dropout Add Backward
  apex_masked_scale_cuda<at::Half, float, uint32_t>(
      static_cast<at::Half const *>(output_grads.data_ptr()),
      static_cast<at::Half *>(dropout_add_grads.data_ptr()),
      static_cast<uint8_t const *>(dropout_add_mask.data_ptr()), total_tokens,
      (1.0 / (1.0 - dropout_prob)));

  // Output Linear Dgrad
  TORCH_CUDABLAS_CHECK(rocblas_gemm_ex(handle,
                             CUBLAS_OP_N, 
                             CUBLAS_OP_N,
                             embed_dim, 
                             batches, 
                             embed_dim,
                             static_cast<const void*>(&alpha),
                             static_cast<const void*>(output_weights.data_ptr()),
                             rocblas_datatype_f16_r /*a_type*/, 
                             embed_dim,
                             static_cast<const void*>(dropout_add_grads.data_ptr()),
                             rocblas_datatype_f16_r /*b_type*/, 
                             embed_dim, 
                             static_cast<const void*>(&beta),
                             static_cast<void*>(output_lin_grads.data_ptr()),
                             rocblas_datatype_f16_r /*c_type*/, 
                             embed_dim,
                             static_cast<void*>(output_lin_grads.data_ptr()),
                             rocblas_datatype_f16_r /*d_type*/,
                             embed_dim,
                             rocblas_datatype_f32_r /*compute_type*/,
                             rocblas_gemm_algo_standard /*algo*/,
                             0 /*solution_index*/,
                             flags));
 
  // Output Linear Wgrad
  TORCH_CUDABLAS_CHECK(rocblas_gemm_ex(handle,
                             CUBLAS_OP_N, 
                             CUBLAS_OP_T,
                             embed_dim, 
                             embed_dim,
                             batches, 
                             static_cast<const void*>(&alpha),
                             static_cast<const void*>(matmul2_results.data_ptr()),
                             rocblas_datatype_f16_r /*a_type*/, 
                             embed_dim,
                             static_cast<const void*>(dropout_add_grads.data_ptr()),
                             rocblas_datatype_f16_r /*b_type*/, 
                             embed_dim, 
                             static_cast<const void*>(&beta),
                             static_cast<void*>(output_weight_grads.data_ptr()),
                             rocblas_datatype_f16_r /*c_type*/, 
                             embed_dim,
                             static_cast<void*>(output_weight_grads.data_ptr()),
                             rocblas_datatype_f16_r /*d_type*/,
                             embed_dim,
                             rocblas_datatype_f32_r /*compute_type*/,
                             rocblas_gemm_algo_standard /*algo*/,
                             0 /*solution_index*/,
                             flags));

  // MatMul2 Dgrad1
  gemm_switch_fp32accum(     a_layout_t, 
                             b_layout_n, 
                             k_seq_len,
                             q_seq_len,
                             head_dim,
                             alpha, 
                             static_cast<const half*>(v_lin_results_ptr),
                             lead_dim, 
                             batch_stride,
                             static_cast<const half*>(output_lin_grads.data_ptr()),
                             head_dim*attn_batches, 
                             head_dim, 
                             beta, 
                             static_cast<half*>(matmul2_grads.data_ptr()),
                             k_seq_len, 
                             k_seq_len*q_seq_len,
                             static_cast<half*>(matmul2_grads.data_ptr()),
                             k_seq_len,
                             k_seq_len*q_seq_len,
                             attn_batches,
                             flags);
  
  // Matmul2 Dgrad2
  gemm_switch_fp32accum(     a_layout_n, 
                             b_layout_t, 
                             head_dim, 
                             k_seq_len, 
                             q_seq_len, 
                             alpha, 
                             static_cast<const half*>(output_lin_grads.data_ptr()),
                             head_dim*attn_batches, 
                             head_dim, 
                             static_cast<const half*>(dropout_results.data_ptr()),
                             k_seq_len, 
                             k_seq_len*q_seq_len, 
                             beta, 
                             v_lin_grads_ptr, 
                             lead_dim, 
                             batch_stride, 
                             v_lin_grads_ptr,
                             lead_dim,
                             batch_stride,
                             attn_batches,
                             flags);

  // Apply Dropout Mask and Scale by Dropout Probability 
  apex_masked_scale_cuda<at::Half,float,uint32_t>(
                             static_cast<at::Half const*>(matmul2_grads.data_ptr()),
							 static_cast<at::Half*>(matmul2_grads.data_ptr()),
							 static_cast<uint8_t const*>(dropout_mask.data_ptr()),
							 dropout_elems,
                             (1.0 / (1.0 - dropout_prob)));

  // Softmax Grad
  bool softmax_success = false;
  softmax_success = dispatch_softmax_backward<half, half, float>(
      static_cast<half *>(matmul2_grads.data_ptr()),
      static_cast<half *>(matmul2_grads.data_ptr()),
      reinterpret_cast<half const *>(softmax_results.data_ptr()), k_seq_len,
      k_seq_len, attn_batches * q_seq_len);
  assert(softmax_success);

  // Matmul1 Dgrad1
  gemm_switch_fp32accum(     a_layout_n, 
                             b_layout_n, 
                             head_dim, 
                             q_seq_len, 
                             k_seq_len, 
                             scale, 
                             k_lin_results_ptr, 
                             lead_dim, 
                             batch_stride, 
                             static_cast<half*>(matmul2_grads.data_ptr()),
                             k_seq_len, 
                             k_seq_len*q_seq_len, 
                             beta, 
                             q_lin_grads_ptr, 
                             lead_dim, 
                             batch_stride,
                             q_lin_grads_ptr,
                             lead_dim,
                             batch_stride, 
                             attn_batches,
                             flags);
  
  // Matmul1 Dgrad2
  gemm_switch_fp32accum(     a_layout_n, 
                             b_layout_t, 
                             head_dim, 
                             k_seq_len, 
                             q_seq_len, 
                             scale, 
                             q_lin_results_ptr, 
                             lead_dim, 
                             batch_stride, 
                             static_cast<half*>(matmul2_grads.data_ptr()),
                             k_seq_len, 
                             k_seq_len*q_seq_len, 
                             beta, 
                             k_lin_grads_ptr, 
                             lead_dim, 
                             batch_stride,
                             k_lin_grads_ptr,
                             lead_dim, 
                             batch_stride,
                             attn_batches,
                             flags);

  // Input Linear Dgrad  
  TORCH_CUDABLAS_CHECK(rocblas_gemm_ex(handle,
                             CUBLAS_OP_N, 
                             CUBLAS_OP_N,
                             embed_dim,
                             batches, 
                             output_lin_dim,
                             static_cast<const void*>(&alpha),
                             static_cast<const void*>(input_weights.data_ptr()),
                             rocblas_datatype_f16_r /*a_type*/, 
                             embed_dim,
                             static_cast<const void*>(q_lin_grads_ptr),
                             rocblas_datatype_f16_r /*b_type*/, 
                             output_lin_dim, 
                             static_cast<const void*>(&beta),
                             //static_cast<void*>(input_grads.data_ptr()),
                             static_cast<void*>(input_lin_grads.data_ptr()),
                             rocblas_datatype_f16_r /*c_type*/, 
                             embed_dim,
                             static_cast<void*>(input_lin_grads.data_ptr()),
                             rocblas_datatype_f16_r /*d_type*/,
                             embed_dim,
                             rocblas_datatype_f32_r /*compute_type*/,
                             rocblas_gemm_algo_standard /*algo*/,
                             0 /*solution_index*/,
                             flags));
  
  // Input Linear Wgrad  
  TORCH_CUDABLAS_CHECK(rocblas_gemm_ex(handle,
                             CUBLAS_OP_N, 
                             CUBLAS_OP_T,
                             embed_dim, 
                             output_lin_dim,
                             batches, 
                             static_cast<const void*>(&alpha),
                             //static_cast<const void*>(inputs.data_ptr()),
                             static_cast<const void*>(lyr_nrm_results.data_ptr()),
                             rocblas_datatype_f16_r /*a_type*/,
                             embed_dim,
                             static_cast<const void*>(q_lin_grads_ptr),
                             rocblas_datatype_f16_r /*b_type*/,
                             output_lin_dim,
                             static_cast<const void*>(&beta),
                             static_cast<void*>(input_weight_grads.data_ptr()),
                             rocblas_datatype_f16_r /*c_type*/, 
                             embed_dim,
                             static_cast<void*>(input_weight_grads.data_ptr()),
                             rocblas_datatype_f16_r /*d_type*/,
                             embed_dim,
                             rocblas_datatype_f32_r /*compute_type*/,
                             rocblas_gemm_algo_standard /*algo*/,
                             0 /*solution_index*/,
                             flags));

  // Fused Layer Norm Bwd with Residual Add
  HostLayerNormGradient<half, float>(
      static_cast<const half *>(input_lin_grads.data_ptr()),
      static_cast<const half *>(output_grads.data_ptr()),
      static_cast<const float *>(lyr_nrm_mean.data_ptr()),
      static_cast<const float *>(lyr_nrm_invvar.data_ptr()), inputs,
      static_cast<int>(batches),   // n1
      static_cast<int>(embed_dim), // n2
      static_cast<const half *>(lyr_nrm_gamma_weights.data_ptr()),
      static_cast<const half *>(lyr_nrm_beta_weights.data_ptr()), 1.0e-5,
      static_cast<half *>(input_grads.data_ptr()),
      static_cast<half *>(lyr_nrm_gamma_grads.data_ptr()),
      static_cast<half *>(lyr_nrm_beta_grads.data_ptr()));

  //TORCH_CUDABLAS_CHECK(cublasSetMathMode(handle, CUBLAS_DEFAULT_MATH));

  return {input_grads, lyr_nrm_gamma_grads, lyr_nrm_beta_grads,
          input_weight_grads, output_weight_grads};
}

} // end namespace rocblas_gemmex
} // end namespace self_norm_add 
} // end namespace multihead_attn

