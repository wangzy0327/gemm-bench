#!/bin/bash
./dcu_power_mon.sh;
./matmul-bench 2048 5120 16384 int8
