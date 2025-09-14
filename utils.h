#ifndef UTILS_H_
#define UTILS_H_

#ifdef WITH_ROCM
#define CUDA_CALL(x) do { if((x) != hipSuccess) { \
        printf("Error at %s:%d, %d\n", __FILE__, __LINE__, EXIT_FAILURE); \
        exit(EXIT_FAILURE);}} while(0)

#define CUBLAS_CALL(x) do { if((x) != rocblas_status_success) { \
        printf("Error %d at %s:%d, %d\n", x, __FILE__, __LINE__, EXIT_FAILURE); \
        exit(EXIT_FAILURE);}} while(0)

#define CUDNN_CALL(x) do { if((x) != miopenStatusSuccess) { \
        printf("Error at %s:%d, %d\n", __FILE__, __LINE__, EXIT_FAILURE); \
        exit(EXIT_FAILURE);}} while(0)

#define CURAND_CALL(x) do { if((x) != hiprandStatusSuccess) { \
        printf("Error at %s:%d, %d\n", __FILE__, __LINE__, EXIT_FAILURE); \
        exit(EXIT_FAILURE);}} while(0)
#else
#define CUDA_CALL(x) do { if((x) != cudaSuccess) { \
        printf("Error at %s:%d, %d\n", __FILE__, __LINE__, EXIT_FAILURE); \
        exit(EXIT_FAILURE);}} while(0)

#define CUBLAS_CALL(x) do { if((x) != CUBLAS_STATUS_SUCCESS) { \
        printf("Error %d at %s:%d, %d\n", x, __FILE__, __LINE__, EXIT_FAILURE); \
        exit(EXIT_FAILURE);}} while(0)

#define CUDNN_CALL(x) do { if((x) != CUDNN_STATUS_SUCCESS) { \
        printf("Error at %s:%d, %d\n", __FILE__, __LINE__, EXIT_FAILURE); \
        exit(EXIT_FAILURE);}} while(0)

#define CURAND_CALL(x) do { if((x) != CURAND_STATUS_SUCCESS) { \
        printf("Error at %s:%d, %d\n", __FILE__, __LINE__, EXIT_FAILURE); \
        exit(EXIT_FAILURE);}} while(0)
#endif

#include <sys/time.h>
#include <ctime>
#ifndef WITH_ROCM
#include <curand.h>
#endif
#include <cstdio>

double get_durtime(struct timeval beg, struct timeval end);

//void rand_gen_data(float* des, int num_of_elems);

constexpr int DTYPE_FLOAT = 0;
constexpr int DTYPE_HALF = 1;
constexpr int DTYPE_DOUBLE = 2;
constexpr int DTYPE_INT8 = 3;

#endif
