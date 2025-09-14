#include <iostream>
#include <string>
#include <unordered_map>
#include <vector>
#include "simulator.h"
#include "operator.h"
#include "utils.h"

int main(int argc, char* argv[]) {
    // 检查命令行参数数量是否正确
    if (argc != 5) {
        std::cerr << "Usage: " << argv[0] << " M N K [fp64|fp32|fp16|int8]" << std::endl;
        return 1; // 返回错误码
    }

    // 从命令行参数中读取 M, N, K
    int M, N, K;
    try {
        M = std::stoi(argv[1]); // 第一个参数为 M
        N = std::stoi(argv[2]); // 第二个参数为 N
        K = std::stoi(argv[3]); // 第三个参数为 K
    } catch (const std::invalid_argument& e) {
        std::cerr << "Error: All arguments must be integers." << std::endl;
        return 1;
    }
    
    std::string dtype_str = argv[4];
    int dtype;

    std::unordered_map<std::string, int> dtype_map = {
        {"fp64", DTYPE_DOUBLE},
        {"fp32", DTYPE_FLOAT},
        {"fp16", DTYPE_HALF},
        {"int8", DTYPE_INT8}
    };

    if (dtype_map.find(dtype_str) == dtype_map.end()) {
        std::cerr << "Error: Unsupported dtype '" << dtype_str << "'. Supported: fp64, fp32, fp16, int8." << std::endl;
        return 1;
    }

    dtype = dtype_map[dtype_str];

    // 打印解析到的参数
    std::cout << "Parsed parameters: M=" << M << ", N=" << N << ", K=" << K << ", dtype=" << dtype_str << std::endl;

    std::vector<OpConfig> configVector;
    
    // OpConfig conv2dConfig;
    // conv2dConfig.opType = OpType::CONV2D;
    // conv2dConfig.args   = {
    // 	/* Group_count = */ 1,
    // 	/* Batch_size  = */ 64,
    // 	/* In_channels_per_grp =  */ 64,
    // 	/* In_h        = */ 28,
    // 	/* In_w        = */ 28,
    // 	/* Out_channels= */ 128,
    // 	/* Kn_h        = */ 3,
    // 	/* Kn_w        = */ 3,
    // 	/* Pad_h       = */ 1,
    // 	/* Pad_w       = */ 1,
    // 	/* Stride_h    = */ 1,
    // 	/* Stride_w    = */ 1,
    // 	/* Dila_h      = */ 1,
    // 	/* Dila_w      = */ 1
    // };

    OpConfig matMulConfig;
    matMulConfig.opType = OpType::MATMUL;
    matMulConfig.args   = {
        /* M = */ M,
        /* N = */ N,
        /* K = */ K,
        /* transa = */ 0,
        /* transb = */ 1,
        /* tenser_op = */ 0,
        /* algo   = */ -1,
        /* dtype*/ dtype
    };

    //configVector.push_back(conv2dConfig);
    configVector.push_back(matMulConfig);

    std::cout << "Test performence of Gemm\n";
    std::cout << "M=" << M << " N=" << N << " K=" << K << std::endl;
    Simulator* simu = new Simulator;
    simu->initOp(configVector);
    PfMap pfMap = simu->measureAllOp(2000);
    if (dtype == DTYPE_INT8) {
        printf("Avg time: %F ms  TOPS: %F\n", pfMap[matMulConfig].getDurtime(), pfMap[matMulConfig].getTflops());
    } else {
        printf("Avg time: %F ms  TFLOPS: %F\n", pfMap[matMulConfig].getDurtime(), pfMap[matMulConfig].getTflops());
    }
    simu->freeOp(); 
    delete simu;

    std::cout << "End of test\n";
    return 0;
}
