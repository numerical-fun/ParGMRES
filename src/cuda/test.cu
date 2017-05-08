#include <iostream>
#include <algorithm>
#include <cassert>

#include <cuda.h>
#include <thrust/device_ptr.h>
#include <cusp/csr_matrix.h>
#include <cusp/io/matrix_market.h>
#include <cusp/krylov/gmres.h>
#include <cusp/print.h>

#include "CycleTimer.h"

#define WARP_SIZE               32
#define MAX_THREAD_NUM          1024 
#define KRYLOV_M                100
#define INDEX( i, j, dim )      (i * dim + j)
#define ROUND( num, base )      ((num + base - 1)/base)
#define HANDLE_ERROR( err )     (cuda_handle_error(err, __FILE__, __LINE__))

typedef struct csr_mat_t {
    int *rowstart;
    int *cindex;
    float *value;
    int nrow;
    int ncol;
    int nnz;
} csr_mat_t;

typedef struct vec_t {
    float *value;
    int size;
} vec_t;

/*
__inline__ __device__
float warp_reduce_sum(float val) {

    for (int offset = WARP_SIZE/2; offset > 0; offset /= 2) 
        val += __shfl_down(val, offset);
    return val;
}

__global__ 
void device_reduce_warp_atomic_kernel(float *in, float* out, int N) {

    float sum = float(0);
    for(int i = blockIdx.x * blockDim.x + threadIdx.x; 
            i < N; 
            i += blockDim.x * gridDim.x) {
        sum += in[i];
    }
    sum = warp_reduce_sum(sum);
    if (threadIdx.x & (WARP_SIZE - 1) == 0)
        atomicAdd(out, sum);
}
*/

/* kernel functions */

__global__ 
void mem_init(float *addr, float value, int N){
    
    int i = blockIdx.x * blockDim.x + threadIdx.x;

    if(i >= N) return;
    addr[i] = value;
}

__global__ 
void vector_sqrt(float *dst, float *src, int N){

    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if(i >= N) return;
    dst[i] = sqrt(src[i]);
}

__global__ 
void vector_divide_scalar(float *dst, float *src, float *val, int N){
    
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if(i >= N) return;
    dst[i] = src[i] / (*val);
}

__global__ 
void vector_dot(float *v1, float *v2, float *out, int N){
    
    int i = blockIdx.x * blockDim.x + threadIdx.x; 

    if(i >= N) return;

    float value = v1[i] * v2[i];
    atomicAdd(out, value);
}

__global__
void vector_sub_svector(float *w, float *v, float *val, int N){    
    int i = blockIdx.x * blockDim.x + threadIdx.x; 

    if(i >= N) return;

    w[i] = w[i] - v[i] * (*val);
}

__global__
void vector_update_gmres(float *x, float *V, float *y, int m, int N){
    
    int i = blockIdx.x * blockDim.x + threadIdx.x; 
    float entry = .0;

    if(i >= N) return;

    for(int k = 0; k < m; k++){
        entry += V[k*N+i] * y[k];
    }
    x[i] += entry;
}

__global__ 
void matrix_vector_multiply(float *w, csr_mat_t mat, float *x){
    
    int i = blockIdx.x * blockDim.x + threadIdx.x;

    int nrow = mat.nrow;
    int *rowstart = mat.rowstart;
    int *cindex = mat.cindex;
    float *value = mat.value;

    if(i >= nrow) return;

    int start_idx = rowstart[i];
    int end_idx = rowstart[i+1];

    float temp = 0.0;
    for (int k = start_idx; k < end_idx; ++k) {
        int j = cindex[k];
        temp += value[k] * x[j];
    }
    w[i] = temp;
}

__global__ 
void compute_remainder(float *r0, csr_mat_t mat, float *x, vec_t vec, float *beta){
     
    int i = blockIdx.x * blockDim.x + threadIdx.x;

    int nrow = mat.nrow;
    int *rowstart = mat.rowstart;
    int *cindex = mat.cindex;
    float *value = mat.value;

    if(i >= nrow) return;

    int start_idx = rowstart[i];
    int end_idx = rowstart[i+1];

    float temp = 0.0;
    for (int k = start_idx; k < end_idx; ++k) {
        int j = cindex[k];
        temp += value[k] * x[j];
    }
    r0[i] = temp - vec.value[i];

    float square = r0[i];
    square *= square;
    atomicAdd(beta, square);
}

/* host functions */

static void cuda_handle_error(cudaError_t err, const char *file, int line) {
    if (err != cudaSuccess) {
        printf( "%s in %s at line %d\n", cudaGetErrorString( err ),
                file, line );
        exit( EXIT_FAILURE );
    }
}

static void mem_log(float* device, int N){
    
    float host[1024];
    char buf[4096];
    int min = std::min(1024, N);

    assert(min >= 0);

    HANDLE_ERROR(cudaMemcpy(host, device, N*sizeof(float), cudaMemcpyDeviceToHost));

    for(int i = 0; i < min; i++){
        sprintf(buf, "%s%lf, ", buf, host[i]);
    }
    std::cout << buf << std::endl;
}

static void display_gpu_info() {
    
    const int kb = 1024;
    const int mb = kb * kb;
    
    std::cout << "\nCUDA version: v" << CUDART_VERSION << std::endl;
    std::cout << "Thrust version: v" << THRUST_MAJOR_VERSION << ".";
    std::cout << THRUST_MINOR_VERSION << std::endl; 

    int devCount;
    HANDLE_ERROR(cudaGetDeviceCount(&devCount));
    
    std::cout << "\nCUDA Devices: \n\n";

    for(int i = 0; i < devCount; ++i) {
        cudaDeviceProp props;
        HANDLE_ERROR(cudaGetDeviceProperties(&props, i));
        std::cout << i << ":\n  " << props.name << ": " << props.major << "." << props.minor << std::endl;
        std::cout << "  Global memory:   " << props.totalGlobalMem / mb << "mb" << std::endl;
        std::cout << "  Shared memory:   " << props.sharedMemPerBlock / kb << "kb" << std::endl;
        std::cout << "  Constant memory: " << props.totalConstMem / kb << "kb" << std::endl;
        std::cout << "  Block registers: " << props.regsPerBlock << std::endl << std::endl;

        std::cout << "  Warp size:         " << props.warpSize << std::endl;
        std::cout << "  Threads per block: " << props.maxThreadsPerBlock << std::endl;
        std::cout << "  Max block dimensions: [ " << props.maxThreadsDim[0] << ", " 
                                             << props.maxThreadsDim[1] << ", " 
                                             << props.maxThreadsDim[2] << " ]" << std::endl;
        std::cout << "  Max grid dimensions:  [ " << props.maxGridSize[0] << ", " 
                                             << props.maxGridSize[1] << ", " 
                                             << props.maxGridSize[2] << " ]" << std::endl;
        std::cout << std::endl;
    }
}


void debug(csr_mat_t mat){
        
    int dim = mat.ncol;
 
    float *H;
    float *V;

    float *r0;
    float *x;
    float *w;
    float *b;
    float *tmp;
    float *beta;
    vec_t vec;

    HANDLE_ERROR(cudaMalloc((void**)&H, (KRYLOV_M+1) * KRYLOV_M * sizeof(float))); 
    HANDLE_ERROR(cudaMalloc((void**)&V, (KRYLOV_M+1) * dim * sizeof(float))); 
    HANDLE_ERROR(cudaMalloc((void**)&r0, dim * sizeof(float)));
    HANDLE_ERROR(cudaMalloc((void**)&x, dim * sizeof(float)));
    HANDLE_ERROR(cudaMalloc((void**)&w, dim * sizeof(float)));
    HANDLE_ERROR(cudaMalloc((void**)&b, dim * sizeof(float)));
    HANDLE_ERROR(cudaMalloc((void**)&tmp, dim * sizeof(float)));
    HANDLE_ERROR(cudaMalloc((void**)&beta, sizeof(float)));

    int blocks = ROUND(dim, MAX_THREAD_NUM);
    int threads = MAX_THREAD_NUM;

    mem_init<<<blocks, threads>>>(x, 1.0, dim);

    blocks = ROUND(dim, MAX_THREAD_NUM);
    mem_init<<<blocks, threads>>>(b, .0, dim);
 
    vec.value = b;
    vec.size = dim;

    HANDLE_ERROR(cudaDeviceSynchronize());

    compute_remainder<<<blocks, threads>>>(r0, mat, x, vec, tmp);
    mem_log(r0, dim);

    vector_sqrt<<<1,1>>>(beta, tmp, 1);
    HANDLE_ERROR(cudaDeviceSynchronize());

    vector_divide_scalar<<<blocks, threads>>>(V, r0, beta, dim);
    mem_log(V, dim);
            

    int j = 0;
    matrix_vector_multiply<<<blocks, threads>>>(w, mat, (V + j*dim));
    mem_log(w, dim);

    float *out = H+(j+1)*(KRYLOV_M+1)+j;
    vector_dot<<<blocks, threads>>>(w, w, out, dim);

    vector_sqrt<<<1,1>>>(tmp, out, 1);  
    vector_divide_scalar<<<blocks, threads>>>(V+(j+1)*dim, w, tmp, dim);
    mem_log(V+(j+1)*dim, dim);


    HANDLE_ERROR(cudaFree(H));
    HANDLE_ERROR(cudaFree(V));
    HANDLE_ERROR(cudaFree(r0));
    HANDLE_ERROR(cudaFree(x));
    HANDLE_ERROR(cudaFree(w));
    HANDLE_ERROR(cudaFree(b));
    HANDLE_ERROR(cudaFree(tmp));
    HANDLE_ERROR(cudaFree(beta));
}

void gmres(csr_mat_t mat, vec_t vec, int m, float tol, int maxit){
   
    int dim = mat.ncol;
    int nit = 0;
    int innit = 0;
    int outnit = 0;

    float *H;
    float *V;

    float *x;
    float *y;
    float *w;
    float *r0;

    float *beta;
    float *tmp1;
    float *tmp2;

    HANDLE_ERROR(cudaMalloc((void**)&H, (m+1) * m * sizeof(float))); 
    HANDLE_ERROR(cudaMalloc((void**)&V, (m+1) * dim * sizeof(float))); 
    HANDLE_ERROR(cudaMalloc((void**)&x, dim * sizeof(float))); 
    HANDLE_ERROR(cudaMalloc((void**)&y, m * sizeof(float))); 
    HANDLE_ERROR(cudaMalloc((void**)&w, dim * sizeof(float))); 
    HANDLE_ERROR(cudaMalloc((void**)&r0, dim * sizeof(float))); 
    HANDLE_ERROR(cudaMalloc((void**)&beta, sizeof(float))); 
    HANDLE_ERROR(cudaMalloc((void**)&tmp1, sizeof(float))); 
    HANDLE_ERROR(cudaMalloc((void**)&tmp2, sizeof(float))); 

    int blocks = ROUND(dim, MAX_THREAD_NUM);
    int threads = MAX_THREAD_NUM;

    mem_init<<<blocks, threads>>>(x, .0, dim);

    /*
    while(nit < 1){
      
        // kernel 1: compute r0 and beta
        compute_remainder<<<blocks, threads>>>(r0, mat, x, vec, tmp1);
        vector_sqrt<<<1,1>>>(beta, tmp1, 1);
        vector_divide_scalar<<<blocks, threads>>>(V, r0, beta, dim);
        
        innit = 0;
        
        // Generate krylov subspace
        for(size_t j = 0; j < m; j++) {

            // tStart = CycleTimer::currentSeconds();
            
            // compute mat and vec mulplication (mat, V, j),  w can be placed at V(:, j+1) in the future
            matrix_vector_multiply<<<blocks, threads>>>(w, mat, (V + j*dim));

            // for (size_t i = 0; i < j; i++) {
            //     Vector v = V.getCol(i);
            //     H.set(i, j, w.dotV(v));
            //     w.isub(v.mulS(H.get(i, j)));
            // }

            for(size_t i = 0; i < j; i++){
                vector_dot<<<blocks, threads>>>(w, (V+i*dim), H+i*(KRYLOV_M+1)+j, dim);
                vector_sub_svector<<<blocks, threads>>>(w, (V+i*dim), H+i*(KRYLOV_M+1)+j, dim);
            }

            //H.set(j+1, j, w.norm2());
            //V.setCol(j+1, w.mulS(1.0 / H.get(j+1, j)));
            float *out = H+(j+1)*(KRYLOV_M+1)+j;
            vector_dot<<<blocks, threads>>>(w, w, out, dim);

            vector_sqrt<<<1,1>>>(tmp1, out, 1);  
            vector_divide_scalar<<<blocks, threads>>>(V+(j+1)*dim, w, tmp1, dim);
            
            // tKrylov += CycleTimer::currentSeconds() - tStart;
            // tStart = CycleTimer::currentSeconds();

            // later 
            // Vector y = leastSquareWithQR(H, j+1, beta);
            // x = x0.add(V.mulPartialT(y, j+1));
            vector_update_gmres<<<blocks, threads>>>(x, V, y, j+1, dim);

            compute_remainder<<<blocks, threads>>>(r0, mat, x, vec, tmp1);
            vector_sqrt<<<1,1>>>(tmp2, tmp1, 1);
            // float res_norm = A.mul(x).sub(b).norm2();

            nit++;
            innit++;
            
            // tLLS += CycleTimer::currentSeconds() - tStart;

            // if (res_norm < tol * b.norm2()) {
            //     cout << "FGMRES converged to relative tolerance: "
            //          << res_norm / b.norm2() << " at iteration " << nit
            //          << " (out: " << outnit << ", in: " << innit << ")" << endl;

            //     sprintf(buf, "[%.3f] ms in Krylov \n", tKrylov * 1000);
            //     cout << buf;
            //     sprintf(buf, "[%.3f] ms in LLS \n", tLLS * 1000);
            //     cout << buf;

            //     return x;
            // }
        }
        outnit++;
    }

    */

    HANDLE_ERROR(cudaFree(H));
    HANDLE_ERROR(cudaFree(V));
    HANDLE_ERROR(cudaFree(x));
    HANDLE_ERROR(cudaFree(y));
    HANDLE_ERROR(cudaFree(w));
    HANDLE_ERROR(cudaFree(r0));
    HANDLE_ERROR(cudaFree(tmp1));
    HANDLE_ERROR(cudaFree(beta));
}

int main(void)
{
    float start_time;
    float end_time;
    char buf[1024];

    display_gpu_info();

    // create an empty sparse matrix structure (CSR format)
    cusp::csr_matrix<int, float, cusp::device_memory> A;

    // load a matrix stored in MatrixMarket format
    cusp::io::read_matrix_market_file(A, "../data/cage4.mtx");

    // allocate storage for solution (x) and right hand side (b)
    cusp::array1d<float, cusp::device_memory> x(A.num_cols, 1);     // 0
    cusp::array1d<float, cusp::device_memory> b(A.num_rows, 0);     // 1

    // get raw pointer
    csr_mat_t csr_mat;
    csr_mat.nrow = A.num_rows;
    csr_mat.ncol = A.num_cols;
    csr_mat.nnz = A.values.size();
    csr_mat.value = thrust::raw_pointer_cast(A.values.data());
    csr_mat.cindex = thrust::raw_pointer_cast(A.column_indices.data());
    csr_mat.rowstart = thrust::raw_pointer_cast(A.row_offsets.data());

    vec_t vec;
    vec.value = thrust::raw_pointer_cast(b.data());
    vec.size = b.size();
  
    /* DEBUG */

    //debug(csr_mat);

    cusp::array1d<float, cusp::device_memory> y(A.num_rows);

    // compute y = A * x
    cusp::multiply(A, x, y);
 
    // print y
    cusp::print(y);

    /* end of DEBUG */

    /*

    // reference answer
    std::cout << "\nOur GMRES solution:\n\n";
    gmres(csr_mat, vec, 100, 1e-6, 1000);


    // reference answer
    std::cout << "\nReference answer from CUSP library:\n\n";

    // initialize b vector
    mem_init<<<ROUND(vec.size, MAX_THREAD_NUM), MAX_THREAD_NUM>>>(vec.value, .0, vec.size){

    // set stopping criteria:
    cusp::monitor<float> monitor(b, KRYLOV_M, 1e-6, 0, false);
    int restart = 50;

    // run gmres to solve 
    start_time = CycleTimer::currentSeconds();
    cusp::krylov::gmres(A, x, b, restart, monitor);
    end_time = CycleTimer::currentSeconds();

    // print the performance
    sprintf(buf, "[%.3f] ms in total (CSR Sparse GMRES) \n\n", 
            (end_time - start_time) * 1000);
    std::cout << buf;

    // print out result for debug
    // cusp::print(A);
    cusp::print(b);
    cusp::print(x);

    */

    return 0;
}

