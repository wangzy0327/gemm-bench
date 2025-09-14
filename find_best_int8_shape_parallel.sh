#!/bin/bash

# 显示前N矩阵形状的变量
TOP_N=30

# 检查命令行参数
if [ $# -lt 2 ]; then
    echo "用法: $0 <num_gpus> <dtype> [sampling_interval_ms]"
    echo "示例: $0 4 int8 100"
    exit 1
fi

# 获取命令行参数
num_gpus=$1
dtype=$2
sampling_interval_ms=${3:-100}  # 默认采样间隔为100ms

# 检查gemm-bench可执行文件是否存在
if [ ! -f "./gemm-bench" ]; then
    echo "错误: 未找到gemm-bench可执行文件，请确保它在当前目录中。"
    exit 1
fi

# 创建日志目录
mkdir -p logs power_logs find_shape_logs

# 清理函数，用于处理终止信号
CLEANUP_PIDS=()
cleanup() {
    echo -e '\n收到终止信号，正在清理后台进程...'
    
    # 终止所有后台gemm-bench进程
    for pid in "${CLEANUP_PIDS[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null
            echo "已终止gemm-bench进程 (PID: $pid)"
        fi
    done
    
    # 等待所有进程终止
    for pid in "${CLEANUP_PIDS[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
            wait "$pid" 2>/dev/null
        fi
    done
    
    # 强制终止所有可能的残留监控进程
    pkill -f "power1_average" 2>/dev/null || true
    
    echo "清理完成，程序已退出。"
    exit 0
}

# 注册信号处理函数
trap cleanup SIGINT SIGTERM

# ==================== 辅助函数 ====================

# 查找传感器路径
find_sensor_path() {
    local gpu_index=$1
    local sensor_path=""
    
    # 根据DCU设备的映射关系，card编号 = gpu_index + 1
    local card_number=$((gpu_index + 1))
    local card_path="/sys/class/drm/card${card_number}"
    
    # 检查card路径是否存在
    if [ ! -d "$card_path" ]; then
        echo "警告: GPU$gpu_index对应的路径$card_path不存在" >&2
        return 1
    fi
    
    # 遍历所有可能的HWMON路径
    for hwmon in "$card_path"/device/hwmon/hwmon*; do
        if [ -d "$hwmon" ]; then
            # 查找power1_average文件
            if [ -f "$hwmon/power1_average" ]; then
                sensor_path="$hwmon/power1_average"
                break
            fi
        fi
    done
    
    echo "$sensor_path"
}

# 全局变量存储功率监控进程PID
declare -A POWER_MONITOR_PIDS
# 启动功率监控
start_power_monitor() {
    local gpu=$1
    local interval=$2
    local log_file="power_logs/gpu${gpu}_power.log"
    local sensor_path=$(find_sensor_path $gpu)
    
    # 检查传感器路径是否存在
    if [ -z "$sensor_path" ]; then
        echo "警告: 无法找到GPU$gpu的功率传感器路径"
        return 1
    fi
    
    # 启动后台监控进程
    {
        while true; do
            if [ -f "$sensor_path" ]; then
                power=$(cat "$sensor_path" 2>/dev/null)
                timestamp=$(date +%s%3N)  # 毫秒时间戳
                echo "$timestamp $power" >> "$log_file"
            fi
            sleep $(echo "scale=3; $interval/1000" | bc)  # 转换为秒
        done
    } &
    
    local monitor_pid=$!
    # 保存监控进程PID用于清理
    CLEANUP_PIDS+=($monitor_pid)
    POWER_MONITOR_PIDS["gpu$gpu"]=$monitor_pid
}

# 停止功率监控
stop_power_monitor() {
    local gpu=$1
    
    # 使用记录的PID精确终止进程
    local pid=${POWER_MONITOR_PIDS["gpu$gpu"]}
    if [ -n "$pid" ] && kill -0 $pid 2>/dev/null; then
        kill $pid 2>/dev/null
        # 从全局数组中移除
        unset POWER_MONITOR_PIDS["gpu$gpu"]
        # 从清理列表中移除
        for i in "${!CLEANUP_PIDS[@]}"; do
            if [[ "${CLEANUP_PIDS[$i]}" == "$pid" ]]; then
                unset 'CLEANUP_PIDS[$i]'
                break
            fi
        done
    fi
}

# 计算能效比
calculate_efficiency() {
    local gpu=$1
    local start_time=$2
    local end_time=$3
    local performance=$4
    local perf_unit=$5
    local sampling_interval=$6
    local log_file="power_logs/gpu${gpu}_power.log"
    
    # 检查日志文件是否存在
    if [ ! -f "$log_file" ]; then
        echo "N/A|N/A|N/A|N/A|N/A|N/A|N/A|N/A|N/A"
        return
    fi
    
    # 调整开始时间，补偿功耗传感器200ms的固定延迟
    local adjusted_start_time=$((start_time + 200))
    
    # 提取计算期间的功率数据
    power_data=$(awk -v start="$adjusted_start_time" -v end="$end_time" '$1 >= start && $1 <= end {print $2}' "$log_file")
    
    # 检查是否有功率数据
    if [ -z "$power_data" ]; then
        echo "N/A|N/A|N/A|N/A|N/A|N/A|N/A|N/A|N/A"
        return
    fi
    
    # 计算功率统计数据
    power_stats=$(echo "$power_data" | awk '{
        sum+=$1; count++;
        if (NR==1) { min=$1; max=$1 } 
        else { if($1<min) min=$1; if($1>max) max=$1 }
    } END {
        if(count>0) printf "%.2f|%.2f|%.2f|%d", min/1000000, max/1000000, sum/count/1000000, count;
        else print "N/A|N/A|N/A|0";
    }')
    
    # 解析功率统计数据
    IFS='|' read -r min_power max_power avg_power sample_count <<< "$power_stats"
    
    # 检查是否有足够的样本
    if [ "$sample_count" -eq 0 ]; then
        echo "N/A|N/A|N/A|N/A|N/A|N/A|N/A|N/A|N/A"
        return
    fi
    
    # 计算时间间隔（秒）
    time_interval=$(echo "scale=6; ($end_time - $start_time) / 1000" | bc)
    
    # 检查时间间隔是否有效
    if (( $(echo "$time_interval <= 0" | bc -l) )); then
        echo "N/A|N/A|N/A|N/A|N/A|N/A|N/A|N/A|N/A"
        return
    fi
    
    # 计算能效比
    if (( $(echo "$avg_power > 0" | bc -l) )); then
        efficiency=$(echo "scale=6; $performance / $avg_power" | bc)
    else
        efficiency="N/A"
    fi
    
    # 返回结果
    echo "$start_time|$time_interval|$sample_count|$min_power|$max_power|$avg_power|$performance|$perf_unit|$efficiency"
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
    
    # 根据新提供的基准点进行分段线性插值
    # 基准点列表（按total_elements升序排列）：
    # 1. M=1024, N=1024, K=1024, total_elements=1,073,741,824 ≈ 1.07GB, iterations=60000
    # 2. M=1024, N=1024, K=2048, total_elements=2,147,483,648 ≈ 2.15GB, iterations=50000
    # 3. M=1024, N=1024, K=2560, total_elements=2,684,354,560 ≈ 2.68GB, iterations=40000
    # 4. M=1024, N=1024, K=4096, total_elements=4,294,967,296 ≈ 4.29GB, iterations=32000
    # 5. M=2048, N=2048, K=4096, total_elements=17,179,869,184 ≈ 17.2GB, iterations=30000
    # 6. M=2048, N=2048, K=8192, total_elements=34,359,738,368 ≈ 34.4GB, iterations=20000
    # 7. M=2048, N=2560, K=8192, total_elements=42,949,672,960 ≈ 42.9GB, iterations=19000
    # 8. M=2560, N=2560, K=8192, total_elements=53,687,091,200 ≈ 53.7GB, iterations=12000
    # 9. M=2048, N=2560, K=16384, total_elements=85,899,345,920 ≈ 85.9GB, iterations=10000
    # 10. M=2048, N=5120, K=9216, total_elements=96,636,764,160 ≈ 96.6GB, iterations=8000
    # 11. M=2048, N=10240, K=10240, total_elements=214,748,364,800 ≈ 214.7GB, iterations=4500
    # 12. M=2048, N=5120, K=65536, total_elements=687,194,767,360 ≈ 687.2GB, iterations=1500
    # 13. M=4096, N=5120, K=65536, total_elements=1,374,389,534,720 ≈ 1374.4GB, iterations=900
    # 14. M=4096, N=4096, K=131072, total_elements=2,199,023,255,552 ≈ 2199.0GB, iterations=470
    # 15. M=6144, N=6144, K=65536, total_elements=2,471,321,649,152 ≈ 2471.3GB, iterations=440
    # 16. M=5120, N=5120, K=131072, total_elements=3,435,973,836,800 ≈ 3436.0GB, iterations=380
    # 17. M=8192, N=10240, K=131072, total_elements=10,995,116,277,760 ≈ 10995.1GB, iterations=80
    # 18. M=10240, N=10240, K=131072, total_elements=13,743,895,347,200 ≈ 13743.9GB, iterations=60
    
    # 定义基准点数组（total_elements, iterations）
    local -a benchmarks=(
        "1073741824 60000"
        "2147483648 50000"
        "2684354560 40000"
        "4294967296 32000"
        "17179869184 30000"
        "34359738368 20000"
        "42949672960 19000"
        "53687091200 12000"
        "85899345920 10000"
        "96636764160 8000"
        "214748364800 4500"
        "687194767360 1500"
        "1374389534720 900"
        "2199023255552 470"
        "2471321649152 440"
        "3435973836800 380"
        "10995116277760 80"
        "13743895347200 60"
    )
    
    # 如果小于最小基准点，使用最大迭代次数
    if [ $total_elements -le 1073741824 ]; then
        echo 60000
        return
    fi
    
    # 如果大于最大基准点，使用最小迭代次数
    if [ $total_elements -ge 13743895347200 ]; then
        echo 60
        return
    fi
    
    # 在基准点之间进行线性插值
    for i in {1..17}; do
        local prev_benchmark=(${benchmarks[$((i-1))]})
        local next_benchmark=(${benchmarks[$i]})
        
        local prev_elements=${prev_benchmark[0]}
        local prev_iter=${prev_benchmark[1]}
        local next_elements=${next_benchmark[0]}
        local next_iter=${next_benchmark[1]}
        
        if [ $total_elements -ge $prev_elements ] && [ $total_elements -le $next_elements ]; then
            # 线性插值公式: iterations = prev_iter + (next_iter - prev_iter) * (total_elements - prev_elements) / (next_elements - prev_elements)
            local diff_elements=$((total_elements - prev_elements))
            local range_elements=$((next_elements - prev_elements))
            local diff_iter=$((next_iter - prev_iter))
            
            # 使用bc进行浮点计算
            local iterations=$(echo "scale=0; $prev_iter + ($diff_elements * $diff_iter) / $range_elements" | bc)
            
            # 确保迭代次数至少为1
            if [ $iterations -lt 1 ]; then
                iterations=1
            fi
            
            echo $iterations
            return
        fi
    done
    
    # 默认情况下返回一个合理的值
    echo 1000
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

# 显示当前排名前N的结果
function display_top_results() {
    # 检查是否有结果要显示
    if [ ${#all_results[@]} -eq 0 ]; then
        echo "当前排名前$TOP_N的形状: 无结果"
        echo ""
        return
    fi
    
    echo "当前排名前$TOP_N的形状:"
    printf "%-4s %-6s %-8s %-8s %-8s %-12s %-12s %-12s %-12s %-12s %-12s\n" "Rank" "GPU" "M" "N" "K" "Iterations" "Performance" "Min Power" "Avg Power" "Max Power" "Efficiency"
    printf "%.0s-" {1..120}
    echo ""
    
    # 将结果排序并显示前N个，添加排名序号
    local rank=1
    printf '%s\n' "${all_results[@]}" | sort -t'|' -k8 -nr | head -$TOP_N | while IFS='|' read -r gpu M N K iter perf perf_unit eff time interval samples min_p max_p avg_p; do
        # 确保不显示无效结果
        if [ "$perf_unit" != "UNKNOWN" ] && [ "$eff" != "N/A" ] && [[ -n "$perf" ]] && [[ -n "$eff" ]]; then
            printf "%-4s %-6s %-8s %-8s %-8s %-12s %-12s %-12s %-12s %-12s %-12s\n" "$rank" "GPU$gpu" "$M" "$N" "$K" "$iter" "$perf $perf_unit" "$min_p W" "$avg_p W" "$max_p W" "$eff TOPS/W"
            rank=$((rank + 1))
        fi
    done
    echo ""
}

# 在日志中显示当前排名前N的结果
function display_top_results_for_log() {
    # 检查是否有结果要显示
    if [ ${#all_results[@]} -eq 0 ]; then
        echo "当前排名前$TOP_N的形状: 无结果"
        echo ""
        return
    fi
    
    echo "当前排名前$TOP_N的形状:"
    printf "%-4s %-6s %-8s %-8s %-8s %-12s %-12s %-12s %-12s %-12s %-12s\n" "Rank" "GPU" "M" "N" "K" "Iterations" "Performance" "Min Power" "Avg Power" "Max Power" "Efficiency"
    printf "%.0s-" {1..120}
    echo ""
    
    # 将结果排序并显示前N个，添加排名序号
    local rank=1
    printf '%s\n' "${all_results[@]}" | sort -t'|' -k8 -nr | head -$TOP_N | while IFS='|' read -r gpu M N K iter perf perf_unit eff time interval samples min_p max_p avg_p; do
        # 确保不显示无效结果
        if [ "$perf_unit" != "UNKNOWN" ] && [ "$eff" != "N/A" ] && [[ -n "$perf" ]] && [[ -n "$eff" ]]; then
            printf "%-4s %-6s %-8s %-8s %-8s %-12s %-12s %-12s %-12s %-12s %-12s\n" "$rank" "GPU$gpu" "$M" "$N" "$K" "$iter" "$perf $perf_unit" "$min_p W" "$avg_p W" "$max_p W" "$eff TOPS/W"
            rank=$((rank + 1))
        fi
    done
    echo ""
}

# ==================== 新增功能：矩阵形状搜索空间 ====================

# 生成搜索空间值
generate_values() {
    local start=$1
    local end=$2
    local step=$3
    local values=()
    
    for ((i=start; i<=end; i+=step)); do
        values+=($i)
    done
    
    echo "${values[@]}"
}

# 生成所有形状组合
generate_shape_combinations() {
    local shapes=()
    local M_VALUES=($(generate_values 1024 10240 1024))
    local N_VALUES=($(generate_values 1024 10240 1024))
    # K值范围保持到131072，步长为2048（512的偶数倍）
    local K_VALUES=($(generate_values 2048 131072 2048))

    # 13800 GB转换为字节的限制
    local MAX_SIZE_BYTES=14817637171200
    
    for M in "${M_VALUES[@]}"; do
        for N in "${N_VALUES[@]}"; do
            # 计算M和N中的较大值和较小值
            local max_mn=$((M > N ? M : N))
            local min_mn=$((M < N ? M : N))
            # 计算K的最大允许值（较小值的64倍，但不超过131072）
            local max_k_allowed=$((min_mn * 64))
            if [ $max_k_allowed -gt 131072 ]; then
                max_k_allowed=131072
            fi
            
            for K in "${K_VALUES[@]}"; do
                # 检查K是否满足所有条件
                if [ $K -ge $max_mn ] && [ $K -le $max_k_allowed ]; then
                    # 检查总大小是否小于13800 GB
                    local total_size=$((M * N * K))
                    if [ $total_size -le $MAX_SIZE_BYTES ]; then
                        shapes+=("$M,$N,$K")
                    fi
                fi
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

# 添加轮次计数器
round_count=0

# 添加累积输出变量
accumulated_output=""

# 并行测试循环
current_index=0
while [ $current_index -lt $total_shapes ]; do
    # 增加轮次计数
    round_count=$((round_count + 1))
    
    # 打印轮次序号
    round_output="第 $round_count 轮计算开始"
    echo "$round_output"
    
    # 将本轮输出添加到累积输出中
    accumulated_output+="$round_output\n"
    
    # 随机选择GPU
    GPUS=($(select_random_gpus $num_gpus))
    
    gpu_output="本轮使用的GPU: ${GPUS[@]}"
    echo "$gpu_output"
    
    # 将GPU信息添加到累积输出中
    accumulated_output+="$gpu_output\n"
    
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
            
            test_output="GPU$gpu 测试形状: M=$M, N=$N, K=$K, 迭代次数: $ITERATIONS"
            echo "$test_output"
            
            # 将测试信息添加到累积输出中
            accumulated_output+="$test_output\n"
            
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

    # 停止本轮GPU的功率监控进程
    for gpu in "${GPUS[@]}"; do
        stop_power_monitor $gpu
    done

    # 显示当前最优结果
    current_best_output="当前批次测试完成，当前最优结果:\n  最佳能效: $best_efficiency TOPS/W\n  最佳形状: $best_shape\n  测试GPU: $best_gpu"
    echo -e "$current_best_output"

    # 显示进度
    progress=$(echo "scale=2; $current_index * 100 / $total_shapes" | bc)
    progress_output="进度: $current_index/$total_shapes ($progress%)"
    echo "$progress_output"

    # 显示当前排名前N的结果
    display_top_results

    # 获取当前排名前N的结果用于日志记录
    top_results_output=$(display_top_results_for_log)

    # 将当前最优结果、进度信息和排名前N的结果添加到累积输出中
    accumulated_output+="$current_best_output\n"
    accumulated_output+="$progress_output\n"
    accumulated_output+="$top_results_output\n"
    accumulated_output+="$(printf '%.0s=' {1..100})\n"

    print_separator
    
    # 每隔5轮将累积的输出写入日志文件
    if [ $((round_count % 5)) -eq 0 ] || [ $current_index -ge $total_shapes ]; then
        # 创建日志文件名，包含轮次范围和时间戳
        start_round=$((round_count - 4))
        if [ $start_round -lt 1 ]; then
            start_round=1
        fi
        log_filename="find_shape_logs/round_${start_round}_${round_count}_$(date +%Y%m%d_%H%M%S).log"
        
        # 将累积的输出写入日志文件
        echo -e "$accumulated_output" > "$log_filename"
        
        echo "最近5轮的输出已写入日志文件: $log_filename"
        
        # 清空累积输出
        accumulated_output=""
    fi
    
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

# 输出排名前N的结果
echo "排名前$TOP_N的形状:"
printf "%-6s %-8s %-8s %-8s %-12s %-12s %-12s %-12s %-12s\n" "GPU" "M" "N" "K" "Iterations" "Performance" "Min Power" "Max Power" "Efficiency"
printf "%.0s-" {1..100}
echo ""

for result in "${all_results[@]}"; do
    echo "$result"
done | sort -t'|' -k9 -nr | head -$TOP_N | while IFS='|' read gpu M N K iter perf perf_unit eff time interval samples min_p max_p avg_p; do
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
