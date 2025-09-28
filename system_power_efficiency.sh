#!/bin/bash

# 整机多GPU性能测试与功率监控脚本
# 用法: ./system_power_efficiency.sh M N K iterations [dtype] [gpu_list] [sampling_interval_ms]
# 示例: ./system_power_efficiency.sh 2048 2048 2048 10000 int8 "0,1,2,3,4,5,6,7" 500

# 检查参数
if [ $# -lt 3 ]; then
    echo "用法: $0 M N K iterations [dtype] [gpu_list] [sampling_interval_ms]"
    echo "示例: $0 2048 2048 2048 10000 int8 \"0,1,2,3,4,5,6,7\" 500"
    echo "支持的数据类型: fp64, fp32, fp16, int8"
    echo "数据类型默认值: int8"
    echo "GPU列表默认值: \"0,1,2,3,4,5,6,7\" (所有8个GPU)"
    echo "采样间隔默认值: 500ms"
    exit 1
fi

# 获取参数 - 常用参数在前
M=$1
N=$2
K=$3
iterations=${4:-10000}
dtype=${5:-int8}
gpu_list=${6:-"0,1,2,3,4,5,6,7"}  # 默认使用所有8个GPU
sampling_interval_ms=${7:-500}  # 默认500ms采样间隔
ipmi_delay=7500 # ipmi读取BMC传感器的延时

# 验证采样间隔参数
if (( sampling_interval_ms < 200 )); then
    echo "警告: 采样间隔 ${sampling_interval_ms}ms 过小，建议不要设置低于200ms的采样间隔"
    echo "      由于IPMI命令执行需要约120ms，实际采样间隔可能大于设定值"
    echo "      建议使用200ms或更大的采样间隔以获得更好的准确性"
    read -p "是否继续？(y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# 检查gemm-bench程序是否存在
if [ ! -f "./gemm-bench" ]; then
    echo "错误: 找不到gemm-bench程序，请先编译ROCm版本"
    echo "编译命令: make rocm"
    exit 1
fi

# 解析GPU列表
IFS=',' read -ra GPUS <<< "$gpu_list"

# 创建日志目录
mkdir -p logs power_logs

# 清理旧的功率日志文件，避免残留数据污染
rm -f power_logs/system_power.log power_logs/system_monitor.pid

# 测试IPMI命令是否可用
test_ipmi_command() {
    echo "测试IPMI命令..."
    # 测试命令并显示前几行数据
    psu_data=$(sudo ipmi-sensors --record-ids="156,164,172,180,188,196,204,212" --no-header-output --comma-separated-output 2>&1)
    if [ $? -ne 0 ]; then
        echo "警告: IPMI命令执行失败，请检查sudo权限和IPMI配置"
        return 1
    fi
    
    # 显示前8行数据用于调试
    echo "$psu_data" | head -8
    
    # 测试解析逻辑
    valid_count=0
    while IFS=',' read -r record_id name type value unit status; do
        name=$(echo "$name" | xargs)
        value=$(echo "$value" | xargs)
        psu_num=$(echo "$name" | grep -o 'PSU[0-9]\+' | grep -o '[0-9]\+')
        if [[ -n "$psu_num" ]] && [[ "$value" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
            ((valid_count++))
        fi
    done <<< "$psu_data"
    
    if [ $valid_count -eq 0 ]; then
        echo "警告: 无法解析PSU功率数据，请检查IPMI输出格式"
        return 1
    fi
    
    return 0
}

# 启动整机PSU功率监控函数
start_system_power_monitor() {
    local sampling_interval=$1
    local monitor_pid_file="power_logs/system_monitor.pid"
    local power_log_file="power_logs/system_power.log"
    
    # 将毫秒转换为秒用于sleep命令
    local sleep_interval=$(echo "scale=3; $sampling_interval / 1000" | bc)
    
    # 后台运行整机功率监控
    (
        echo "监控整机PSU功率"
        echo "采样间隔: ${sampling_interval}ms"
        echo "时间戳(ms),总功率(W),PSU1(W),PSU2(W),PSU3(W),PSU4(W),PSU5(W),PSU6(W),PSU7(W),PSU8(W)"
        
        while true; do
            # 记录循环开始时间
            loop_start_time=$(date +%s%3N)

            # 使用loop_start_time作为当前时间
            current_time=$loop_start_time
            
            # 获取所有PSU的功率数据
            psu_data=$(sudo ipmi-sensors --record-ids="156,164,172,180,188,196,204,212" --no-header-output --comma-separated-output 2>/dev/null)
            
            if [ $? -eq 0 ] && [ -n "$psu_data" ]; then
                # 初始化PSU值数组
                declare -A psu_values
                total_power=0
                valid_psus=0
                
                # 逐行处理PSU数据（CSV格式）
                while IFS=',' read -r record_id name type value unit status; do
                    # 清理字段中的空格
                    name=$(echo "$name" | xargs)
                    value=$(echo "$value" | xargs)
                    
                    # 提取PSU编号
                    psu_num=$(echo "$name" | grep -o 'PSU[0-9]\+' | grep -o '[0-9]\+')
                    if [[ -n "$psu_num" ]] && [[ "$value" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
                        # 将浮点数转换为整数（去掉小数点）
                        int_value=$(echo "$value" | awk -F. '{print $1}')
                        psu_values[$psu_num]=$int_value
                        total_power=$((total_power + int_value))
                        valid_psus=$((valid_psus + 1))
                    fi
                done <<< "$psu_data"
                
                if [ $valid_psus -gt 0 ]; then
                    # 输出格式: 时间戳,总功率,PSU1,PSU2,...,PSU8
                    echo "$current_time,$total_power,${psu_values[1]:-0},${psu_values[2]:-0},${psu_values[3]:-0},${psu_values[4]:-0},${psu_values[5]:-0},${psu_values[6]:-0},${psu_values[7]:-0},${psu_values[8]:-0}"
                else
                    echo "$current_time,0,0,0,0,0,0,0,0,0"
                fi
            else
                echo "$current_time,0,0,0,0,0,0,0,0,0"
            fi
            
            # 计算循环执行时间
            loop_end_time=$(date +%s%3N)
            loop_execution_time=$((loop_end_time - loop_start_time))
            
            # 确保采样间隔控制在指定时间内
            if (( loop_execution_time < sampling_interval )); then
                remaining_time=$((sampling_interval - loop_execution_time))
                remaining_sleep=$(echo "scale=3; $remaining_time / 1000" | bc)
                sleep $remaining_sleep
            else
                # 如果循环执行时间超过采样间隔，立即开始下一次循环
                sleep 0.001
            fi
        done
    ) > "$power_log_file" 2>/dev/null &
    
    echo $! > "$monitor_pid_file"
}

# 停止整机功率监控函数
stop_system_power_monitor() {
    local monitor_pid_file="power_logs/system_monitor.pid"
    
    if [ -f "$monitor_pid_file" ]; then
        monitor_pid=$(cat "$monitor_pid_file")
        if kill -0 "$monitor_pid" 2>/dev/null; then
            kill "$monitor_pid"
        fi
        rm -f "$monitor_pid_file"
    fi
}

# 安全的数值比较函数
numeric_compare() {
    local a=$1
    local b=$2
    local op=$3
    
    # 使用awk进行浮点数比较
    awk -v a="$a" -v b="$b" -v op="$op" 'BEGIN {
        if (op == "<") { exit (a < b) ? 0 : 1 }
        if (op == ">") { exit (a > b) ? 0 : 1 }
        if (op == "==") { exit (a == b) ? 0 : 1 }
        exit 1
    }'
}

# 分析整机功率数据并计算能效比
calculate_system_efficiency() {
    local start_time=$1
    local end_time=$2
    local total_performance=$3
    local performance_unit=$4
    local sampling_interval=$5
    local power_log_file="power_logs/system_power.log"
    
    # 根据性能指标单位确定能效比单位
    local efficiency_unit="${performance_unit}/W"
    
    if [ ! -f "$power_log_file" ]; then
        echo "错误: 找不到整机功率日志文件"
        return
    fi
    
    # 计算矩阵运行总时间
    total_time=$((end_time - start_time))
    
    # 考虑8秒的延时，调整时间窗口（向后偏移8000ms）
    adjusted_start_time=$((start_time + ipmi_delay))
    adjusted_end_time=$((end_time + ipmi_delay))
    
    # 提取指定时间范围内的功率数据
    valid_samples=0
    total_power_sum=0
    avg_power=0
    max_power=0
    actual_power_start_time=""
    actual_power_end_time=""

    while IFS=',' read -r timestamp total_power_w psu1 psu2 psu3 psu4 psu5 psu6 psu7 psu8; do
        # 跳过标题行和无效数据
        if [[ "$timestamp" =~ ^[0-9]+$ ]] && [[ "$total_power_w" =~ ^[0-9]+$ ]]; then
            if (( timestamp >= adjusted_start_time && timestamp <= adjusted_end_time )); then
                # 记录实际的功率数据时间戳范围
                if [[ -z "$actual_power_start_time" ]] || (( timestamp < actual_power_start_time )); then
                    actual_power_start_time=$timestamp
                fi
                if [[ -z "$actual_power_end_time" ]] || (( timestamp > actual_power_end_time )); then
                    actual_power_end_time=$timestamp
                fi
                
                # 累加功率值用于计算平均值
                total_power_sum=$((total_power_sum + total_power_w))
                
                # 更新最大功率（使用最大值作为计算功率）
                if numeric_compare "$total_power_w" "$max_power" ">"; then
                    max_power=$total_power_w
                fi
                
                ((valid_samples++))
            fi
        fi
    done < "$power_log_file"
    
    if ((valid_samples > 0)); then
        # 计算平均功率
        if numeric_compare "$total_power_sum" "0" ">"; then
            avg_power=$(awk "BEGIN {printf \"%.2f\", $total_power_sum / $valid_samples}")
        else
            avg_power=0
        fi
        
        # 使用最大功率值计算能效比（而不是平均值）
        if numeric_compare "$max_power" "0" ">"; then
            efficiency=$(awk "BEGIN {printf \"%.3f\", $total_performance / $max_power}")
            # 返回格式化的结果字符串，包含实际的功率数据时间戳范围
            echo "$total_time|$sampling_interval|$valid_samples|$avg_power|$max_power|$max_power|$total_performance|$performance_unit|$efficiency|$efficiency_unit|$actual_power_start_time|$actual_power_end_time"
        else
            echo "$total_time|$sampling_interval|$valid_samples|$avg_power|$max_power|$max_power|$total_performance|$performance_unit|N/A|N/A|$actual_power_start_time|$actual_power_end_time"
        fi
    else
        echo "$total_time|$sampling_interval|0|N/A|N/A|N/A|$total_performance|$performance_unit|N/A|N/A|N/A|N/A"
    fi
}

# 打印分隔线
print_separator() {
    echo "=========================================================================================================="
}

# 打印标题
print_title() {
    print_separator
    echo "                                         整机智能算力能效测试"
    print_separator
}

# 打印测试配置信息
print_config() {
    echo "测试配置:"
    echo "  - 矩阵形状: M=$M, N=$N, K=$K"
    echo "  - 数据类型: $dtype"
    echo "  - 参与计算GPU列表: ${gpu_list}"
    echo "  - 矩阵乘计算循环次数: ${iterations}"
    echo "  - 整机功率采样间隔: ${sampling_interval_ms} ms"
    print_separator
}

# 安全的数值格式化函数
safe_format_number() {
    local num=$1
    local format=$2
    
    if [[ "$num" == "N/A" ]] || ! [[ "$num" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
        printf "$format" 0
    else
        printf "$format" "$num"
    fi
}

# 打印整机结果表格
print_system_results_table() {
    local result="$1"
    
    IFS='|' read -ra data <<< "$result"
    
    # 提取数据字段
    total_time="${data[0]}"
    sampling_interval="${data[1]}"
    valid_samples="${data[2]}"
    avg_power="${data[3]}"
    max_power="${data[4]}"
    calc_power="${data[5]}"  # 现在这是计算功率（最大值）
    total_performance="${data[6]}"
    performance_unit="${data[7]}"
    efficiency="${data[8]}"
    efficiency_unit="${data[9]}"
    actual_power_start_time="${data[10]}"
    actual_power_end_time="${data[11]}"
    
    # 确定空格数量
    local spaces="  "
    if [[ "$performance_unit" == "TFLOPS" ]]; then
        spaces=""
    fi
    
    echo "整机测试结果:"
    echo "+------------+----------+-------------+-------------+-------------+----------------+----------------+"
    echo "|计算耗时(ms)| 采样点数 | 平均功率(W) | 最大功率(W) | 计算功率(W) |$spaces计算性能($performance_unit)|$spaces能效比($efficiency_unit)|"
    echo "+------------+----------+-------------+-------------+-------------+----------------+----------------+"
    
    # 安全的数值格式化
    avg_power_formatted=$(safe_format_number "$avg_power" "%13.2f")
    max_power_formatted=$(safe_format_number "$max_power" "%13.2f")
    calc_power_formatted=$(safe_format_number "$calc_power" "%13.2f")
    performance_formatted=$(safe_format_number "$total_performance" "%16.2f")
    efficiency_formatted=$(safe_format_number "$efficiency" "%16.2f")
    
    # 居中对齐
    total_time_centered=$(printf "%12s" "$total_time")
    valid_samples_centered=$(printf "%10s" "$valid_samples")
    
    printf "|%12s|%10s|%13s|%13s|%13s|%15s|%15s|\n" \
        "$total_time_centered" "$valid_samples_centered" \
        "$avg_power_formatted" "$max_power_formatted" "$calc_power_formatted" \
        "$performance_formatted" "$efficiency_formatted"
    
    echo "+------------+----------+-------------+-------------+-------------+----------------+----------------+"
    
    # 简洁的总结输出
    if [[ "$efficiency" != "N/A" ]]; then
        echo "整机计算性能: $total_performance $performance_unit"
        echo "整机计算功率: $calc_power W (使用最大值)"
        echo "整机能效比: $efficiency $efficiency_unit"
    else
        echo "警告: 无法计算能效比，请检查功率监控数据"
    fi
}

# 打印统计信息
print_statistics() {
    print_separator
    echo "测试完成时间: $(TZ='Asia/Shanghai' date '+%Y-%m-%d %H:%M:%S %Z')"
    echo "日志文件位置: ~/codes/gemm-bench/logs/ 和 ~/codes/gemm-bench/power_logs/ 目录"
    print_separator
}

# 主执行流程
print_title
print_config

# 测试IPMI命令
if ! test_ipmi_command; then
    echo "警告: IPMI命令可能无法正常工作，将继续使用默认值"
fi

# 启动整机功率监控
start_system_power_monitor $sampling_interval_ms
sleep 2  # 给监控程序一些启动时间

# 打印每个GPU的性能表格
print_gpu_performance_table() {
    local gpu_performances=("$@")
    local num_gpus=${#gpu_performances[@]}

    # 确定空格数量
    local spaces="  "
    if [[ "$performance_unit" == "TFLOPS" ]]; then
        spaces=""
    fi
    
    echo "各GPU计算性能:"
    echo "+------+------------------+---------------+"
    echo "| GPU  |  $spaces计算性能($performance_unit)|    占比(%)    |"
    echo "+------+------------------+---------------+"
    
    for ((i=0; i<num_gpus; i++)); do
        gpu_data="${gpu_performances[$i]}"
        IFS='|' read -ra data <<< "$gpu_data"
        gpu_id="${data[0]}"
        gpu_perf="${data[1]}"
        
        # 计算占比
        if numeric_compare "$total_performance" "0" ">"; then
            percentage=$(awk "BEGIN {printf \"%.2f\", ($gpu_perf / $total_performance) * 100}")
        else
            percentage="0.00"
        fi
        
        # 格式化输出
        gpu_perf_formatted=$(safe_format_number "$gpu_perf" "%15.2f")
        percentage_formatted=$(safe_format_number "$percentage" "%14.2f")
        
        printf "| %4s |%17s |%14s |\n" \
            "$gpu_id" "$gpu_perf_formatted" "$percentage_formatted"
    done
    
    echo "+------+------------------+---------------+"
}

# 在后台并行运行每个GPU任务
gemm_pids=()
gpu_performance_data=()  # 新增：存储每个GPU的性能数据

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

# 停止整机功率监控
stop_system_power_monitor

# 收集所有GPU的结果并计算总算力
total_performance=0
performance_unit=""
earliest_start_time=9999999999999
latest_end_time=0
latest_start_gpu=""
latest_start_time=0
earliest_end_gpu=""
earliest_end_time=9999999999999

for gpu in "${GPUS[@]}"; do
    log_file="logs/gpu${gpu}.log"
    if [ -f "$log_file" ]; then
        # 提取计算开始/结束时间戳
        compute_start_time=$(grep "计算开始毫秒时间戳:" "$log_file" | awk '{print $2}')
        compute_end_time=$(grep "计算结束毫秒时间戳:" "$log_file" | awk '{print $2}')
        
        # 提取计算性能结果和单位
        if grep -q "TOPS:" "$log_file"; then
            performance_value=$(grep "TOPS:" "$log_file" | awk '{print $NF}')
            current_unit="TOPS"
        elif grep -q "TFLOPS:" "$log_file"; then
            performance_value=$(grep "TFLOPS:" "$log_file" | awk '{print $NF}')
            current_unit="TFLOPS"
        else
            performance_value=0
            current_unit="UNKNOWN"
        fi
        
        if [[ -n "$compute_start_time" && -n "$compute_end_time" && -n "$performance_value" ]]; then
            # 更新最早开始时间和最晚结束时间
            if (( compute_start_time < earliest_start_time )); then
                earliest_start_time=$compute_start_time
            fi
            if (( compute_end_time > latest_end_time )); then
                latest_end_time=$compute_end_time
            fi
            
            # 记录最晚开始的GPU
            if (( compute_start_time > latest_start_time )); then
                latest_start_time=$compute_start_time
                latest_start_gpu=$gpu
            fi
            
            # 记录最早结束的GPU
            if (( compute_end_time < earliest_end_time )); then
                earliest_end_time=$compute_end_time
                earliest_end_gpu=$gpu
            fi
            
            # 累计算力
            total_performance=$(awk "BEGIN {printf \"%.3f\", $total_performance + $performance_value}")
            
            # 保存每个GPU的性能数据
            gpu_performance_data+=("$gpu|$performance_value")
            
            # 设置性能单位（以第一个有效单位为准）
            if [[ -z "$performance_unit" && "$current_unit" != "UNKNOWN" ]]; then
                performance_unit="$current_unit"
            fi
        fi
    fi
done

# 如果没有有效的性能单位，使用默认值
if [[ -z "$performance_unit" ]]; then
    performance_unit="UNKNOWN"
fi

# 计算整机能效比
if (( earliest_end_time < 9999999999999 && latest_start_time > 0 )); then
    system_result=$(calculate_system_efficiency $latest_start_time $earliest_end_time $total_performance "$performance_unit" $sampling_interval_ms)
else
    system_result="N/A|N/A|N/A|N/A|N/A|N/A|$total_performance|$performance_unit|N/A|N/A"
fi

# 输出整机结果
print_system_results_table "$system_result"

# 输出每个GPU的性能表格
if [ ${#gpu_performance_data[@]} -gt 0 ]; then
    print_separator
    print_gpu_performance_table "${gpu_performance_data[@]}"
fi

# 输出同步调试信息
print_separator
echo "计算时间同步信息:"
echo "  - 最晚开始计算的GPU: GPU $latest_start_gpu, 开始时间: $latest_start_time ms"
echo "  - 最早结束计算的GPU: GPU $earliest_end_gpu, 结束时间: $earliest_end_time ms"
echo "  - 计算时间窗口: $earliest_start_time ms - $latest_end_time ms"
echo "  - 功率采集窗口: $actual_power_start_time ms - $actual_power_end_time ms"

print_statistics

# 强制终止所有可能的残留监控进程
pkill -f "ipmi-sensors" 2>/dev/null || true