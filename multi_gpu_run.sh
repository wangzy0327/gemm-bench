#!/bin/bash

# 多GPU运行gemm-bench脚本
# 用法: ./multi_gpu_run.sh M N K dtype [gpu_list]
# 示例: ./multi_gpu_run.sh 2048 2048 2048 fp32 "0,1,2,3"

# 检查参数
if [ $# -lt 4 ]; then
  echo "用法: $0 M N K dtype [gpu_list]"
  echo "示例: $0 2048 2048 2048 fp32 \"0,1,2,3\""
  echo "支持的数据类型: fp64, fp32, fp16, int8"
  exit 1
fi

# 获取参数
M=$1
N=$2
K=$3
dtype=$4
gpu_list=${5:-"0,1"}  # 默认使用GPU 0和1
iter=$6

# 检查gemm-bench程序是否存在
if [ ! -f "./gemm-bench" ]; then
  echo "错误: 找不到gemm-bench程序，请先编译ROCm版本"
  echo "编译命令: make rocm"
  exit 1
fi

# 解析GPU列表
IFS=',' read -ra GPUS <<< "$gpu_list"

# 创建日志目录
mkdir -p logs

# 在后台并行运行每个GPU任务
echo "在以下GPU上并行运行gemm-bench: ${GPUS[*]}"
echo "矩阵大小: M=$M, N=$N, K=$K, 数据类型: $dtype"

for gpu in "${GPUS[@]}"; do
  export HIP_VISIBLE_DEVICES=$gpu
  export CUDA_VISIBLE_DEVICES=$gpu
  log_file="logs/gpu${gpu}.log"
  
  echo "启动GPU $gpu 任务，日志文件: $log_file"
  ./gemm-bench $M $N $K $dtype $iter> "$log_file" 2>&1 &
  
  # 保存进程ID用于后续管理
  echo $! > "logs/gpu${gpu}.pid"
done

# 等待所有后台任务完成
echo "等待所有任务完成..."
wait

echo "所有GPU任务已完成，结果保存在logs目录中"

# 显示结果摘要
for gpu in "${GPUS[@]}"; do
  log_file="logs/gpu${gpu}.log"
  if [ -f "$log_file" ]; then
    echo "=== GPU $gpu 结果 ==="
    tail -n 5 "$log_file"
    echo ""
  fi
done
