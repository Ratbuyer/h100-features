// This code uses TMA's 2d load to load a matrix's tile to
// shared memory and then change the value in the
// shared memory and uses TMA's store to store the
// tile back to global memory. We print the result matrix to prove the
// changes are done

// note very carefully the order of the m and k coordinate in the api calls
// and note the alignment requirement of the coordinatess

#include <cuda.h>
#include <cuda/barrier>
#include <stdio.h>

#include "matrix_utilities.cuh"
#include "profile_utilities.cuh"
#include "tma.cuh"
#include "tma_tensor_map.cuh"

// Suppress warning about barrier in shared memory
#pragma nv_diag_suppress static_var_with_dynamic_init

using barrier = cuda::barrier<cuda::thread_scope_block>;
namespace cde = cuda::device::experimental;

constexpr size_t M = 64; // Number of rows of matrix
constexpr size_t K = 32; // Number of columns of matrix
constexpr size_t gmem_len = M * K;

constexpr int m = 16; // subtile rows
constexpr int k = 8;  // subtile columns

static constexpr int buf_len = k * m;

__global__ void test(const __grid_constant__ CUtensorMap tensor_map, int x,
					 int y) {
	__shared__ alignas(128) int smem_buffer[buf_len];
	__shared__ barrier bar;

	if (threadIdx.x == 0) {
		init(&bar, blockDim.x);
	}
	__syncthreads();

	// Load data:
	uint64_t token;
	if (threadIdx.x == 0) {
		// just to demonstrate using prefetch, completely unnecessary here
		copy_async_2d_prefetch(&tensor_map, x, y);
		// call the loading api
		cde::cp_async_bulk_tensor_2d_global_to_shared(smem_buffer, &tensor_map,
													  x, y, bar);
		token = cuda::device::barrier_arrive_tx(bar, 1, sizeof(smem_buffer));
	} else {
		token = bar.arrive();
	}

	bar.wait(cuda::std::move(token));

	__syncthreads();

	// Update subtile, + 1
	for (int i = threadIdx.x; i < buf_len; i += blockDim.x) {
		smem_buffer[i] += 1;
	}

	cde::fence_proxy_async_shared_cta();
	__syncthreads();

	// Write back to global memory:
	if (threadIdx.x == 0) {
		cde::cp_async_bulk_tensor_2d_shared_to_global(&tensor_map, x, y,
													  smem_buffer);
		cde::cp_async_bulk_commit_group();
		cde::cp_async_bulk_wait_group_read<0>();
	}
	__threadfence();
	__syncthreads();
}

int main() {
	// fill the host matrix
	int host_tensor[gmem_len];
	fill_tilewise(host_tensor, M, K, m, k);

	print_matrix(host_tensor, M, K);

	// copy host matrix to device
	int *tensor_ptr = nullptr;
	cudaMalloc(&tensor_ptr, gmem_len * sizeof(int));
	cudaMemcpy(tensor_ptr, host_tensor, gmem_len * sizeof(int),
			   cudaMemcpyHostToDevice);

	// create tensor map for the matrix
	CUtensorMap tensor_map = create_2d_tensor_map(M, K, m, k, tensor_ptr);

	// launch kernel, select a tile coordinate
	// x (0 16 32 48) y (0 8 16 24) must be aligned with m and k
	int coordinate_m = 48;
	int coordinate_k = 24;
	test<<<1, 128>>>(tensor_map, coordinate_k, coordinate_m);

	cuda_check_error();

	// copy device matrix to host
	int host_gmem_tensor[gmem_len];
	cudaMemcpy(host_gmem_tensor, tensor_ptr, gmem_len * sizeof(int),
			   cudaMemcpyDeviceToHost);

	// verify the results
	print_matrix(host_gmem_tensor, M, K);

	return 0;
}
