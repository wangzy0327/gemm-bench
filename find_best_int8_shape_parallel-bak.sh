#!/bin/bash

# ==================== 参数处理 ====================

# 检查参数
if [ $# -ne 1 ]; then
  echo "用法: $0 <GPU数量>"
  exit 1
fi

num_gpus=$1
sampling_interval_ms=100  # 功率采样间隔(毫秒)
dtype="int8"  # 固定为int8数据类型

# 检查gemm-bench程序是否存在
if [ ! -f "./gemm-bench" ]; then
  echo "错误: 找不到gemm-bench程序，请先编译ROCm版本"
  echo "编译命令: make rocm"
  exit 1
fi

# 创建日志目录
mkdir -p logs
mkdir -p power_logs

# ==================== 从eff_cal_format.sh复用的核心函数 ====================

# 查找特定DCU的功率传感器路径
find_sensor_path() {
    local gpu_index=$1
    
    local card_number=$((gpu_index + 1))
    local card_path="/sys/class/drm/card${card_number}"
    
    if [[ ! -d "$card_path" ]]; then
        echo "错误: DCU$gpu_index对应的路径$card_path不存在" >&2
        return 1
    fi
    
    for hwmon in "$card_path"/device/hwmon/hwmon*; do
        if [[ -f "$hwmon/power1_average" ]]; then
            echo "$hwmon/power1_average"
            return 0
        fi
    done
    
    echo "错误: 在DCU$gpu_index对应的路径$card_path上未找到功率传感器" >&2
    return 1
}

# 启动功率监控函数（修改后版本）
start_power_monitor() {
    local gpu_index=$1
    local sampling_interval=$2
    local monitor_pid_file="power_logs/gpu${gpu_index}_monitor.pid"
    local power_log_file="power_logs/gpu${gpu_index}_power.log"
    
    if ! SENSOR_PATH=$(find_sensor_path $gpu_index); then
        echo "警告: 无法监控GPU $gpu_index 的功率"
        return 1
    fi
    
    local sleep_interval=$(echo "scale=3; $sampling_interval / 1000" | bc)
    
    (
        echo "监控的DCU索引: $gpu_index"
        echo "传感器路径: $SENSOR_PATH"
        echo "采样间隔: ${sampling_interval}ms"
        echo "时间戳(ms),功率(W)"
        
        while true; do
            current_time=$(date +%s%3N)
            power_mw=$(cat "$SENSOR_PATH" 2>/dev/null)
            if [[ $power_mw =~ ^[0-9]+$ ]]; then
                power_w=$(echo "scale=2; $power_mw / 1000000" | bc)
            else
                power_w="N/A"
            fi
            echo "$current_time,$power_w"
            sleep $sleep_interval
        done
    ) > "$power_log_file" 2>/dev/null &
    
    local monitor_pid=$!
    echo $monitor_pid > "$monitor_pid_file"
    
    # 记录监控进程PID用于清理
    CLEANUP_PIDS+=($monitor_pid)
}

# 停止功率监控函数
stop_power_monitor() {
    local gpu_index=$1
    local monitor_pid_file="power_logs/gpu${gpu_index}_monitor.pid"
    
    if [ -f "$monitor_pid_file" ]; then
        monitor_pid=$(cat "$monitor_pid_file")
        if kill -0 "$monitor_pid" 2>/dev/null; then
            kill "$monitor_pid"
        fi
        rm -f "$monitor_pid_file"
    fi
}

# 分析功率数据并计算能效比
calculate_efficiency() {
    local gpu_index=$1
    local start_time=$2
    local end_time=$3
    local performance_value=$4
    local performance_unit=$5
    local sampling_interval=$6
    local power_log_file="power_logs/gpu${gpu_index}_power.log"
    
    local efficiency_unit="${performance_unit}/W"
    
    if [ ! -f "$power_log_file" ]; then
        echo "错误: 找不到GPU $gpu_index 的功率日志文件"
        return
    fi
    
    total_time=$((end_time - start_time))
    total_power=0
    valid_samples=0
    min_power=999999.0  # 修改为浮点数
    max_power=0.0       # 明确设置为浮点数
    
    while IFS=',' read -r timestamp power_w; do
        if [[ "$timestamp" =~ ^[0-9]+$ ]] && [[ "$power_w" =~ ^[0-9.]+$ ]]; then
            if (( timestamp >= start_time && timestamp <= end_time )); then
                total_power=$(echo "$total_power + $power_w" | bc)
                
                # 使用bc进行浮点数比较
                if (( $(echo "$power_w < $min_power" | bc -l) )); then
                    min_power=$power_w
                fi
                
                if (( $(echo "$power_w > $max_power" | bc -l) )); then
                    max_power=$power_w
                fi
                
                ((valid_samples++))
            fi
        fi
    done < "$power_log_file"
    
    if ((valid_samples > 0)); then
        avg_power=$(echo "scale=3; $total_power / $valid_samples" | bc)
        
        # 确保功率值格式正确
        min_power=$(printf "%.3f" "$min_power")
        max_power=$(printf "%.3f" "$max_power")
        avg_power=$(printf "%.3f" "$avg_power")
        
        if (( $(echo "$avg_power > 0" | bc -l) )); then
            efficiency=$(echo "scale=3; $performance_value / $avg_power" | bc)
            echo "$total_time|$sampling_interval|$valid_samples|$min_power|$max_power|$avg_power|$performance_value|$performance_unit|$efficiency|$efficiency_unit"
        else
            echo "$total_time|$sampling_interval|$valid_samples|$min_power|$max_power|$avg_power|$performance_value|$performance_unit|N/A|N/A"
        fi
    else
        echo "$total_time|$sampling_interval|0|N/A|N/A|N/A|$performance_value|$performance_unit|N/A|N/A"
    fi
}

# 打印分隔线
print_separator() {
    echo "=========================================================================================================="
}

# 打印标题
print_title() {
    print_separator
    echo "                                         并行最佳能效矩阵形状搜索"
    print_separator
}

# 根据矩阵大小动态计算迭代次数
calculate_iterations() {
    local M=$1
    local N=$2
    local K=$3
    
    local total_elements=$((M * N * K))
    
    # 根据您提供的三个基准点进行分段线性插值
    # 1. M=2048, N=2560, K=16384, total_elements=85,899,345,920 ≈ 85.9GB, iterations=50000
    # 2. M=2048, N=5120, K=65536, total_elements=687,194,767,360 ≈ 687.2GB, iterations=2400
    # 3. M=4096, N=5120, K=131072, total_elements=2,748,779,069,440 ≈ 2748.8GB, iterations=600
    
    if [ $total_elements -le 85899345920 ]; then         # <= 85.9GB
        echo 50000
    elif [ $total_elements -le 687194767360 ]; then      # 85.9GB - 687.2GB
        # 线性插值计算: iterations = 50000 - ((total_elements - 85899345920) * (50000 - 2400)) / (687194767360 - 85899345920)
        local diff_elements=$((total_elements - 85899345920))
        local range_elements=$((687194767360 - 85899345920))
        local diff_iterations=$((50000 - 2400))
        local iterations=$(echo "50000 - ($diff_elements * $diff_iterations) / $range_elements" | bc)
        echo $iterations
    elif [ $total_elements -le 2748779069440 ]; then     # 687.2GB - 2748.8GB
        # 线性插值计算: iterations = 2400 - ((total_elements - 687194767360) * (2400 - 600)) / (2748779069440 - 687194767360)
        local diff_elements=$((total_elements - 687194767360))
        local range_elements=$((2748779069440 - 687194767360))
        local diff_iterations=$((2400 - 600))
        local iterations=$(echo "2400 - ($diff_elements * $diff_iterations) / $range_elements" | bc)
        echo $iterations
    else                                                 # > 2748.8GB
        echo 600
    fi
}

# 随机选择GPU
select_random_gpus() {
    local num_needed=$1
    local available_gpus=(0 1 2 3 4 5 6 7)  # 假设最多8个GPU
    local selected_gpus=()
    
    # Fisher-Yates洗牌算法
    for ((i=0; i<${#available_gpus[@]}; i++)); do
        local j=$((i + RANDOM % (${#available_gpus[@]} - i)))
        # 交换元素
        local temp=${available_gpus[i]}
        available_gpus[i]=${available_gpus[j]}
        available_gpus[j]=$temp
    done
    
    # 选择前num_needed个GPU
    for ((i=0; i<num_needed && i<${#available_gpus[@]}; i++)); do
        selected_gpus+=(${available_gpus[i]})
    done
    
    echo "${selected_gpus[@]}"
}

# 显示当前排名前5的结果
display_top5_results() {
    # 检查是否有结果要显示
    if [ ${#all_results[@]} -eq 0 ]; then
        echo "当前排名前5的形状: 无结果"
        echo ""
        return
    fi
    
    echo "当前排名前5的形状:"
    printf "%-6s %-8s %-8s %-8s %-12s %-12s %-12s %-12s %-12s %-12s\n" "GPU" "M" "N" "K" "Iterations" "Performance" "Min Power" "Avg Power" "Max Power" "Efficiency"
    printf "%.0s-" {1..110}; echo ""
    
    # 将结果排序并显示前5个
    printf '%s\n' "${all_results[@]}" | sort -t'|' -k8 -nr | head -5 | while IFS='|' read -r gpu M N K iter perf perf_unit eff time interval samples min_p max_p avg_p; do
        # 确保不显示无效结果
        if [ "$perf_unit" != "UNKNOWN" ] && [ "$eff" != "N/A" ] && [[ -n "$perf" ]] && [[ -n "$eff" ]]; then
            printf "%-6s %-8s %-8s %-8s %-12s %-12s %-12s %-12s %-12s %-12s\n" "GPU$gpu" "$M" "$N" "$K" "$iter" "$perf $perf_unit" "$min_p W" "$avg_p W" "$max_p W" "$eff TOPS/W"
        fi
    done
    echo ""
}

# ==================== 新增功能：矩阵形状搜索空间 ====================

# 搜索空间定义（基于您的建议）
M_VALUES=(1024 2048 3072 4096 5120 6144 7168 8192)
N_VALUES=(1024 2048 3072 4096 5120 6144 7168 8192 9216 10240)
K_VALUES=(1024 2048 4096 8192 16384 32768 65536 98304 131072)

# 生成所有形状组合
generate_shape_combinations() {
    local shapes=()
    for M in "${M_VALUES[@]}"; do
        for N in "${N_VALUES[@]}"; do
            for K in "${K_VALUES[@]}"; do
                shapes+=("$M,$N,$K")
            done
        done
    done
    echo "${shapes[@]}"
}

# ==================== 主执行流程 ====================

print_title

# 打印测试配置信息
echo "测试配置:"
echo "  - 数据类型: $dtype"
echo "  - 使用GPU数量: $num_gpus"
echo "  - GPU功率采样间隔: ${sampling_interval_ms} ms"
print_separator

# 生成所有形状组合
SHAPE_COMBINATIONS=($(generate_shape_combinations))
total_shapes=${#SHAPE_COMBINATIONS[@]}

echo "总共需要测试 $total_shapes 种矩阵形状组合"
print_separator

# 最佳结果记录
best_efficiency=0
best_shape=""
best_gpu=""
all_results=()

# 并行测试循环
current_index=0
while [ $current_index -lt $total_shapes ]; do
    # 随机选择GPU
    GPUS=($(select_random_gpus $num_gpus))
    
    echo "本轮使用的GPU: ${GPUS[@]}"
    
    # 启动本轮GPU的功率监控
    for gpu in "${GPUS[@]}"; do
        start_power_monitor $gpu $sampling_interval_ms
        sleep 1
    done
    
    # 为每个可用GPU分配一个形状测试任务
    gemm_pids=()
    shape_info=()
    
    for gpu in "${GPUS[@]}"; do
        if [ $current_index -lt $total_shapes ]; then
            shape="${SHAPE_COMBINATIONS[$current_index]}"
            IFS=',' read -r M N K <<< "$shape"
            
            # 计算动态迭代次数
            ITERATIONS=$(calculate_iterations $M $N $K)
            
            echo "GPU$gpu 测试形状: M=$M, N=$N, K=$K, 迭代次数: $ITERATIONS"
            
            # 设置GPU环境变量
            export HIP_VISIBLE_DEVICES=$gpu
            export CUDA_VISIBLE_DEVICES=$gpu
            log_file="logs/gpu${gpu}_shape_${M}_${N}_${K}.log"
            
            # 后台运行gemm-bench测试
            ./gemm-bench $M $N $K $dtype $ITERATIONS > "$log_file" 2>&1 &
            gemm_pid=$!
            gemm_pids+=($gemm_pid)
            shape_info+=("$gpu|$M|$N|$K|$ITERATIONS|$log_file")
            
            # 记录gemm进程PID用于清理
            CLEANUP_PIDS+=($gemm_pid)
            
            ((current_index++))
        fi
    done
    
    # 等待当前批次的所有测试完成
    for pid in "${gemm_pids[@]}"; do
        wait $pid
        
        # 从清理列表中移除已完成的进程
        for i in "${!CLEANUP_PIDS[@]}"; do
            if [[ "${CLEANUP_PIDS[$i]}" == "$pid" ]]; then
                unset 'CLEANUP_PIDS[$i]'
                break
            fi
        done
    done
    
    # 处理当前批次的测试结果
    for shape_data in "${shape_info[@]}"; do
        IFS='|' read -r gpu M N K iterations log_file <<< "$shape_data"
        
        # 检查日志文件是否存在
        if [ -f "$log_file" ]; then
            # 提取计算开始/结束时间戳
            compute_start_time=$(grep "计算开始毫秒时间戳:" "$log_file" | awk '{print $2}')
            compute_end_time=$(grep "计算结束毫秒时间戳:" "$log_file" | awk '{print $2}')
            
            # 提取计算性能结果
            if grep -q "TOPS:" "$log_file"; then
                performance_value=$(grep "TOPS:" "$log_file" | awk '{print $NF}')
                performance_unit="TOPS"
            else
                performance_value=0
                performance_unit="UNKNOWN"
            fi
            
            if [[ -n "$compute_start_time" && -n "$compute_end_time" && -n "$performance_value" ]]; then
                # 计算能效比
                result=$(calculate_efficiency $gpu $compute_start_time $compute_end_time $performance_value "$performance_unit" $sampling_interval_ms)
                
                # 提取能效值和其他信息
                IFS='|' read -ra eff_data <<< "$result"
                time=${eff_data[0]}
                interval=${eff_data[1]}
                samples=${eff_data[2]}
                min_power=${eff_data[3]}
                max_power=${eff_data[4]}
                avg_power=${eff_data[5]}
                perf_value=${eff_data[6]}
                perf_unit=${eff_data[7]}
                efficiency=${eff_data[8]}
                
                # 记录结果
                all_results+=("$gpu|$M|$N|$K|$iterations|$perf_value|$perf_unit|$efficiency|$time|$interval|$samples|$min_power|$max_power|$avg_power")
                
                # 更新最佳结果
                if [[ "$efficiency" != "N/A" ]] && (( $(echo "$efficiency > $best_efficiency" | bc -l) )); then
                    best_efficiency=$efficiency
                    best_shape="M=$M, N=$N, K=$K"
                    best_gpu="GPU$gpu"
                fi
                
                # 删除处理过的日志文件
                rm -f "$log_file"
            fi
        fi
    done
    
    # 显示当前排名前5的结果
    display_top5_results
    
    # 显示当前最优结果
    echo "当前批次测试完成，当前最优结果:"
    echo "  最佳能效: $best_efficiency TOPS/W"
    echo "  最佳形状: $best_shape"
    echo "  测试GPU: $best_gpu"
    
    # 显示进度
    progress=$(echo "scale=2; $current_index * 100 / $total_shapes" | bc)
    echo "进度: $current_index/$total_shapes ($progress%)"
    print_separator
    
    # 停止本轮GPU的功率监控
    for gpu in "${GPUS[@]}"; do
        stop_power_monitor $gpu
        # 清理本轮的功率日志文件
        rm -f "power_logs/gpu${gpu}_power.log"
        sleep 1
    done
    
    # 确保所有GPU完成后再开始新一轮计算
done

# ==================== 结果输出 ====================

print_separator
echo "                                    搜索完成!"
print_separator

# 输出最佳结果
echo "最佳能效形状: $best_shape"
echo "最佳能效: $best_efficiency TOPS/W"
echo "测试GPU: $best_gpu"
print_separator

# 输出排名前10的结果
echo "排名前10的形状:"
printf "%-6s %-8s %-8s %-8s %-12s %-12s %-12s %-12s %-12s\n" "GPU" "M" "N" "K" "Iterations" "Performance" "Min Power" "Max Power" "Efficiency"
printf "%.0s-" {1..100}; echo ""

for result in "${all_results[@]}"; do
    echo "$result"
done | sort -t'|' -k8 -nr | head -10 | while IFS='|' read gpu M N K iter perf perf_unit eff time interval samples min_p max_p avg_p; do
    printf "%-6s %-8s %-8s %-8s %-12s %-12s %-12s %-12s %-12s\n" "GPU$gpu" "$M" "$N" "$K" "$iter" "$perf $perf_unit" "$min_p W" "$max_p W" "$eff TOPS/W"
done

print_separator

# 输出统计信息
echo "测试完成时间: $(TZ='Asia/Shanghai' date '+%Y-%m-%d %H:%M:%S %Z')"
echo "日志文件位置: ~/codes/gemm-bench/blas/logs/ 和 ~/codes/gemm-bench/blas/power_logs/ 目录"
print_separator

# 强制终止所有可能的残留监控进程
pkill -f "power1_average" 2>/dev/null || true

# 保存所有结果到文件
results_file="best_int8_shapes_$(date +%Y%m%d_%H%M%S).csv"
echo "GPU,M,N,K,Iterations,Performance,Performance_Unit,Efficiency,Time,Interval,Samples,Min_Power,Max_Power,Avg_Power" > "$results_file"
for result in "${all_results[@]}"; do
    echo "$result" | tr '|' ',' >> "$results_file"
done

echo "详细结果已保存到: $results_file"