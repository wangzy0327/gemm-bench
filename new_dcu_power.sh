#!/bin/bash

# 多DCU支持,HY DCU 功耗监控脚本 (支持指定DCU列表，时长单位为秒)

# 配置参数
LOG_FILE=${1:-"./dcu_power.log"}
DURATION_S=${2:-10}       # 默认10秒
INTERVAL_MS=${3:-100}     # 默认100ms采样间隔
GPU_INDICES=${4:-"0"}    # 默认监控第0号DCU，支持逗号分隔的列表如"0,1,2,3"

# 转换时长为毫秒
DURATION_MS=$((DURATION_S * 1000))

# 验证参数
if ! [[ "$DURATION_S" =~ ^[0-9]+$ ]] || ! [[ "$INTERVAL_MS" =~ ^[0-9]+$ ]]; then
    echo "错误: 持续时间(DURATION_S)和间隔(INTERVAL_MS)必须是整数"
    exit 1
fi

# 验证GPU索引参数
if [[ -z "$GPU_INDICES" ]]; then
    echo "错误: DCU索引列表不能为空"
    exit 1
fi

# 计算分钟表示
DURATION_MINUTES=$(echo "scale=2; $DURATION_S / 60" | bc)

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

# 解析GPU索引列表并获取传感器路径
declare -a sensor_paths
declare -a gpu_indices

# 将逗号分隔的索引列表转换为数组
IFS=',' read -ra INDEX_ARRAY <<< "$GPU_INDICES"

for index in "${INDEX_ARRAY[@]}"; do
    # 验证索引是否为整数
    if ! [[ "$index" =~ ^[0-9]+$ ]]; then
        echo "错误: DCU索引$index必须是整数" >&2
        exit 1
    fi
    
    if SENSOR_PATH=$(find_sensor_path $index); then
        sensor_paths+=($SENSOR_PATH)
        gpu_indices+=($index)
        echo "找到DCU$index的传感器路径: $SENSOR_PATH"
    else
        echo "警告: 无法获取DCU$index的传感器路径" >&2
    fi
done

# 检查是否有可用的传感器
if [[ ${#sensor_paths[@]} -eq 0 ]]; then
    echo "错误: 没有找到任何可用的DCU传感器" >&2
    exit 1
fi

echo "总共找到${#sensor_paths[@]}个DCU传感器进行监控"

# 获取开始时间（毫秒）
start_time=$(date +%s%3N)

# 创建内存数据缓冲区
declare -A power_data
sample_count=0
expected_samples=$(( (DURATION_MS + INTERVAL_MS - 1) / INTERVAL_MS ))

# 初始化每个DCU的数据数组
for gpu_index in "${gpu_indices[@]}"; do
    power_data[$gpu_index]="监控的DCU索引: $gpu_index\n开始时间戳(ms): $start_time\n监控时长: $DURATION_S 秒 ($DURATION_MINUTES 分钟)\n采样间隔: $INTERVAL_MS ms\n传感器路径: ${sensor_paths[$gpu_index]}\n时间戳(ms),功耗(W)"
done

# 主监控循环
while true; do
    # 获取当前时间（毫秒）
    current_time=$(date +%s%3N)
    elapsed_time=$((current_time - start_time))
    
    # 检查是否超时
    if ((elapsed_time >= DURATION_MS)); then
        break
    fi
    
    # 读取每个DCU的功耗值
    for i in "${!gpu_indices[@]}"; do
        gpu_index=${gpu_indices[$i]}
        sensor_path=${sensor_paths[$i]}
        
        # 直接读取功耗值（微瓦）
        power_mw=$(cat "$sensor_path" 2>/dev/null)
        
        # 转换为瓦特
        if [[ $power_mw =~ ^[0-9]+$ ]]; then
            power_w=$(echo "scale=2; $power_mw / 1000000" | bc)
        else
            power_w="N/A"
        fi
        
        # 将数据添加到对应DCU的内存数组
        power_data[$gpu_index]+="\n$current_time,$power_w"
    done
    
    ((sample_count++))
    
    # 计算精确等待时间
    next_sample_time=$((start_time + (sample_count * INTERVAL_MS)))
    current_time=$(date +%s%3N)
    sleep_time=$((next_sample_time - current_time))
    
    # 仅当需要时才等待
    if ((sleep_time > 0)); then
        sleep_sec=$(echo "scale=3; $sleep_time / 1000" | bc)
        sleep "$sleep_sec"
    elif ((sleep_time < -INTERVAL_MS)); then
        echo "警告: 采样延迟 ${sleep_time#-}ms" >&2
    fi
done

# 监控结束后写入文件
{
    # 写入所有DCU的内存数据
    for gpu_index in "${gpu_indices[@]}"; do
        printf "\n==================== DCU $gpu_index ====================\n"
        echo -e "${power_data[$gpu_index]}"
        
        # 为每个DCU添加统计信息
        printf "\n=== DCU $gpu_index 统计信息 ===\n"
        
        # 计算平均功耗（忽略无效值）
        total_power=0
        valid_samples=0
        max_power=0
        
        # 分析数据行（跳过标题行）
        data_lines=()
        while IFS= read -r line; do
            data_lines+=("$line")
        done <<< "$(echo -e "${power_data[$gpu_index]}" | tail -n +6)"
        
        for line in "${data_lines[@]}"; do
            IFS=',' read -r timestamp power_w <<< "$line"
            if [[ $power_w =~ ^[0-9.]+$ ]]; then
                total_power=$(echo "$total_power + $power_w" | bc)
                ((valid_samples++))
                # 更新最大功耗
                if (( $(echo "$power_w > $max_power" | bc -l) )); then
                    max_power=$power_w
                fi
            fi
        done
        
        if ((valid_samples > 0)); then
            avg_power=$(echo "scale=3; $total_power / $valid_samples" | bc)
            printf "总样本数: %d\n" "$sample_count"
            printf "理论样本数: %d\n" "$expected_samples"
            printf "采样完成率: %.1f%%\n" "$(echo "scale=1; 100 * $sample_count / $expected_samples" | bc)"
            printf "实际采样率: %.1f Hz\n" "$(echo "scale=1; 1000 * $sample_count / $DURATION_MS" | bc)"
            printf "平均功耗: %.2f W\n" "$avg_power"
            printf "最大功耗: %.2f W\n" "$max_power"
        else
            printf "平均功耗: 无有效数据\n"
            printf "最大功耗: 无有效数据\n"
        fi
    done
} > "$LOG_FILE"

echo "监控完成! DCU数量: ${#sensor_paths[@]}, 时长: ${DURATION_S}秒, 间隔: ${INTERVAL_MS}ms"
echo "样本: ${sample_count}/${expected_samples}, 日志: $LOG_FILE"