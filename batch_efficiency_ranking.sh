#!/bin/bash

# 批量矩阵形状能效比排名脚本
# 用法: ./batch_efficiency_ranking.sh [iterations] [dtype] [gpu_list] [sampling_interval_ms]
# 示例: ./batch_efficiency_ranking.sh 10000 int8 "0,1,2,3,4,5,6,7" 500

# 默认参数
ITERATIONS=${1:-10000}
DTYPE=${2:-int8}
GPU_LIST=${3:-"0,1,2,3,4,5,6,7"}
SAMPLING_INTERVAL=${4:-500}

# 输入文件和输出文件
INPUT_FILE="test_gemm.txt"
OUTPUT_FILE="gemm_efficiency_ranking_$(date +%Y%m%d_%H%M%S).csv"
TEMP_RESULTS="temp_efficiency_results.txt"

# 检查输入文件是否存在
if [ ! -f "$INPUT_FILE" ]; then
    echo "错误: 找不到输入文件 $INPUT_FILE"
    exit 1
fi

# 检查system_power_efficiency.sh是否存在
if [ ! -f "system_power_efficiency.sh" ]; then
    echo "错误: 找不到system_power_efficiency.sh脚本"
    exit 1
fi

# 创建输出目录
mkdir -p batch_results

echo "开始批量测试矩阵形状能效比..."
echo "参数配置:"
echo "  - 迭代次数: $ITERATIONS"
echo "  - 数据类型: $DTYPE"
echo "  - GPU列表: $GPU_LIST"
echo "  - 采样间隔: ${SAMPLING_INTERVAL}ms"
echo "  - 输入文件: $INPUT_FILE"
echo "  - 输出文件: batch_results/$OUTPUT_FILE"
echo "========================================================================"

# 清空临时结果文件
> "$TEMP_RESULTS"

# 计数器
total_shapes=$(wc -l < "$INPUT_FILE")
current_shape=0

# 读取并处理每个矩阵形状
while IFS=$'\t' read -r M N K; do
    # 跳过空行
    if [[ -z "$M" || -z "$N" || -z "$K" ]]; then
        continue
    fi
    
    ((current_shape++))
    echo "[$current_shape/$total_shapes] 测试矩阵形状: M=$M, N=$N, K=$K"
    
    # 运行system_power_efficiency.sh并捕获输出
    output=$(./system_power_efficiency.sh "$M" "$N" "$K" "$ITERATIONS" "$DTYPE" "$GPU_LIST" "$SAMPLING_INTERVAL" 2>&1)
    
    # 从输出中提取关键信息
    efficiency=$(echo "$output" | grep "整机能效比:" | awk '{print $2}')
    total_performance=$(echo "$output" | grep "整机计算性能:" | awk '{print $2}')
    performance_unit=$(echo "$output" | grep "整机计算性能:" | awk '{print $3}')
    calc_power=$(echo "$output" | grep "整机计算功率:" | awk '{print $2}')
    
    # 如果提取失败，使用N/A
    if [[ -z "$efficiency" ]]; then
        efficiency="N/A"
    fi
    if [[ -z "$total_performance" ]]; then
        total_performance="N/A"
        performance_unit="N/A"
    fi
    if [[ -z "$calc_power" ]]; then
        calc_power="N/A"
    fi
    
    # 将结果写入临时文件
    echo "$M|$N|$K|$total_performance|$performance_unit|$calc_power|$efficiency" >> "$TEMP_RESULTS"
    
    echo "  结果: 性能=$total_performance $performance_unit, 功率=$calc_power W, 能效比=$efficiency ${performance_unit}/W"
    echo "------------------------------------------------------------------------"
    
    # 添加短暂延迟，避免系统负载过高
    sleep 2
    
done < "$INPUT_FILE"

# 对结果进行排序（按能效比从高到低）
echo "正在对结果进行排序..."
# 首先处理N/A值，将它们放在最后
awk -F'|' '{
    if ($7 == "N/A") {
        efficiency = -999999
    } else {
        efficiency = $7 + 0
    }
    print efficiency "|" $0
}' "$TEMP_RESULTS" | sort -t'|' -k1,1nr | cut -d'|' -f2- > "sorted_results.txt"

# 生成最终的排名CSV文件
echo "生成排名文件..."
echo "排名,矩阵M,矩阵N,矩阵K,计算性能,性能单位,整机功耗(W),整机能效比(性能单位/W)" > "batch_results/$OUTPUT_FILE"

rank=1
while IFS='|' read -r M N K total_performance performance_unit calc_power efficiency; do
    if [[ "$efficiency" != "N/A" ]]; then
        printf "%d,%d,%d,%d,%.2f,%s,%.2f,%.3f\n" \
            "$rank" "$M" "$N" "$K" "$total_performance" "$performance_unit" "$calc_power" "$efficiency" >> "batch_results/$OUTPUT_FILE"
        ((rank++))
    else
        # 将N/A结果放在最后 - 修复printf格式问题
        printf "%s,%d,%d,%d,%s,%s,%s,%s\n" \
            "N/A" "$M" "$N" "$K" "$total_performance" "$performance_unit" "$calc_power" "$efficiency" >> "batch_results/$OUTPUT_FILE"
    fi
done < "sorted_results.txt"

# 清理临时文件
rm -f "$TEMP_RESULTS" "sorted_results.txt"

echo "========================================================================"
echo "批量测试完成!"
echo "结果已保存到: batch_results/$OUTPUT_FILE"
echo "总共测试了 $total_shapes 个矩阵形状"
echo "有效结果: $((rank-1)) 个"
echo "无效结果(N/A): $((total_shapes - rank + 1)) 个"

# 显示前10名结果
echo ""
echo "能效比排名前10的矩阵形状:"
echo "排名 |    矩阵形状    | 计算性能 | 功耗(W) | 能效比"
echo "-----+----------------+----------+---------+---------"
# 跳过CSV文件的表头行，只显示数据行
tail -n +2 "batch_results/$OUTPUT_FILE" | head -10 | while IFS=',' read -r rank M N K perf unit power efficiency; do
    if [[ "$rank" != "N/A" ]]; then
        shape="(${M}x${N}x${K})"
        printf "%-4s | %-12s | %8s | %7s | %7.3f\n" \
            "$rank" "$shape" "$perf" "$power" "$efficiency"
    else
        # 处理N/A排名的情况
        printf "%-4s | %-12s | %8s | %7s | %7s\n" \
            "$rank" "(${M}x${N}x${K})" "$perf" "$power" "$efficiency"
    fi
done