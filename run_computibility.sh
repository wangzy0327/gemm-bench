#!/bin/bash

# 定义系数组合 (w1,w2,w3,w4) - 注意：w1:fp64, w2:fp32, w3:fp16, w4:int8
declare -A coefficients=(
    ["1"]="0.25,0.25,0.25,0.25"
    ["2"]="0.2125,0.45,0.2,0.1375" 
    ["3"]="0.2,0.325,0.325,0.15"
    ["4"]="0.225,0.5,0.075,0.2"
)

# 昇腾910B基准性能指标
declare -A ascend_benchmarks=(
    ["fp64"]="0"
    ["fp32"]="608.472"
    ["fp16"]="2299.272"
    ["int8"]="4460.076"
)

# 存储测试结果的数组
declare -A test_results

echo "开始执行性能测试..."
echo "================================================================"

# 执行测试命令并提取性能数据
perform_tests() {
    local commands=(
        "./system_computibility.sh 5120 4096 32768 100 fp64" 
        "./system_computibility.sh 5120 8192 65536 100 fp32"
        "./system_computibility.sh 5120 4096 65536 100 fp16"
        "./system_computibility.sh 5120 4096 131072 100 int8"
    )
    
    local data_types=("fp64" "fp32" "fp16" "int8")
    
    for i in "${!commands[@]}"; do
        local data_type="${data_types[$i]}"
        echo "执行命令: ${commands[$i]}"
        echo "------------------------------------------------"
        
        # 执行命令并捕获输出
        local output
        output=$(${commands[$i]} 2>&1)
        echo "$output"
        echo "------------------------------------------------"
        
        # 提取性能数据 (TFLOPS或TOPS)
        local performance="0"
        if [ "$data_type" = "int8" ]; then
            performance=$(echo "$output" | grep -oP "整机计算性能:\s*\K[0-9.]+(?=\s*T?OPS)" | head -1 || echo "0")
        else
            performance=$(echo "$output" | grep -oP "整机计算性能:\s*\K[0-9.]+(?=\s*TFLOPS)" | head -1 || echo "0")
        fi
        
        if [ -n "$performance" ] && [ "$performance" != "0" ]; then
            test_results["$data_type"]="$performance"
            echo "提取的${data_type}性能: $performance"
        else
            test_results["$data_type"]="0"
            echo "警告: 无法提取${data_type}性能数据，使用默认值0"
        fi
        echo ""
    done
}

# 计算指数加权性能
calculate_exponential_weighted_performance() {
    local w1=$1  # fp64系数
    local w2=$2  # fp32系数  
    local w3=$3  # fp16系数
    local w4=$4  # int8系数
    local combo=$5
    
    local p_fp64="${test_results["fp64"]}"
    local p_fp32="${test_results["fp32"]}"
    local p_fp16="${test_results["fp16"]}"
    local p_int8="${test_results["int8"]}"
    
    # 计算测试系统的指数加权性能: (性能)^(系数)
    local weighted_perf=1
    local terms=()
    
    # fp64: (性能)^(w1)
    if [ "$p_fp64" != "0" ] && [ "$p_fp64" != "" ]; then
        local term1=$(echo "scale=10; e($w1 * l($p_fp64))" | bc -l 2>/dev/null || echo "0")
        if [ "$term1" != "0" ]; then
            weighted_perf=$(echo "scale=10; $weighted_perf + $term1" | bc -l)
            terms+=("fp64:($p_fp64)^($w1)=$term1")
        fi
    fi
    
    # fp32: (性能)^(w2)
    if [ "$p_fp32" != "0" ] && [ "$p_fp32" != "" ]; then
        local term2=$(echo "scale=10; e($w2 * l($p_fp32))" | bc -l 2>/dev/null || echo "0")
        if [ "$term2" != "0" ]; then
            weighted_perf=$(echo "scale=10; $weighted_perf + $term2" | bc -l)
            terms+=("fp32:($p_fp32)^($w2)=$term2")
        fi
    fi
    
    # fp16: (性能)^(w3)
    if [ "$p_fp16" != "0" ] && [ "$p_fp16" != "" ]; then
        local term3=$(echo "scale=10; e($w3 * l($p_fp16))" | bc -l 2>/dev/null || echo "0")
        if [ "$term3" != "0" ]; then
            weighted_perf=$(echo "scale=10; $weighted_perf + $term3" | bc -l)
            terms+=("fp16:($p_fp16)^($w3)=$term3")
        fi
    fi
    
    # int8: (性能)^(w4)
    if [ "$p_int8" != "0" ] && [ "$p_int8" != "" ]; then
        local term4=$(echo "scale=10; e($w4 * l($p_int8))" | bc -l 2>/dev/null || echo "0")
        if [ "$term4" != "0" ]; then
            weighted_perf=$(echo "scale=10; $weighted_perf + $term4" | bc -l)
            terms+=("int8:($p_int8)^($w4)=$term4")
        fi
    fi
    
    # 计算昇腾的指数加权性能
    local ascend_fp64="${ascend_benchmarks["fp64"]}"
    local ascend_fp32="${ascend_benchmarks["fp32"]}"
    local ascend_fp16="${ascend_benchmarks["fp16"]}"
    local ascend_int8="${ascend_benchmarks["int8"]}"
    
    local ascend_weighted_perf=1
    local ascend_terms=()
    
    # 昇腾 fp64: (性能)^(w1)
    if [ "$ascend_fp64" != "0" ] && [ "$ascend_fp64" != "" ]; then
        local ascend_term1=$(echo "scale=10; e($w1 * l($ascend_fp64))" | bc -l 2>/dev/null || echo "0")
        if [ "$ascend_term1" != "0" ]; then
            ascend_weighted_perf=$(echo "scale=10; $ascend_weighted_perf + $ascend_term1" | bc -l)
            ascend_terms+=("fp64:($ascend_fp64)^($w1)=$ascend_term1")
        fi
    fi
    
    # 昇腾 fp32: (性能)^(w2)
    if [ "$ascend_fp32" != "0" ] && [ "$ascend_fp32" != "" ]; then
        local ascend_term2=$(echo "scale=10; e($w2 * l($ascend_fp32))" | bc -l 2>/dev/null || echo "0")
        if [ "$ascend_term2" != "0" ]; then
            ascend_weighted_perf=$(echo "scale=10; $ascend_weighted_perf + $ascend_term2" | bc -l)
            ascend_terms+=("fp32:($ascend_fp32)^($w2)=$ascend_term2")
        fi
    fi
    
    # 昇腾 fp16: (性能)^(w3)
    if [ "$ascend_fp16" != "0" ] && [ "$ascend_fp16" != "" ]; then
        local ascend_term3=$(echo "scale=10; e($w3 * l($ascend_fp16))" | bc -l 2>/dev/null || echo "0")
        if [ "$ascend_term3" != "0" ]; then
            ascend_weighted_perf=$(echo "scale=10; $ascend_weighted_perf + $ascend_term3" | bc -l)
            ascend_terms+=("fp16:($ascend_fp16)^($w3)=$ascend_term3")
        fi
    fi
    
    # 昇腾 int8: (性能)^(w4)
    if [ "$ascend_int8" != "0" ] && [ "$ascend_int8" != "" ]; then
        local ascend_term4=$(echo "scale=10; e($w4 * l($ascend_int8))" | bc -l 2>/dev/null || echo "0")
        if [ "$ascend_term4" != "0" ]; then
            ascend_weighted_perf=$(echo "scale=10; $ascend_weighted_perf + $ascend_term4" | bc -l)
            ascend_terms+=("int8:($ascend_int8)^($w4)=$ascend_term4")
        fi
    fi
    
    # 比较结果
    local comparison=""
    if (( $(echo "$weighted_perf > $ascend_weighted_perf" | bc -l) )); then
        local ratio=$(echo "scale=2; $weighted_perf / $ascend_weighted_perf" | bc -l)
        comparison="✓ 超过昇腾 (${ratio}x)"
    else
        local ratio=$(echo "scale=2; $ascend_weighted_perf / $weighted_perf" | bc -l)
        comparison="✗ 低于昇腾 (${ratio}x)"
    fi
    
    # 输出结果
    echo "系数组合$combo (w1=fp64:$w1, w2=fp32:$w2, w3=fp16:$w3, w4=int8:$w4):"
    echo "  - 测试系统指数加权性能: $(echo "scale=3; $weighted_perf" | bc -l)"
    echo "  - 昇腾910B指数加权性能: $(echo "scale=3; $ascend_weighted_perf" | bc -l)"
    echo "  - 比较结果: $comparison"
    
    # 显示详细计算过程（可选）
    if [ "${#terms[@]}" -gt 0 ]; then
        echo "  - 详细计算:"
        for term in "${terms[@]}"; do
            echo "    * $term"
        done
    fi
    echo ""
}

# 显示原始测试结果
show_raw_results() {
    echo "================================================================"
    echo "性能测试结果汇总:"
    echo "================================================================"
    
    for data_type in "fp64" "fp32" "fp16" "int8"; do
        local result="${test_results[$data_type]}"
        local ascend_bench="${ascend_benchmarks[$data_type]}"
        local comparison=""
        
        if [ "$result" != "0" ] && [ "$ascend_bench" != "0" ]; then
            local ratio=$(echo "scale=2; $result / $ascend_bench" | bc -l)
            if (( $(echo "$result > $ascend_bench" | bc -l) )); then
                comparison="(超过昇腾, ${ratio}x)"
            else
                comparison="(低于昇腾, ${ratio}x)"
            fi
        elif [ "$ascend_bench" = "0" ] && [ "$result" != "0" ]; then
            comparison="(昇腾无此算力)"
        fi
        
        printf "%-8s: %-12s TFLOPS/TOPS  昇腾: %-12s %s\n" \
               "$data_type" "$result" "$ascend_bench" "$comparison"
    done
    echo ""
}

# 检查单个项目是否超过昇腾
check_individual_superiority() {
    echo "================================================================"
    echo "单个项目超过昇腾910B指标:"
    echo "================================================================"
    
    local has_superior=false
    
    for data_type in "fp64" "fp32" "fp16" "int8"; do
        local result="${test_results[$data_type]}"
        local ascend_bench="${ascend_benchmarks[$data_type]}"
        
        if [ "$result" != "0" ] && [ "$ascend_bench" != "0" ]; then
            if (( $(echo "$result > $ascend_bench" | bc -l) )); then
                local ratio=$(echo "scale=2; $result / $ascend_bench" | bc -l)
                printf "%-8s: %-12s > %-12s (%.2fx 昇腾性能)\n" \
                       "$data_type" "$result" "$ascend_bench" "$ratio"
                has_superior=true
            fi
        fi
    done
    
    if [ "$has_superior" = false ]; then
        echo "暂无单个项目超过昇腾910B指标"
    fi
    echo ""
}

# 主执行流程
main() {
    # 检查bench-test.txt文件
    #if [ -f "bench-test.txt" ]; then
    #    echo "发现bench-test.txt文件:"
    #    cat bench-test.txt
    #    echo ""
    #fi
    
    # 执行测试
    perform_tests
    
    # 显示原始结果
    show_raw_results
    
    # 检查单个项目优势
    check_individual_superiority
    
    echo "================================================================"
    echo "指数加权性能比较 (性能^系数):"
    echo "================================================================"
    echo "加权公式: fp64^w1 + fp32^w2 + fp16^w3 + int8^w4"
    echo ""
    
    # 计算每种系数组合的指数加权性能
    for combo in 1 2 3 4; do
        IFS=',' read -r w1 w2 w3 w4 <<< "${coefficients[$combo]}"
        calculate_exponential_weighted_performance "$w1" "$w2" "$w3" "$w4" "$combo"
    done
    
    echo "================================================================"
    echo "所有测试完成!"
    echo "================================================================"
}

# 运行主程序
main
