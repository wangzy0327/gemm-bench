#include "operator.h"
#include <cstdlib>
#include <cstdio>
#include <vector>
#include <chrono>
#include <iostream>
#include <cuda_runtime.h>
#include <cublas_v2.h>
#include "utils.h"
#include <cublasLt.h>

void MatMul::performance_measuring(Simulator *simu, int rounds)
{
    if (config.args.size() < 8)
    {
        std::cerr << "invalid configuration of MatMul!\n";
        exit(0);
    }

    int M = config.args[0];
    int N = config.args[1];
    int K = config.args[2];
    int TRANSA = config.args[3];
    int TRANSB = config.args[4];
    int TENSOR_OP = config.args[5];
    int ALGO_ID = config.args[6];
    int dtype = config.args[7];

    size_t dsize = sizeof(float);
    if (dtype == DTYPE_HALF)
        dsize = sizeof(half);

    float alpha = 1.0, beta = 0.0;
    half alpha_half = 1.0, beta_half = 0.0;

    cublasHandle_t handle;
    CUBLAS_CALL(cublasCreate(&handle));

    int max_size_a = M * K, max_size_b = K * N, max_size_c = M * N;
    void *devPtrA = 0, *devPtrB = 0, *devPtrC = 0;
    CUDA_CALL(cudaMalloc((void **)&devPtrA, max_size_a * dsize));
    CUDA_CALL(cudaMalloc((void **)&devPtrB, max_size_b * dsize));
    CUDA_CALL(cudaMalloc((void **)&devPtrC, max_size_c * dsize));

    void *A = malloc(max_size_a * dsize);
    void *B = malloc(max_size_b * dsize);
    void *C = malloc(max_size_c * dsize);

    if (dtype == DTYPE_FLOAT)
    {
        for (int i = 0; i < max_size_a; i++)
            ((float *)A)[i] = rand() % 5;
        for (int i = 0; i < max_size_b; i++)
            ((float *)B)[i] = rand() % 5;
        for (int i = 0; i < max_size_c; i++)
            ((float *)C)[i] = rand() % 5;
    }else if (dtype == DTYPE_HALF)
    {
        for (int i = 0; i < max_size_a; i++)
            ((half *)A)[i] = __half(float(rand() % 5));
        for (int i = 0; i < max_size_b; i++)
            ((half *)B)[i] = __half(float(rand() % 5));
        for (int i = 0; i < max_size_c; i++)
            ((half *)C)[i] = __half(float(rand() % 5));
    }
    

    CUDA_CALL(cudaMemcpy(devPtrA, A, max_size_a * dsize, cudaMemcpyHostToDevice));
    CUDA_CALL(cudaMemcpy(devPtrB, B, max_size_b * dsize, cudaMemcpyHostToDevice));
    CUDA_CALL(cudaMemcpy(devPtrC, C, max_size_c * dsize, cudaMemcpyHostToDevice));

    cublasOperation_t transa, transb;
    int lda, ldb, ldc = M;
    switch (TRANSA)
    {
    case 0:
        transa = CUBLAS_OP_N;
        lda = M;
        break;
    case 1:
        transa = CUBLAS_OP_T;
        lda = K;
        break;
    default:
        printf("Invalid transa\n");
        exit(1);
    }
    switch (TRANSB)
    {
    case 0:
        transb = CUBLAS_OP_N;
        ldb = K;
        break;
    case 1:
        transb = CUBLAS_OP_T;
        ldb = N;
    default:
        printf("Invalid transb\n");
        exit(1);
    }

    cublasGemmAlgo_t algo;
    if (TENSOR_OP == 0)
    {
        switch (ALGO_ID)
        {
        case -1:
            algo = CUBLAS_GEMM_DEFAULT;
            break;
        case 0:
            algo = CUBLAS_GEMM_ALGO0;
            break;
        case 1:
            algo = CUBLAS_GEMM_ALGO1;
            break;
        case 2:
            algo = CUBLAS_GEMM_ALGO2;
            break;
        case 3:
            algo = CUBLAS_GEMM_ALGO3;
            break;
        case 4:
            algo = CUBLAS_GEMM_ALGO4;
            break;
        case 5:
            algo = CUBLAS_GEMM_ALGO5;
            break;
        case 6:
            algo = CUBLAS_GEMM_ALGO6;
            break;
        case 7:
            algo = CUBLAS_GEMM_ALGO7;
            break;
        case 8:
            algo = CUBLAS_GEMM_ALGO8;
            break;
        case 9:
            algo = CUBLAS_GEMM_ALGO9;
            break;
        case 10:
            algo = CUBLAS_GEMM_ALGO10;
            break;
        case 11:
            algo = CUBLAS_GEMM_ALGO11;
            break;
        case 12:
            algo = CUBLAS_GEMM_ALGO12;
            break;
        case 13:
            algo = CUBLAS_GEMM_ALGO13;
            break;
        case 14:
            algo = CUBLAS_GEMM_ALGO14;
            break;
        case 15:
            algo = CUBLAS_GEMM_ALGO15;
            break;
        case 16:
            algo = CUBLAS_GEMM_ALGO16;
            break;
        case 17:
            algo = CUBLAS_GEMM_ALGO17;
            break;
        case 18:
            algo = CUBLAS_GEMM_ALGO18;
            break;
        case 19:
            algo = CUBLAS_GEMM_ALGO19;
            break;
        case 20:
            algo = CUBLAS_GEMM_ALGO20;
            break;
        case 21:
            algo = CUBLAS_GEMM_ALGO21;
            break;
        case 22:
            algo = CUBLAS_GEMM_ALGO22;
            break;
        case 23:
            algo = CUBLAS_GEMM_ALGO23;
            break;
        default:
            printf("Invalid algo id\n");
            exit(1);
        }
    }
    else
    {
        switch (ALGO_ID)
        {
        case -1:
            algo = CUBLAS_GEMM_DEFAULT_TENSOR_OP;
            break;
        case 0:
            algo = CUBLAS_GEMM_ALGO0_TENSOR_OP;
            break;
        case 1:
            algo = CUBLAS_GEMM_ALGO1_TENSOR_OP;
            break;
        case 2:
            algo = CUBLAS_GEMM_ALGO2_TENSOR_OP;
            break;
        case 3:
            algo = CUBLAS_GEMM_ALGO3_TENSOR_OP;
            break;
        case 4:
            algo = CUBLAS_GEMM_ALGO4_TENSOR_OP;
            break;
        case 5:
            algo = CUBLAS_GEMM_ALGO5_TENSOR_OP;
            break;
        case 6:
            algo = CUBLAS_GEMM_ALGO6_TENSOR_OP;
            break;
        case 7:
            algo = CUBLAS_GEMM_ALGO7_TENSOR_OP;
            break;
        case 8:
            algo = CUBLAS_GEMM_ALGO8_TENSOR_OP;
            break;
        case 9:
            algo = CUBLAS_GEMM_ALGO9_TENSOR_OP;
            break;
        case 10:
            algo = CUBLAS_GEMM_ALGO10_TENSOR_OP;
            break;
        case 11:
            algo = CUBLAS_GEMM_ALGO11_TENSOR_OP;
            break;
        case 12:
            algo = CUBLAS_GEMM_ALGO12_TENSOR_OP;
            break;
        case 13:
            algo = CUBLAS_GEMM_ALGO13_TENSOR_OP;
            break;
        case 14:
            algo = CUBLAS_GEMM_ALGO14_TENSOR_OP;
            break;
        case 15:
            algo = CUBLAS_GEMM_ALGO15_TENSOR_OP;
            break;
        default:
            printf("Invalid algo id\n");
            exit(1);
        }
    }

    double avg_time = 0;
    float time = 0;
    cudaEvent_t start, stop;
    CUDA_CALL(cudaEventCreate(&start));
    CUDA_CALL(cudaEventCreate(&stop));

    for (int i = 0; i < rounds; ++i)
    {
        cudaEventRecord(start);
        if (dtype == DTYPE_FLOAT)
        {
            CUBLAS_CALL(cublasGemmEx(handle, transa, transb, M, N, K, &alpha,
                                     devPtrA, CUDA_R_32F, lda,
                                     devPtrB, CUDA_R_32F, ldb,
                                     &beta, devPtrC, CUDA_R_32F, ldc, CUDA_R_32F, algo));
        }
        else if (dtype == DTYPE_HALF)
        {
            CUBLAS_CALL(cublasGemmEx(handle, transa, transb, M, N, K, &alpha_half,
                                     devPtrA, CUDA_R_16F, lda,
                                     devPtrB, CUDA_R_16F, ldb,
                                     &beta_half, devPtrC, CUDA_R_16F, ldc, CUDA_R_16F, algo));
        }

        CUDA_CALL(cudaEventRecord(stop));
        CUDA_CALL(cudaEventSynchronize(stop));
        CUDA_CALL(cudaEventElapsedTime(&time, start, stop));
        avg_time += time;
	std::cout<<"time: "<<time<<std::endl;
    }
    avg_time /= rounds;

    CUDA_CALL(cudaFree(devPtrA));
    CUDA_CALL(cudaFree(devPtrB));
    CUDA_CALL(cudaFree(devPtrC));
    free(A);
    free(B);
    free(C);
    CUBLAS_CALL(cublasDestroy(handle));

    double tflops = (double)M * (double)N * (double)K * 2 / avg_time / 1000000000.0;

    simu->updatePfMap(config, avg_time, tflops, {});
}
