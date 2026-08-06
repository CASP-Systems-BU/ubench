#!/bin/bash

cd $(dirname $0)

# <bench> <request> <threads> <conns> <total_s> <rate>
bash ../../scripts/run.sh social mix 4 16 60 1000
