#!/bin/bash

# 启用严格模式
set -euo pipefail

# 处理命令行参数
BACKGROUND_TASK="${1:-}"

# 颜色定义
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

# 标识符定义
INFO="[INFO]"
WARN="[WARN]"
ERROR="[ERROR]"
SUCCESS="[OK]"

# 目录和文件配置
TEMP_DIR="/tmp/solana_dc_finder"
LOG_FILE="${TEMP_DIR}/dc_finder.log"
RESULTS_FILE="${TEMP_DIR}/validator_locations.txt"
REPORT_DIR="$HOME/solana_reports"
LATEST_REPORT="${REPORT_DIR}/latest_report.txt"
BACKGROUND_LOG="${REPORT_DIR}/background.log"
LOCK_FILE="/tmp/solana_dc_finder.lock"
BACKUP_DIR="${REPORT_DIR}/backups"
BACKUP_FILE="${BACKUP_DIR}/latest_analysis.bak"
VERSION="v1.2.6"

# 创建必要的目录
mkdir -p "${TEMP_DIR}" "${REPORT_DIR}" "${BACKUP_DIR}"

# 格式化数字
format_number() {
    printf "%'d" "$1"
}

# 日志函数
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local line_info=""
    
    if [ "$level" = "ERROR" ]; then
        line_info=" (行号: ${BASH_LINENO[0]})"
    fi
    
    echo -e "${timestamp} [${level}]${line_info} ${message}" >> "${LOG_FILE}"
    
    case "$level" in
        "INFO")    echo -e "${BLUE}${INFO} ${message}${NC}" ;;
        "ERROR")   echo -e "${RED}${ERROR} ${message}${line_info}${NC}" ;;
        "SUCCESS") echo -e "${GREEN}${SUCCESS} ${message}${NC}" ;;
        "WARN")    echo -e "${YELLOW}${WARN} ${message}${NC}" ;;
        *) echo -e "${message}" ;;
    esac
}

# 清理函数
cleanup() {
    rm -f "$LOCK_FILE"
    log "INFO" "清理完成"
}

# 备份函数
backup_data() {
    if [ -f "${RESULTS_FILE}" ]; then
        cp "${RESULTS_FILE}" "${BACKUP_FILE}"
        log "INFO" "数据已备份到 ${BACKUP_FILE}"
    fi
}

# 恢复函数
restore_data() {
    if [ -f "${BACKUP_FILE}" ]; then
        cp "${BACKUP_FILE}" "${RESULTS_FILE}"
        log "INFO" "已从备份恢复数据"
        return 0
    fi
    return 1
}

# 检查依赖
check_dependencies() {
    local deps=("curl" "jq" "whois" "bc" "ping" "nohup")
    local missing=()

    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            missing+=("$dep")
        fi
    done

    if [ ${#missing[@]} -ne 0 ]; then
        log "INFO" "正在安装必要工具: ${missing[*]}"
        apt-get update -qq && apt-get install -y -qq "${missing[@]}"
        if [ $? -ne 0 ]; then
            log "ERROR" "工具安装失败，请手动安装: ${missing[*]}"
            return 1
        fi
    fi
    return 0
}

# 安装 Solana CLI
install_solana_cli() {
    if ! command -v solana &>/dev/null; then
        log "INFO" "Solana CLI 未安装,开始安装..."
        
        sh -c "$(curl -sSfL https://release.solana.com/stable/install)"
        export PATH="/root/.local/share/solana/install/active_release/bin:$PATH"
        
        if ! command -v solana &>/dev/null; then
            log "ERROR" "Solana CLI 安装失败"
            return 1
        fi
        
        log "SUCCESS" "Solana CLI 安装成功"
        solana config set --url https://api.mainnet-beta.solana.com
    else
        log "INFO" "Solana CLI 已安装"
    fi
    return 0
}

# 检查后台任务状态
check_background_task() {
    if [ -f "$LOCK_FILE" ]; then
        local pid
        pid=$(pgrep -f "solana_dc_finder.*--background-task" 2>/dev/null)
        if [ -n "$pid" ]; then
            echo "后台分析正在运行 (PID: $pid)"
            echo "最近的日志内容:"
            tail -n 10 "${BACKGROUND_LOG}"
        else
            echo "发现锁文件但进程不存在，可能是异常退出"
            echo "建议清理锁文件: rm -f ${LOCK_FILE}"
        fi
    else
        echo "没有正在运行的后台分析任务"
    fi
}

# 进度条显示
show_progress() {
    local current="$1"
    local total="$2"
    local width=50
    local percentage=$((current * 100 / total))
    local completed=$((width * current / total))
    
    printf "\r进度: [%-${width}s] %3d%%" "$(printf '#%.0s' $(seq 1 $completed))" "$percentage"
    printf "\e[0K"
}

# 测试网络质量
test_network_quality() {
    local ip="$1"
    local count=5
    local interval=0.2
    local timeout=1
    local retries=3
    
    for ((i=1; i<=retries; i++)); do
        local result
        result=$(ping -c "$count" -i "$interval" -W "$timeout" "$ip" 2>/dev/null)
        if [ $? -eq 0 ]; then
            local stats
            stats=$(echo "$result" | tail -1)
            local min
            min=$(echo "$stats" | awk -F'/' '{print $4}')
            local avg
            avg=$(echo "$stats" | awk -F'/' '{print $5}')
            local max
            max=$(echo "$stats" | awk -F'/' '{print $6}')
            local loss
            loss=$(echo "$result" | grep -oP '\d+(?=% packet loss)')
            
            if [[ "$min" =~ ^[0-9]+(\.[0-9]+)?$ ]] && \
               [[ "$avg" =~ ^[0-9]+(\.[0-9]+)?$ ]] && \
               [[ "$max" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
                echo "$min|$avg|$max|$loss"
                return 0
            fi
        fi
        sleep 1
    done
    
    log "WARN" "无法测试 IP ${ip} 的网络质量"
    echo "timeout|timeout|timeout|100"
    return 1
}

# 识别数据中心
identify_datacenter() {
    local ip="$1"
    local dc_info=""
    local location=""
    local subnet=""
    local provider=""
    local datacenter=""
    local instance_type=""
    local network_capacity=""
    
    # 使用 ASN 查询获取更详细信息
    local asn_info
    asn_info=$(whois -h whois.cymru.com " -v $ip" 2>/dev/null)
    if [ $? -eq 0 ]; then
        local asn_org
        asn_org=$(echo "$asn_info" | tail -n1 | awk -F'|' '{print $6}' | xargs)
        local asn_num
        asn_num=$(echo "$asn_info" | tail -n1 | awk -F'|' '{print $1}' | xargs)
        [ -n "$asn_org" ] && provider="$asn_org"
        
        # 识别具体的云服务商和数据中心
        case "$asn_org" in
            *Amazon*|*AWS*)
                provider="AWS"
                if [[ "$ip" =~ ^54\.168\. ]]; then
                    datacenter="ap-northeast-1a"
                    location="Tokyo"
                    subnet="54.168.0.0/16"
                    instance_type="c6gn.4xlarge"
                    network_capacity="25Gbps"
                elif [[ "$ip" =~ ^18\.162\. ]]; then
                    datacenter="ap-east-1b"
                    location="Hong Kong"
                    subnet="18.162.0.0/16"
                    instance_type="c6gn.4xlarge"
                    network_capacity="25Gbps"
                fi
                ;;
            *Google*)
                provider="Google Cloud"
                if [[ "$ip" =~ ^35\.186\. ]]; then
                    datacenter="asia-east1-b"
                    location="Singapore"
                    subnet="35.186.0.0/17"
                    instance_type="c2-standard-16"
                    network_capacity="32Gbps"
                fi
                ;;
            *Alibaba*)
                provider="Alibaba Cloud"
                if [[ "$ip" =~ ^47\.96\. ]]; then
                    datacenter="cn-hangzhou-1a"
                    location="Hangzhou"
                    subnet="47.96.0.0/16"
                    instance_type="ecs.g7.4xlarge"
                    network_capacity="20Gbps"
                fi
                ;;
            *Azure*)
                provider="Azure"
                if [[ "$ip" =~ ^52\.231\. ]]; then
                    datacenter="ap-east-1"
                    location="Seoul"
                    subnet="52.231.0.0/16"
                    instance_type="Standard_F16s_v2"
                    network_capacity="20Gbps"
                fi
                ;;
        esac
    fi
    
    # 获取子网信息
    if [ -z "$subnet" ]; then
        local whois_info
        whois_info=$(whois "$ip" 2>/dev/null)
        if [ $? -eq 0 ]; then
            subnet=$(echo "$whois_info" | grep -i "CIDR\|route:" | head -1 | awk '{print $2}')
            if [ -z "$location" ]; then
                local country
                country=$(echo "$whois_info" | grep -i "country:" | head -1 | cut -d':' -f2 | xargs)
                local city
                city=$(echo "$whois_info" | grep -i "city:" | head -1 | cut -d':' -f2 | xargs)
                [ -n "$city" ] && location="$city"
                [ -n "$country" ] && location="${location:+$location, }$country"
            fi
        fi
    fi
    
    # 返回格式: provider|datacenter|location|subnet|asn|instance_type|network_capacity
    echo "${provider:-Unknown}|${datacenter:-Unknown}|${location:-Unknown}|${subnet:-Unknown}|${asn_num:-Unknown}|${instance_type:-Unknown}|${network_capacity:-Unknown}"
}

# 获取验证者信息
get_validators() {
    log "INFO" "正在获取验证者信息..."
    
    local validators
    validators=$(solana gossip 2>/dev/null)
    if [ $? -ne 0 ]; then
        log "ERROR" "无法通过 solana gossip 获取验证者信息"
        return 1
    fi
    
    local ips
    ips=$(echo "$validators" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | sort -u)
    if [ -z "$ips" ]; then
        log "ERROR" "未找到有效的验证者IP地址"
        return 1
    fi
    
    echo "$ips"
    return 0
}

# 生成网络优化建议
generate_network_optimization() {
    local provider="$1"
    local datacenter="$2"
    
    echo "### 网络优化建议"
    echo "#### 系统参数优化"
    echo '```bash'
    echo "# 网络栈优化"
    echo "sysctl -w net.core.rmem_max=134217728"
    echo "sysctl -w net.core.wmem_max=134217728"
    echo "sysctl -w net.ipv4.tcp_rmem='4096 87380 67108864'"
    echo "sysctl -w net.ipv4.tcp_wmem='4096 87380 67108864'"
    echo
    echo "# 网络队列优化"
    echo "sysctl -w net.core.netdev_max_backlog=300000"
    echo "sysctl -w net.core.somaxconn=65535"
    echo
    echo "# TCP优化"
    echo "sysctl -w net.ipv4.tcp_max_syn_backlog=8192"
    echo "sysctl -w net.ipv4.tcp_max_tw_buckets=2000000"
    echo "sysctl -w net.ipv4.tcp_slow_start_after_idle=0"
    echo "sysctl -w net.ipv4.tcp_fin_timeout=30"
    echo '```'
    
    case "$provider" in
        "AWS")
            echo
            echo "#### AWS 特定优化"
            echo "- 启用 ENA (Elastic Network Adapter)"
            echo "- 配置 Placement Group: Cluster"
            echo "- 使用 AWS Direct Connect (10Gbps)"
            echo "- 启用 Jumbo Frames (MTU 9001)"
            echo "- 配置 VPC 端点"
            ;;
        "Google Cloud")
            echo
            echo "#### GCP 特定优化"
            echo "- 启用 GVNIC"
            echo "- 配置 Sole-tenant nodes"
            echo "- 使用 Cloud Interconnect"
            echo "- 启用 VPC 流日志"
            ;;
        "Alibaba Cloud")
            echo
            echo "#### 阿里云特定优化"
            echo "- 启用 RDMA 网络"
            echo "- 配置弹性网卡"
            echo "- 使用 Express Connect"
            echo "- 启用 智能网卡"
            ;;
        "Azure")
            echo
            echo "#### Azure 特定优化"
            echo "- 启用 Accelerated Networking"
            echo "- 配置 Proximity Placement Groups"
            echo "- 使用 ExpressRoute"
            echo "- 启用 Network Watcher"
            ;;
    esac
}

# 生成存储优化建议
generate_storage_optimization() {
    local provider="$1"
    local instance_type="$2"
    
    echo "### 存储优化建议"
    echo "#### 基础优化"
    echo '```bash'
    echo "# 文件系统优化"
    echo "mount -o noatime,nodiratime,discard,nobarrier /dev/nvme0n1 /solana"
    echo
    echo "# I/O调度器优化"
    echo "echo 'none' > /sys/block/nvme0n1/queue/scheduler"
    echo "echo '2' > /sys/block/nvme0n1/queue/nomerges"
    echo "echo '256' > /sys/block/nvme0n1/queue/nr_requests"
    echo '```'
    
    case "$provider" in
        "AWS")
            echo
            echo "#### AWS存储配置"
            echo "- 主存储:"
            echo "  * 类型: io2 Block Express"
            echo "  * 容量: 4TB"
            echo "  * IOPS: 160,000"
            echo "  * 吞吐量: 4,000 MB/s"
            echo "  * 延迟: < 1ms"
            echo "- 日志存储:"
            echo "  * 类型: NVMe SSD"
            echo "  * 容量: 1TB"
            echo "  * IOPS: 200,000"
            ;;
        "Google Cloud")
            echo
            echo "#### GCP存储配置"
            echo "- 主存储:"
            echo "  * 类型: Local SSD (NVMe)"
            echo "  * 容量: 3TB"
            echo "  * IOPS: 180,000"
            echo "  * 吞吐量: 3,600 MB/s"
            ;;
        "Alibaba Cloud")
            echo
            echo "#### 阿里云存储配置"
            echo "- 主存储:"
            echo "  * 类型: ESSD PL3"
            echo "  * 容量: 4TB"
            echo "  * IOPS: 150,000"
            echo "  * 吞吐量: 3,500 MB/s"
            ;;
    esac
}

# 生成报告
generate_report() {
    local report_file="$1"
    local total_nodes
    total_nodes=$(wc -l < "${RESULTS_FILE}")
    
    {
        echo "# Solana 验证者节点分布报告"
        echo "生成时间: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "分析节点总数: $(format_number ${total_nodes})"
        echo
        
        echo "## 部署建议"
        echo "### 1. 优选部署区域 (Top 5)"
        echo "|------------------|-------------|------------|----------|------------|------------|"
        echo "| 运营商/机房      | 位置        | 节点数量   | 平均延迟 | 最低延迟   | 网络容量   |"
        echo "|------------------|-------------|------------|----------|------------|------------|"
        
        # 生成优选部署区域表格
        awk -F'|' '
            $9!="timeout" {
                key=$2 "-" $3
                count[key]++
                latency_sum[key]+=$10
                if (!min_latency[key] || $9 < min_latency[key]) {
                    min_latency[key]=$9
                    best_ip[key]=$1
                    location[key]=$4
                    network[key]=$8
                }
            }
            END {
                for (k in count) {
                    avg=latency_sum[k]/count[k]
                    printf "| %-16s | %-11s | %10d | %8.2f | %8.2f | %-10s |\n", 
                           substr(k,1,16), substr(location[k],1,11), 
                           count[k], avg, min_latency[k], network[k]
                }
            }
        ' "${RESULTS_FILE}" | sort -t'|' -k5 -n | head -5
        
        echo "|------------------|-------------|------------|----------|------------|------------|"
        
        # 获取最优部署选项
        local best_option
        best_option=$(awk -F'|' '
            $9!="timeout" {
                if (!min_lat || $9 < min_lat) {
                    min_lat=$9
                    provider=$2
                    dc=$3
                    loc=$4
                    ip=$1
                    subnet=$5
                    instance=$7
                    network=$8
                }
            }
            END {
                print provider "|" dc "|" loc "|" ip "|" subnet "|" instance "|" network "|" min_lat
            }
        ' "${RESULTS_FILE}")
        
        local best_provider
        best_provider=$(echo "$best_option" | cut -d'|' -f1)
        local best_dc
        best_dc=$(echo "$best_option" | cut -d'|' -f2)
        local best_loc
        best_loc=$(echo "$best_option" | cut -d'|' -f3)
        local best_ip
        best_ip=$(echo "$best_option" | cut -d'|' -f4)
        local best_subnet
        best_subnet=$(echo "$best_option" | cut -d'|' -f5)
        local best_instance
        best_instance=$(echo "$best_option" | cut -d'|' -f6)
        local best_network
        best_network=$(echo "$best_option" | cut -d'|' -f7)
        local best_latency
        best_latency=$(echo "$best_option" | cut -d'|' -f8)
        
        echo
        echo "### 2. 最优部署方案"
        echo "#### 2.1 基础信息"
        echo "- 运营商: ${best_provider}"
        echo "- 数据中心: ${best_dc}"
        echo "- 位置: ${best_loc}"
        echo "- 参考节点: ${best_ip} (延迟: ${best_latency}ms)"
        echo "- 网段信息: ${best_subnet}"
        echo "- 推荐实例: ${best_instance}"
        echo "- 网络容量: ${best_network}"
        
        echo
        generate_network_optimization "$best_provider" "$best_dc"
        
        echo
        generate_storage_optimization "$best_provider" "$best_instance"
        
        echo
        echo "### 3. 监控配置建议"
        echo "#### 3.1 关键指标"
        echo "- 网络延迟监控"
        echo "  * 目标节点: ${best_ip}"
        echo "  * 告警阈值: > ${best_latency}ms"
        echo "  * 采样间隔: 10s"
        echo
        echo "- 系统资源监控"
        echo "  * CPU使用率: < 80%"
        echo "  * 内存使用率: < 85%"
        echo "  * 磁盘使用率: < 70%"
        echo "  * 网络吞吐量: < ${best_network} 的 80%"
        
        echo
        echo "---"
        echo "报告生成时间: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "分析工具版本: ${VERSION}"
        
    } > "$report_file"
    
    log "SUCCESS" "报告已生成: $report_file"
}

# 分析验证者节点
analyze_validators() {
    log "INFO" "开始分析验证者节点分布"
    
    local validator_ips
    validator_ips=$(get_validators)
    if [ $? -ne 0 ]; then
        return 1
    fi
    
    > "${RESULTS_FILE}"
    
    local tmp_ips_file="${TEMP_DIR}/tmp_ips.txt"
    echo "$validator_ips" > "$tmp_ips_file"
    
    local total
    total=$(wc -l < "$tmp_ips_file")
    local current=0
    
    log "INFO" "找到 ${total} 个唯一的验证者节点"
    echo -e "\n${YELLOW}正在分析节点位置信息...${NC}"
    
    while read -r ip; do
        ((current++))
        show_progress "$current" "$total"
        
        local dc_info
        dc_info=$(identify_datacenter "$ip")
        local provider
        provider=$(echo "$dc_info" | cut -d'|' -f1)
        local datacenter
        datacenter=$(echo "$dc_info" | cut -d'|' -f2)
        local location
        location=$(echo "$dc_info" | cut -d'|' -f3)
        local subnet
        subnet=$(echo "$dc_info" | cut -d'|' -f4)
        local asn
        asn=$(echo "$dc_info" | cut -d'|' -f5)
        local instance_type
        instance_type=$(echo "$dc_info" | cut -d'|' -f6)
        local network_capacity
        network_capacity=$(echo "$dc_info" | cut -d'|' -f7)
        
        local network_stats
        network_stats=$(test_network_quality "$ip")
        local min_latency
        min_latency=$(echo "$network_stats" | cut -d'|' -f1)
        local avg_latency
        avg_latency=$(echo "$network_stats" | cut -d'|' -f2)
        local max_latency
        max_latency=$(echo "$network_stats" | cut -d'|' -f3)
        local loss
        loss=$(echo "$network_stats" | cut -d'|' -f4)
        
        echo "$ip|$provider|$datacenter|$location|$subnet|$asn|$instance_type|$network_capacity|$min_latency|$avg_latency|$max_latency|$loss" >> "${RESULTS_FILE}"
    done < "$tmp_ips_file"
    
    rm -f "$tmp_ips_file"
    
    echo -e "\n"
    log "SUCCESS" "分析完成"
    generate_report "${LATEST_REPORT}"
}

# 后台运行分析
run_background_analysis() {
    if [ -f "$LOCK_FILE" ]; then
        log "ERROR" "已有分析任务在运行中"
        return 1
    fi
    
    touch "$LOCK_FILE"
    log "INFO" "开始后台分析任务..."
    
    nohup bash -c "
        echo '开始后台分析 - $(date)' > '${BACKGROUND_LOG}'
        export PATH='/root/.local/share/solana/install/active_release/bin:$PATH'
        cd '$(dirname "${LOCK_FILE}")'
        '$(dirname "$0")'/'$(basename "$0")' --background-task >> '${BACKGROUND_LOG}' 2>&1
        echo '分析完成 - $(date)' >> '${BACKGROUND_LOG}'
        rm -f '${LOCK_FILE}'
    " > /dev/null 2>&1 &

    local pid=$!
    log "SUCCESS" "后台分析任务已启动 (PID: $pid)"
    echo
