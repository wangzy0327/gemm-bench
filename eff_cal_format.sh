#!/bin/bash

# 多GPU性能测试与功率监控脚本
# 用法: ./multi_gpu_power_efficiency.sh M极 N K dtype [gpu_list] [sampling_interval_ms] [iterations]
# 示例: ./multi_gpu_power_efficiency.sh 2048 204极 2048 fp32 "0,1,2,3" 100 2000

# 检查参数
if [ $# -lt 4 ]; then
  echo "用法: $0 M N K dtype [gpu_list] [sampling_interval_ms] [iterations]"
  echo "示例: $0 2048 2048 2048 fp32 \"0,1,2,3\" 100 2000"
  echo "支持的数据类型: fp64, fp32, fp16, int8"
  echo "采样间隔默认值: 100ms"
  echo "迭代次数默认值: 2000"
  exit 1
fi

# 获取参数
M=$1
N=$2
K=$3
dtype=$4
gpu_list=${5:-"0,1"}  # 默认使用GPU 0和1
sampling_interval_ms=${6:-100}  # 默认100ms采样间隔
iterations=${7:-2000}  # 默认2000次迭代

# 检查gemm-bench程序是否存在
if [ ! -f "./gemm-bench" ]; then
  echo "错误: 找不到gemm-bench程序，请先编译ROCm版本"
  echo "编译极令: make rocm"
  exit 1
fi

# 解析GPU列表
IFS=',' read -ra GPUS <<< "$gpu_list"

# 创建日志目录
mkdir -p logs
mkdir -p power_logs

# 查找特定DCU的功率传感器路径
find_sensor_path() {
    local gpu_index=$1
    
    # 根据用户提供的信息，card1对应DCU0，card2对应DCU1，以此类推
    # 所以card编号 = gpu_index + 1
    local card_number=$((gpu_index + 1))
    local card_path="/sys/class/drm/card${card_number}"
    
    # 检查card路径是否存在
    if [[ ! -d "$card_path" ]]; then
        echo "错误: DCU$gpu_index对应的路径$card_path不存在" >&2
        return 1
    fi
    
    # 查找该卡下的hwmon目录
    for hwmon in "$card_path"/device/hwmon/hwmon*; do
        if [[ -f "$hwmon/power1_average" ]]; then
            echo "$hwmon/power1_average"
            return 0
        fi
    done
    
    echo "错误: 在DCU$gpu_index对应的路径$card_path上未找到功率传感器" >&2
    return 1
}

# 启动功率监控函数
start_power_monitor() {
    local gpu_index=$1
    local sampling_interval=$2
    local monitor_pid_file="power_logs/gpu${gpu_index}_monitor.pid"
    local power_log_file="power_logs/gpu${gpu_index}_power.log"
    
    # 获取传感器路径
    if ! SENSOR_PATH=$(find_sensor_path $gpu_index); then
        echo "警告: 无法监控GPU $gpu_index 的功率"
        return 1
    fi
    
    # 将毫秒转换为秒用于sleep命令
    local sleep_interval=$(echo "scale=3; $sampling_interval / 1000" | bc)
    
    # 后台运行功率监控
    (
        echo "监控的DCU索引: $gpu_index"
        echo "传感器路径: $SENSOR_PATH"
        echo "采样间隔: ${sampling_interval}ms"
        echo "时间戳(ms),功率(W)"
        
        while true; do
            current_time=$(date +%s%3N)
            # 读取功率值（微瓦）并转换为瓦特
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
    
    echo $! > "$monitor_pid_file"
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

# 分析功率数据并计算能效比（返回结果字符串）
calculate_efficiency() {
    local gpu_index=$1
    local start_time=$2
    local end_time=$3
    local performance_value=$4
    local performance_unit=$5
    local sampling_interval=$6
    local power_log_file="power_logs/gpu${gpu_index}_power.log"
    
    # 根据性能指标单位确定能效比单位
    local efficiency_unit="${performance_unit}/W"
    
    if [ ! -f "$power_log_file" ]; then
        echo "错误: 找不到GPU $gpu_index 的功率日志文件"
        return
    fi
    
    # 计算矩阵运行总时间
    total_time=$((end_time - start_time))
    
    # 提取指定时间范围内的功率数据
    total_power=0
    valid_samples=0
    min_power=999999
    max_power=0

    # 调整开始时间：推后2个采样间隔，去除计算开始前的功耗数据
    adjusted_start_time=$((start_time + 500))

    while IFS=',' read -r timestamp power_w; do
        # 跳过标题行和无效数据
        if [[ "$timestamp" =~ ^[0-9]+$ ]] && [[ "$power_w" =~ ^[0-9.]+$ ]]; then
            if (( timestamp >=  adjusted_start_time && timestamp <= end_time )); then
                total_power=$(echo "$total_power + $power_w" | bc)
                
                # 更新最小功率
                if (( $(echo "$power_w < $min_power" | bc -l) )); then
                    min_power=$power_w
                fi
                
                # 更新最大功率
                if (( $(echo "$power_w > $max_power" | bc -l) )); then
                    max_power=$power_w
                fi
                
                ((valid_samples++))
            fi
        fi
    done < "$power_log_file"
    
    if ((valid_samples > 0)); then
        avg_power=$(echo "scale=3; $total_power / $valid_samples" | bc)
        
        if (( $(echo "$avg_power > 0" | bc -l) )); then
            efficiency=$(echo "scale=3; $performance_value / $avg_power" | bc)
            # 返回格式化的结果字符串
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
    echo "                                         主机智能算力能效测试"
    print_separator
}

# 打印测试配置信息
print_config() {
    echo "测试配置:"
    echo "  - 矩阵形状: M=$M, N=$N, K=$K"
    echo "  - 数据类型: $dtype"
    echo "  - 参与计算GPU列表: ${gpu_list}"
    echo "  - 矩阵乘计算循环次数: ${iterations}"
    echo "  - GPU功率采样间隔: ${sampling_interval_ms} ms"
    print_separator
}

# 打印结果表格
print_results_table() {
    local results=("$@")
    local total_performance=0
    local total_power=0  # 总功率（所有显卡平均功率之和）
    local total_efficiency=0
    local valid_gpus=0
    
    # 确定性能单位（从第一个有效结果中获取）
    local performance_unit=""
    for result in "${results[@]}"; do
        IFS='|' read -ra data <<< "$result"
        if [[ "${data[9]}" != "N/A" && "${data[9]}" != "UNKNOWN" ]]; then
            performance_unit="${data[9]}"
            break
        fi
    done
    
    # 确定能效单位
    local efficiency_unit="${performance_unit}/W"
    
    # 根据单位长度动态调整空格数量
    local spaces=" "  # 默认2个空格（用于TOPS）
    
    if [[ "$performance_unit" == "FLOPS" ]]; then
        spaces=""
    fi
    
    echo "测试结果汇总:"
    echo "+------+------------+----------+-------------+-------------+-------------+---------------+---------------+"
    echo "| GPU  |计算耗时(ms)| 采样点数 | 最小功率(W) | 最大功率(W) | 平均功率(W) |计算性能($performance_unit)$spaces|能效比($efficiency_unit)$spaces|"
    echo "+------+------------+----------+-------------+-------------+-------------+---------------+---------------+"
    
    for result in "${results[@]}"; do
        IFS='|' read -ra data <<< "$result"
        
        # 提取数据字段
        gpu_id="${data[0]}"
        total_time="${data[2]}"
        valid_samples="${data[4]}"
        min_power="${data[5]}"
        max_power="${data[6]}"
        avg_power="${data[7]}"
        performance_value="${data[8]}"
        efficiency="${data[10]}"
        
        # 格式化数值，保留两位小数并居中对齐
        min_power_formatted=$(printf "%13.2f" "$min_power")
        max_power_formatted=$(printf "%13.2f" "$max_power")
        avg_power_formatted=$(printf "%13.2f" "$avg_power")
        performance_formatted=$(printf "%15.2f" "$performance_value")
        efficiency_formatted=$(printf "%15.2f" "$efficiency")
        
        # 居中对齐GPU ID
        gpu_id_centered=$(printf "%6s" "$gpu_id")
        
        # 居中对齐总时间
        total_time_centered=$(printf "%12s" "$total_time")
        
        # 居中对齐采样点数
        valid_samples_centered=$(printf "%10s" "$valid_samples")
        
        printf "|%6s|%11s|%10s|%13s|%13s|%13s|%15s|%15s|\n" \
            "$gpu_id_centered" "$total_time_centered" "$valid_samples_centered" \
            "$min_power_formatted" "$max_power_formatted" "$avg_power_formatted" \
            "$performance_formatted" "$efficiency_formatted"
        
        # 计算汇总数据（只统计有效数据）
        if [[ "$performance_value" != "N/A" && "$avg_power" != "N/A" && "$efficiency" != "N/A" ]]; then
            total_performance=$(echo "$total_performance + $performance_value" | bc)
            total_power=$(echo "$total_power + $avg_power" | bc)  # 所有显卡平均功率之和
            total_efficiency=$(echo "$total_efficiency + $efficiency" | bc)
            ((valid_gpus++))
        fi
    done
    
    echo "+------+------------+----------+-------------+-------------+-------------+---------------+---------------+"
    
    # 计算并显示汇总行
    if (( valid_gpus > 0 )); then
        avg_efficiency=$(echo "scale=3; $total_efficiency / $valid_gpus" | bc)
        avg_efficiency_formatted=$(printf "%.2f" "$avg_efficiency")
        total_performance_formatted=$(printf "%.2f" "$total_performance")
        total_power_formatted=$(printf "%.2f" "$total_power")
        
        # 汇总行居中对齐
        printf "| 汇总 |     -      |     -    |      -      |      -      |%13s|%15s|%15s|\n" \
            "$total_power_formatted" "$total_performance_formatted" "$avg_efficiency_formatted"
        echo "+------+------------+----------+-------------+-------------+-------------+---------------+---------------+"
        
        # 简洁的总结输出
        echo "总计算性能: $total_performance_formatted $performance_unit"
        echo "总功率: $total_power_formatted W"
        echo "平均能效比: $avg_efficiency_formatted $efficiency_unit"
    fi
}

# 打印统计信息
print_statistics() {
    print_separator
    echo "测试完成时间: $(TZ='Asia/Shanghai' date '+%Y-%m-%d %H:%M:%S %Z')"
    # 使用~代替个人home路径
    echo "日志文件位置: ~/codes/gemm-bench/blas/logs/ 和 ~/codes/gemm-bench/blas/power_logs/ 目录"
    print_separator
}

# 主执行流程
print_title
print_config

# 启动所有GPU的功率监控
for gpu in "${GPUS[@]}"; do
    start_power_monitor $gpu $sampling_interval_ms
    sleep 1  # 给监控程序一些启动时间
done

# 在后台并行运行每个GPU任务
# 保存所有gemm-bench进程ID
gemm_pids=()

for gpu in "${GPUS[@]}"; do
    export HIP_VISIBLE_DEVICES=$gpu
    export CUDA_VISIBLE_DEVICES=$gpu
    log_file="logs/gpu${gpu}.log"
    
    ./gemm-bench $M $N $K $dtype $iterations > "$log_file" 2>&1 &
    gemm_pid=$!
    gemm_pids+=($gemm_pid)
    
    # 保存进程ID用于后续管理
    echo $gemm_pid > "logs/gpu${gpu}.pid"
done

# 等待所有gemm-bench任务完成
for pid in "${gemm_pids[@]}"; do
    wait $pid
done

# 停止所有GPU的功率监控
for gpu in "${GPUS[@]}"; do
    stop_power_monitor $gpu
done

# 收集所有结果
results=()
for gpu in "${GPUS[@]}"; do
    log_file="logs/gpu${gpu}.log"
    if [ -f "$log_file" ]; then
        # 提取循环计算次数
        iterations_count=$(grep "循环计算次数:" "$log_file" | awk '{print $2}')
        if [ -z "$iterations_count" ]; then
            iterations_count=$iterations  # 使用默认值
        fi
        
        # 提取真正的计算开始/结束时间戳（从gemm-bench输出）
        compute_start_time=$(grep "计算开始毫秒时间戳:" "$log_file" | awk '{print $2}')
        compute_end_time=$(grep "计算结束毫秒时间戳:" "$log_file" | awk '{print $2}')
        
        # 提取计算性能结果和单位
        if grep -q "TOPS:" "$log_file"; then
            performance_value=$(grep "TOPS:" "$log_file" | awk '{print $NF}')
            performance_unit="TOPS"
        elif grep -q "FLOPS:" "$log_file"; then
            performance_value=$(grep "FLOPS:" "$log_file" | awk '{print $NF}')
            performance_unit="FLOPS"
        elif grep -q "TFLOPS:" "$log_file"; then
            # 将TFLOPS转换为FLOPS (1 TFLOPS = 10^12 FLOPS)
            tflops=$(grep "TFLOPS:" "$log_file" | awk '{print $NF}')
            performance_value=$(echo "scale=3; $tflops * 1000000000000" | bc)
            performance_unit="FLOPS"
        else
            performance_value=0
            performance_unit="UNKNOWN"
        fi
        
        if [[ -n "$compute_start_time" && -n "$compute_end_time" && -n "$performance_value" ]]; then
            # 计算能效比并获取格式化结果
            result=$(calculate_efficiency $gpu $compute_start_time $compute_end_time $performance_value "$performance_unit" $sampling_interval_ms)
            results+=("$gpu|$iterations_count|$result")
        else
            results+=("$gpu|$iterations_count|N/A|N/A|N/A|N/A|N/A|N/A|$performance_value|$performance_unit|N/A|N/A")
        fi
    fi
done

# 统一输出所有结果
print_results_table "${results[@]}"
print_statistics

# 强制终止所有可能的残留监控进程
pkill -f "power1_average" 2>/dev/null || true
