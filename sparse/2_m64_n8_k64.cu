/*
This code demonstrates how to use the sparse wgmma instructions
to perform matrix multiplication

Sparse means matrix A follows a 2:4 format
*/

#include <assert.h>
#include <cuda.h>
#include <cuda_fp16.h>
#include <iostream>
#include <mma.h>
#include <random>
#include <stdio.h>
#include <cuda/barrier>

#include "matrix_utilities.cuh"
#include "profile_utilities.cuh"
#include "tma_tensor_map.cuh"
#include "wgmma.cuh"

#pragma nv_diag_suppress static_var_with_dynamic_init

const int M = 64;
const int N = 8;
const int K = 64;

// 2:4 format
const int K_A = 32;

const int threads_per_block = 32 * 4; // 4 warps
const int blocks = 1;

using barrier = cuda::barrier<cuda::thread_scope_block>;
namespace cde = cuda::device::experimental;

__global__ void kernel(
                        const __grid_constant__ CUtensorMap tensor_map_a,
                        const __grid_constant__ CUtensorMap tensor_map_b,
                        half *C,
                        u_int32_t *metadata_array) {

	const int tid = threadIdx.x;
	const int warp_id = tid / 32;
	const int lane_id = tid % 32;
	const int group_id = lane_id >> 2;
	const int lane_in_group = lane_id & 3;
	const int lane_in_work_group = lane_in_group % 2;

	__align__(128) __shared__ half A_shared[M * K_A];
	__align__(16) __shared__ half B_shared[K * N];

	__shared__ barrier bar;

	if (threadIdx.x == 0) {
		init(&bar, blockDim.x);
	}
	__syncthreads();

	uint64_t token;
	if (tid == 0) {
		// call the loading api
		cde::cp_async_bulk_tensor_2d_global_to_shared(A_shared, &tensor_map_a, 0,
													  0, bar);
		cde::cp_async_bulk_tensor_2d_global_to_shared(B_shared, &tensor_map_b,
													  0, 0, bar);
		token = cuda::device::barrier_arrive_tx(bar, 1, sizeof(A_shared) + sizeof(B_shared));
	} else {
		token = bar.arrive();
	}

	bar.wait(cuda::std::move(token));

	__syncthreads();

	// load metadata
	u_int32_t metadata;
	uint metadata_offset = warp_id * 8 * 4 + lane_in_work_group * 8 + group_id;
	metadata = metadata_array[metadata_offset];

	__syncthreads();

	// create descriptors
	GmmaDescriptor desc_a = make_desc<half *, 8, 32, 2>(A_shared);
	GmmaDescriptor desc_b = make_desc<half *, 8, 16, 0>(B_shared);

	// accumulator
	uint32_t c[2] = {};

	warpgroup_arrive();

	asm volatile("wgmma.mma_async.sp.sync.aligned.m64n8k32.f16.f16.f16 "
				 "{%0, %1}, " // c
				 "%2, %3, "	  // desc A, B
				 "%4, "		  // meta
				 "0, "		  // thread selection
				 "1, "		  // scale D
				 "%7, %8, "	  // +/- scale A, B
				 "%9, %10;"	  // transpose A, B
				 : "+r"(c[0]), "+r"(c[1])
				 : "l"(desc_a), "l"(desc_b),
				   "r"(metadata),	// metadata
				   "r"(0),			// thread selection
				   "r"(1),			// scale D
				   "n"(1), "n"(1),	// +- scale A, B
				   "n"(0), "n"(1)); // transpose A, B
	
	desc_a = make_desc<half *, 8, 32, 2>(A_shared + K_A / 2);
	desc_b = make_desc<half *, 8, 8, 0>(B_shared + 32 * N);
	
	warpgroup_arrive();
	
	metadata_offset = warp_id * 8 * 4 + 8 * 2 + lane_in_work_group * 8 + group_id;
	metadata = metadata_array[metadata_offset];
	
	asm volatile("wgmma.mma_async.sp.sync.aligned.m64n8k32.f16.f16.f16 "
				 "{%0, %1}, " // c
				 "%2, %3, "	  // desc A, B
				 "%4, "		  // meta
				 "0, "		  // thread selection
				 "1, "		  // scale D
				 "%7, %8, "	  // +/- scale A, B
				 "%9, %10;"	  // transpose A, B
				 : "+r"(c[0]), "+r"(c[1])
				 : "l"(desc_a), "l"(desc_b),
				   "r"(metadata),	// metadata
				   "r"(0),			// thread selection
				   "r"(1),			// scale D
				   "n"(1), "n"(1),	// +- scale A, B
				   "n"(0), "n"(1)); // transpose A, B

	// commit, start the computation
	warpgroup_commit_batch();

	// wait for the previous commit to finish
	warpgroup_wait<0>();

	// thread fence needed for async operations
	__threadfence();

	warpgroup_arrive();

	// store the result
	uint32_t *C_ptr = reinterpret_cast<uint32_t *>(C);

	int offset1 = warp_id * 16 * 4 + group_id * 4 + lane_in_group;
	int offset2 = warp_id * 16 * 4 + (group_id + 8) * 4 + lane_in_group;

	C_ptr[offset1] = c[0];
	C_ptr[offset2] = c[1];
}

int main() {

	half *d_C;
	half h_C[M * N];
	half h_CPU[M * N];
	half h_A[M * K];
	half h_A2[M * K_A];
	half h_B[K * N];

	fill_24(h_A, M, K);
	fill_random(h_B, K, N);

	// extract the non-zeros in each 2:4 tile to a compressed matrix A2
	compress24(h_A, h_A2, M, K);

	// print_matrix(h_A2, M, K_A);

	half *d_A, *d_B;

	cudaMalloc((void **)&d_A, M * K_A * sizeof(half));
	cudaMalloc((void **)&d_B, K * N * sizeof(half));
	cudaMalloc((void **)&d_C, M * N * sizeof(half));

	cudaMemcpy(d_A, h_A2, M * K_A * sizeof(half), cudaMemcpyHostToDevice);
	cudaMemcpy(d_B, h_B, K * N * sizeof(half), cudaMemcpyHostToDevice);

	int metadata_size = (M / 16) * (K / 16) * 8;

	u_int32_t *metadata_array = new u_int32_t[metadata_size];
	inspect_metadata(h_A, metadata_array, M, K);

	u_int32_t *d_metadata;
	cudaMalloc((void **)&d_metadata, metadata_size * sizeof(u_int32_t));
	cudaMemcpy(d_metadata, metadata_array, metadata_size * sizeof(u_int32_t),
			   cudaMemcpyHostToDevice);

	CUtensorMap tensor_map_a = create_2d_tensor_map<half, CU_TENSOR_MAP_DATA_TYPE_FLOAT16, CU_TENSOR_MAP_SWIZZLE_64B>(M, K_A, M, K_A, d_A);
	CUtensorMap tensor_map_b = create_2d_tensor_map<half, CU_TENSOR_MAP_DATA_TYPE_FLOAT16, CU_TENSOR_MAP_SWIZZLE_NONE>(K, N, K, N, d_B);

	kernel<<<blocks, threads_per_block>>>(tensor_map_a, tensor_map_b, d_C, d_metadata);

	cuda_check_error();

	cudaMemcpy(h_C, d_C, M * N * sizeof(half), cudaMemcpyDeviceToHost);

	// print_matrix<5>(h_A2, M, K_A);

	CPU_gemm(h_A, h_B, h_CPU, M, N, K);

	compare_matrices(h_CPU, h_C, M, N);

	// print_differnce(h_CPU, h_C, M, N, 0);

	return 0;
}
