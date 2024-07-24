// This code uses TMA's 1d load to load an array to
// shared memory and then change the value in the
// shared memory and uses TMA's store to store the
// array back to global memory.

#include <cuda/barrier>
#include <iostream>

#include "tma_tensor_map.cuh"
#include "matrix_utilities.cuh"
#include "profile_utilities.cuh"

using barrier = cuda::barrier<cuda::thread_scope_block>;
namespace cde = cuda::device::experimental;

const int array_size = 128;
const int tile_size = 16;

__global__ void add_one_kernel(const __grid_constant__ CUtensorMap tensor_map, int coordinate)
{
  // Shared memory buffers for x and y. The destination shared memory buffer of
  // a bulk operations should be 16 byte aligned.
  __shared__ alignas(16) int tile_shared[tile_size];

  // 1. a) Initialize shared memory barrier with the number of threads participating in the barrier.
  //    b) Make initialized barrier visible in async proxy.
  // #pragma nv_diag_suppress static_var_with_dynamic_init
  __shared__ barrier bar;
  if (threadIdx.x == 0)
  {
    init(&bar, blockDim.x);              // a)
    cde::fence_proxy_async_shared_cta(); // b)
  }
  __syncthreads();

  // 2. Initiate TMA transfer to copy global to shared memory.
  barrier::arrival_token token;
  if (threadIdx.x == 0)
  {
    cde::cp_async_bulk_tensor_1d_global_to_shared(tile_shared, &tensor_map, coordinate, bar);
    // 3a. Arrive on the barrier and tell how many bytes are expected to come in (the transaction count)
    token = cuda::device::barrier_arrive_tx(bar, 1, sizeof(tile_shared));
  }
  else
  {
    // 3b. Rest of threads just arrive
    token = bar.arrive();
  }

  // 3c. Wait for the data to have arrived.
  bar.wait(std::move(token));

  // 4. Compute saxpy and write back to shared memory
  for (int i = threadIdx.x; i < array_size; i += blockDim.x)
  {
    if (i < tile_size)
    {
      tile_shared[i] += 1;
    }
  }

  // 5. Wait for shared memory writes to be visible to TMA engine.
  cde::fence_proxy_async_shared_cta();
  __syncthreads();
  // After syncthreads, writes by all threads are visible to TMA engine.

  // 6. Initiate TMA transfer to copy shared memory to global memory
  if (threadIdx.x == 0)
  {
    cde::cp_async_bulk_tensor_1d_shared_to_global(&tensor_map, coordinate, tile_shared);
    // 7. Wait for TMA transfer to have finished reading shared memory.
    // Create a "bulk async-group" out of the previous bulk copy operation.
    cde::cp_async_bulk_commit_group();
    // Wait for the group to have completed reading from shared memory.
    cde::cp_async_bulk_wait_group_read<0>();
  }

  __threadfence();
  __syncthreads();
}

int main()
{
  // initialize array and fill it with values
  int h_data[array_size];
  for (size_t i = 0; i < array_size; ++i)
  {
    h_data[i] = i;
  }

  print_matrix(h_data, array_size / tile_size, tile_size);

  // transfer array to device
  int *d_data = nullptr;
  cudaMalloc(&d_data, array_size * sizeof(int));
  cudaMemcpy(d_data, h_data, array_size * sizeof(int), cudaMemcpyHostToDevice);

  // create tensor map
  CUtensorMap tensor_map = create_1d_tensor_map(array_size, tile_size, d_data);

  size_t offset = tile_size * 1; // select the second tile of the array to change
  add_one_kernel<<<1, 128>>>(tensor_map, offset);

  cuda_check_error();

  cudaMemcpy(h_data, d_data, array_size * sizeof(int), cudaMemcpyDeviceToHost);
  cudaFree(d_data);

  print_matrix(h_data, array_size / tile_size, tile_size);

  return 0;
}
