#### 测试代码执行

运行方式：

```bash
make #编译
./main #运行
make clean #清理
```

可在 `main.cc` 中更改矩阵乘的形状（M, N, K），以及数据类型（DTYPE_FLOAT 或 DTYPE_HALF），更改后需重新编译。



#### 筛选出能达到指定指标的shape

运行方式，该脚本是通过获取GPU的能效，不是整机能效，但能获取大致符合的形状

```bash
#用法: find_best_int8_shape_parallel.sh <num_gpus> <dtype> [sampling_interval_ms]
bash find_best_int8_shape_parallel.sh 4 int8 100
```

#### 通过初筛得到的shape进行整机能效对比

运行方式，该脚本是通过获取符合效率排序的能效

```bash
# 批量测试能效比
# 参数配置:
#  - 迭代次数: 10000
#  - 数据类型: int8
#  - GPU列表: 0,1,2,3,4,5,6,7
#  - 采样间隔: 500ms
#  - 输入文件: test_gemm.txt
#  - 输出文件: batch_results/gemm_efficiency_ranking_xxx.csv

bash batch_efficiency_ranking.sh
```

#### 测试计算能效比指标

通过system_power_efficiency.sh脚本执行得到指定的整机计算能效比

```bash
#用法: system_power_efficiency.sh M N K iterations [dtype] [gpu_list] [sampling_interval_ms]
#示例: system_power_efficiency.sh 2048 2048 2048 10000 int8 "0,1,2,3,4,5,6,7" 500
#支持的数据类型: fp64, fp32, fp16, int8
#数据类型默认值: int8
#GPU列表默认值: "0,1,2,3,4,5,6,7" (所有8个GPU)
#采样间隔默认值: 500ms
bash system_power_efficiency.sh 5120 2048 36864 20000
```

#### 测试峰值指标

通过system_computibility.sh脚本执行得到指定的整机计算峰值性能

```bash
#用法: system_computibility.sh M N K iterations [dtype] [gpu_list] [sampling_interval_ms]
#示例: system_computibility.sh 2048 2048 2048 10000 int8 "0,1,2,3,4,5,6,7" 500
#支持的数据类型: fp64, fp32, fp16, int8
#数据类型默认值: int8
#GPU列表默认值: "0,1,2,3,4,5,6,7" (所有8个GPU)
# 峰值参数 需要提前将 DCU频率提升到10等级
# bash system_computibility.sh 5120 4096 32768 100 fp64
# bash system_computibility.sh 5120 8192 65536 100 fp32
# bash system_computibility.sh 5120 4096 65536 100 fp16
# bash system_computibility.sh 5120 4096 131072 100 int8
bash system_computibility.sh
```



补充内容：

```bash
# 激活环境变量
source /opt/dtk/env.sh
# 查看 频率等级
hy-smi --showclkfrq

#如下所示等级为10

#HCU[7]          : Supported sclk frequencies on HCU 7
#HCU[7]          : 0: 300Mhz
#HCU[7]          : 1: 600Mhz
#HCU[7]          : 2: 800Mhz
#HCU[7]          : 3: 900Mhz
#HCU[7]          : 4: 1000Mhz
#HCU[7]          : 5: 1100Mhz
#HCU[7]          : 6: 1200Mhz
#HCU[7]          : 7: 1300Mhz
#HCU[7]          : 8: 1400Mhz
#HCU[7]          : 9: 1500Mhz
#HCU[7]          : 10: 1550Mhz *

# 设置频率等级
hy-smi --setsclk 6
# 筛选功率
sudo ipmi-sensors | grep -i power

#46  | PWR_Status       | System ACPI Power State     | N/A        | N/A   | 'S0/G0'
#62  | CPU_Power        | Power Supply                | 288.00     | W     | 'OK'
#89  | MEM_Power        | Power Supply                | 76.00      | W     | 'OK'
#150 | 12V_FAN_Power    | Power Supply                | 12.00      | W     | 'OK'
#154 | PSU1_IN_Power    | Power Supply                | 375.00     | W     | 'OK'
#156 | PSU1_OUT_Power   | Power Supply                | 351.00     | W     | 'OK'
```


