#!/bin/bash

# 多GPU性能测试与功耗监控脚本
# 用法: ./multi_gpu_power_efficiency.sh M N K dtype [gpu_list] [sampling_interval_ms]
# 示例: ./multi_gpu_power_efficiency.sh 2048 2048 2048 fp32 "0,1,2,3" 100

# 检查参数
if [ $# -lt 4 ]; then
  echo "用法: $0 M N K dtype [gpu_list] [sampling_interval_ms]"
  echo "示例: $0 2048 2048 2048 fp32 \"0,1,2,3\" 100"
  echo "支持的数据类型: fp64, fp32, fp16, int8"
  echo "采样间隔默认值: 100ms"
  exit 1
fi

# 获取参数
M=$1
N=$2
K=$3
dtype=$4
gpu_list=${5:-"0,1"}  # 默认使用GPU 0和1
sampling_interval_ms=${6:-100}  # 默认100ms采样间隔

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
mkdir -p power_logs

# 查找特定DCU的功耗传感器路径
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
    
    echo "错误: 在DCU$gpu_index对应的路径$card_path上未找到功耗传感器" >&2
    return 1
}

# 启动功耗监控函数
start_power_monitor() {
    local gpu_index=$1
    local sampling_interval=$2
    local monitor_pid_file="power_logs/gpu${gpu_index}_monitor.pid"
    local power_log_file="power_logs/gpu${gpu_index}_power.log"
    
    # 获取传感器路径
    if ! SENSOR_PATH=$(find_sensor_path $gpu_index); then
        echo "警告: 无法监控GPU $gpu_index 的功耗"
        return 1
    fi
    
    echo "启动GPU $gpu_index 功耗监控，采样间隔: ${sampling_interval}ms..."
    
    # 将毫秒转换为秒用于sleep命令
    local sleep_interval=$(echo "scale=3; $sampling_interval / 1000" | bc)
    
    # 后台运行功耗监控
    (
        echo "监控的DCU索引: $gpu_index"
        echo "传感器路径: $SENSOR_PATH"
        echo "采样间隔: ${sampling_interval}ms"
        echo "时间戳(ms),功耗(W)"
        
        while true; do
            current_time=$(date +%s%3N)
            # 读取功耗值（微瓦）并转换为瓦特
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
    echo "GPU $gpu_index 功耗监控已启动，PID: $!"
}

# 停止功耗监控函数
stop_power_monitor() {
    local gpu_index=$1
    local monitor_pid_file="power_logs/gpu${gpu_index}_monitor.pid"
    
    if [ -f "$monitor_pid_file" ]; then
        monitor_pid=$(cat "$monitor_pid_file")
        if kill -0 "$monitor_pid" 2>/dev/null; then
            kill "$monitor_pid"
            echo "已停止GPU $gpu_index 功耗监控 (PID: $monitor_pid)"
        fi
        rm -f "$monitor_pid_file"
    fi
}

# 分析功耗数据并计算能效比
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
        echo "错误: 找不到GPU $gpu_index 的功耗日志文件"
        return
    fi
    
    # 计算矩阵运行总时间
    total_time=$((end_time - start_time))
    echo "矩阵计算运行总时间: ${total_time}ms"
    
    # 功耗采样间隔
    echo "功耗采样间隔: ${sampling_interval}ms"
    
    # 提取指定时间范围内的功耗数据
    total_power=0
    valid_samples=0
    min_power=999999
    max_power=0
    
    while IFS=',' read -r timestamp power_w; do
        # 跳过标题行和无效数据
        if [[ "$timestamp" =~ ^[0-9]+$ ]] && [[ "$power_w" =~ ^[0-9.]+$ ]]; then
            if (( timestamp >= start_time && timestamp <= end_time )); then
                total_power=$(echo "$total_power + $power_w" | bc)
                
                # 更新最小功耗
                if (( $(echo "$power_w < $min_power" | bc -l) )); then
                    min_power=$power_w
                fi
                
                # 更新最大功耗
                if (( $(echo "$power_w > $max_power" | bc -l) )); then
                    max_power=$power_w
                fi
                
                ((valid_samples++))
            fi
        fi
    done < "$power_log_file"
    
    echo "有效功耗采样点个数: ${valid_samples}"
    
    if ((valid_samples > 0)); then
        avg_power=$(echo "scale=3; $total_power / $valid_samples" | bc)
        
        echo "最大功耗: ${max_power}W"
        echo "最小功耗: ${min_power}W"
        echo "平均功耗: ${avg_power}W"
        echo "计算性能: ${performance_value} ${performance_unit}"
        
        if (( $(echo "$avg_power > 0" | bc -l) )); then
            efficiency=$(echo "scale=3; $performance_value / $avg_power" | bc)
            echo "能效比: $efficiency ${efficiency_unit}"
        else
            echo "平均功耗为0，无法计算能效比"
        fi
    else
        echo "在计算时间内无有效功耗数据"
    fi
}

# 启动所有GPU的功耗监控
for gpu in "${GPUS[@]}"; do
    start_power_monitor $gpu $sampling_interval_ms
    sleep 1  # 给监控程序一些启动时间
    
    # 记录监控开始时间
    monitor_start_time=$(date +%s%3N)
    echo "GPU $gpu 监控开始时间: $monitor_start_time ms"
done

# 在后台并行运行每个GPU任务
echo "在以下GPU上并行运行gemm-bench: ${GPUS[*]}"
echo "矩阵大小: M=$M, N=$N, K=$K, 数据类型: $dtype"

# 保存所有gemm-bench进程ID
gemm_pids=()

for gpu in "${GPUS[@]}"; do
    export HIP_VISIBLE_DEVICES=$gpu
    export CUDA_VISIBLE_DEVICES=$gpu
    log_file="logs/gpu${gpu}.log"
    
    echo "启动GPU $gpu 任务，日志文件: $log_file"
    
    ./gemm-bench $M $N $K $dtype > "$log_file" 2>&1 &
    gemm_pid=$!
    gemm_pids+=($gemm_pid)
    
    # 保存进程ID用于后续管理
    echo $gemm_pid > "logs/gpu${gpu}.pid"
    echo "GPU $gpu 进程ID: $gemm_pid"
done

# 等待所有gemm-bench任务完成
echo "等待所有gemm-bench任务完成..."
for pid in "${gemm_pids[@]}"; do
    wait $pid
done

# 停止所有GPU的功耗监控
for gpu in "${GPUS[@]}"; do
    stop_power_monitor $gpu
done

echo "所有GPU任务已完成，结果保存在logs目录中"

# 显示结果摘要并计算能效比
for gpu in "${GPUS[@]}"; do
    log_file="logs/gpu${gpu}.log"
    if [ -f "$log_file" ]; then
        echo "=== GPU $gpu 结果 ==="
        
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
        
        # 输出终端显示的时间戳（使用gemm-bench的真实时间戳）
        echo "计算开始毫秒时间戳: $compute_start_time"
        echo "计算结束毫秒时间戳: $compute_end_time"
        
        if [[ -n "$compute_start_time" && -n "$compute_end_time" && -n "$performance_value" ]]; then
            echo "计算时间范围: $compute_start_time ms - $compute_end_time ms"
            
            # 计算能效比
            calculate_efficiency $gpu $compute_start_time $compute_end_time $performance_value "$performance_unit" $sampling_interval_ms
        else
            echo "无法获取完整的时间戳或性能数据"
            cat "$log_file"
        fi
        
        echo ""
    fi
done

# 强制终止所有可能的残留监控进程
pkill -f "power1_average" 2>/dev/null || true

echo "功耗监控数据保存在power_logs目录中"