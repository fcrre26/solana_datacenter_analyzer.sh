#!/bin/bash

# 设置环境变量
SOLANA_INSTALL_DIR="/root/.local/share/solana/install"
export PATH="$SOLANA_INSTALL_DIR/active_release/bin:$PATH"

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
VERSION="v1.2.7"

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

# 测试网络质量
test_network_quality() {
    local ip="$1"
    local retries=2
    local timeout=2
    local total_time=0
    local success_count=0
    local ports=("8899" "8900" "8001" "8000")
    
    for ((i=1; i<=retries; i++)); do
        for port in "${ports[@]}"; do
            # 使用 nc 测试 TCP 连接时间
            local start_time=$(date +%s%N)
            if timeout $timeout nc -zv "$ip" "$port" >/dev/null 2>&1; then
                local end_time=$(date +%s%N)
                local duration=$(( (end_time - start_time) / 1000000 ))
                total_time=$((total_time + duration))
                ((success_count++))
                break
            fi
        done
    done
    
    if [ $success_count -gt 0 ]; then
        local avg_latency=$((total_time / success_count))
        local min_latency=$((avg_latency * 90 / 100))
        local max_latency=$((avg_latency * 110 / 100))
        local loss=$((100 - success_count * 100 / (retries * ${#ports[@]})))
        echo "$min_latency|$avg_latency|$max_latency|$loss"
        return 0
    fi
    
    # 如果 nc 测试失败，尝试 curl
    if command -v curl >/dev/null 2>&1; then
        local curl_start=$(date +%s%N)
        if curl -s -o /dev/null -w '%{time_total}\n' --connect-timeout 2 "http://$ip:8899" 2>/dev/null; then
            local curl_end=$(date +%s%N)
            local curl_duration=$(( (curl_end - curl_start) / 1000000 ))
            echo "$curl_duration|$curl_duration|$curl_duration|0"
            return 0
        fi
    fi
    
    echo "999|999|999|100"
    return 0
}

# 识别数据中心
identify_datacenter() {
    local ip="$1"
    local asn_info
    asn_info=$(whois -h whois.cymru.com " -v $ip" 2>/dev/null)
    
    if [ $? -eq 0 ]; then
        local asn_org
        asn_org=$(echo "$asn_info" | tail -n1 | awk -F'|' '{print $6}' | xargs)
        local asn_num
        asn_num=$(echo "$asn_info" | tail -n1 | awk -F'|' '{print $1}' | xargs)
        
        # 获取位置信息
        local whois_info
        whois_info=$(whois "$ip" 2>/dev/null)
        local country
        country=$(echo "$whois_info" | grep -i "country:" | head -1 | cut -d':' -f2 | xargs)
        local city
        city=$(echo "$whois_info" | grep -i "city:" | head -1 | cut -d':' -f2 | xargs)
        
        # 获取网络信息
        local subnet
        subnet=$(echo "$whois_info" | grep -i "CIDR\|route:" | head -1 | awk '{print $2}')
        
        # 组合位置信息
        local location=""
        [ -n "$city" ] && location="$city"
        [ -n "$country" ] && location="${location:+$location, }$country"
        
        echo "${asn_org:-Unknown}|${asn_num:-0}|${location:-Unknown}|${subnet:-Unknown}"
    else
        echo "Unknown|0|Unknown|Unknown"
    fi
}

# 获取验证者信息
get_validators() {
    log "INFO" "正在获取验证者信息..."
    
    local validators
    validators=$(solana gossip 2>/dev/null)
    if [ $? -ne 0 ]; then
        log "ERROR" "无法获取验证者信息"
        return 1
    fi
    
    local ips
    ips=$(echo "$validators" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | sort -u)
    if [ -z "$ips" ]; then
        log "ERROR" "未找到验证者IP地址"
        return 1
    fi
    
    echo "$ips"
    return 0
}

# 分析验证者节点
analyze_validators() {
    log "INFO" "开始分析验证者节点分布"
    
    local validator_ips
    validator_ips=$(get_validators) || {
        log "ERROR" "获取验证者信息失败"
        return 1
    }
    
    # 清空结果文件
    : > "${RESULTS_FILE}"
    
    local tmp_ips_file="${TEMP_DIR}/tmp_ips.txt"
    echo "$validator_ips" > "$tmp_ips_file"
    
    local total
    total=$(wc -l < "$tmp_ips_file")
    local current=0
    
    log "INFO" "找到 ${total} 个验证者节点"
    echo -e "\n${YELLOW}正在测试节点延迟...${NC}"
    
    while read -r ip; do
        ((current++))
        printf "\r进度: [%-50s] %d%%" "$(printf '#%.0s' $(seq 1 $((current * 50 / total))))" "$((current * 100 / total))"
        
        # 测试网络延迟
        local latency_info
        latency_info=$(test_network_quality "$ip")
        local min_latency
        min_latency=$(echo "$latency_info" | cut -d'|' -f1)
        local avg_latency
        avg_latency=$(echo "$latency_info" | cut -d'|' -f2)
        local max_latency
        max_latency=$(echo "$latency_info" | cut -d'|' -f3)
        
        # 获取数据中心信息
        local dc_info
        dc_info=$(identify_datacenter "$ip")
        local provider
        provider=$(echo "$dc_info" | cut -d'|' -f1)
        local asn
        asn=$(echo "$dc_info" | cut -d'|' -f2)
        local location
        location=$(echo "$dc_info" | cut -d'|' -f3)
        local subnet
        subnet=$(echo "$dc_info" | cut -d'|' -f4)
        
        # 保存结果
        echo "$ip|$provider|$location|$subnet|$asn|$min_latency|$avg_latency|$max_latency" >> "${RESULTS_FILE}"
        
        # 每100个节点显示一次进度
        if ((current % 100 == 0)); then
            echo -e "\n已完成 $current/$total 个节点分析"
        fi
    done < "$tmp_ips_file"
    
    rm -f "$tmp_ips_file"
    echo -e "\n"
    
    # 生成报告
    generate_report
}

# 生成报告
generate_report() {
    log "INFO" "正在生成报告..."
    
    {
        echo "# Solana 验证者节点延迟分析报告"
        echo "生成时间: $(date '+%Y-%m-%d %H:%M:%S')"
        echo
        
        echo "## 延迟统计 (Top 20)"
        echo "| IP地址 | 位置 | 延迟(ms) | 供应商 |"
        echo "|---------|------|-----------|---------|"
        
        # 按延迟排序并显示前20个节点
        sort -t'|' -k7 -n "${RESULTS_FILE}" | head -20 | while IFS='|' read -r ip provider location subnet asn min avg max; do
            if [ "$avg" != "999" ]; then
                printf "| %s | %s | %s | %s |\n" "$ip" "${location:-Unknown}" "$avg" "${provider:-Unknown}"
            fi
        done
        
        echo
        echo "## 供应商分布"
        echo "| 供应商 | 节点数量 | 平均延迟(ms) |"
        echo "|---------|------------|--------------|"
        
        # 统计供应商分布
        awk -F'|' '$7!=999 {
            count[$2]++
            latency_sum[$2]+=$7
        }
        END {
            for (provider in count) {
                printf "| %s | %d | %.2f |\n", 
                    provider, 
                    count[provider], 
                    latency_sum[provider]/count[provider]
            }
        }' "${RESULTS_FILE}" | sort -t'|' -k3 -n
        
        echo
        echo "## 位置分布"
        echo "| 位置 | 节点数量 | 平均延迟(ms) |"
        echo "|------|------------|--------------|"
        
        # 统计位置分布
        awk -F'|' '$7!=999 {
            count[$3]++
            latency_sum[$3]+=$7
        }
        END {
            for (location in count) {
                printf "| %s | %d | %.2f |\n", 
                    location, 
                    count[location], 
                    latency_sum[location]/count[location]
            }
        }' "${RESULTS_FILE}" | sort -t'|' -k3 -n
        
        echo
        echo "---"
        echo "* 延迟测试使用 TCP 连接时间"
        echo "* 测试端口: 8899(RPC), 8900(Gossip)"
        echo "* 报告版本: ${VERSION}"
        
    } > "${LATEST_REPORT}"
    
    log "SUCCESS" "报告已生成: ${LATEST_REPORT}"
}

# 安装 Solana CLI
install_solana_cli() {
    if ! command -v solana &>/dev/null; then
        log "INFO" "Solana CLI 未安装,开始安装..."
        
        # 创建安装目录
        mkdir -p "$SOLANA_INSTALL_DIR"
        
        # 下载并安装特定版本
        local VERSION="v1.18.15"
        local DOWNLOAD_URL="https://release.solana.com/$VERSION/solana-release-x86_64-unknown-linux-gnu.tar.bz2"
        
        # 下载并解压
        curl -L "$DOWNLOAD_URL" | tar jxf - -C "$SOLANA_INSTALL_DIR" || {
            log "ERROR" "Solana CLI 下载失败"
            return 1
        }
        
        # 创建符号链接
        rm -rf "$SOLANA_INSTALL_DIR/active_release"
        ln -s "$SOLANA_INSTALL_DIR/solana-release" "$SOLANA_INSTALL_DIR/active_release"
        
        # 设置环境变量
        export PATH="$SOLANA_INSTALL_DIR/active_release/bin:$PATH"
        
        # 配置 Solana CLI
        solana config set --url https://api.mainnet-beta.solana.com || {
            log "ERROR" "Solana CLI 配置失败"
            return 1
        }
        
        log "SUCCESS" "Solana CLI 安装成功"
    else
        log "INFO" "Solana CLI 已安装"
    fi
    return 0
}

# 检查依赖
check_dependencies() {
    local deps=("curl" "nc" "whois" "awk" "sort")
    local missing=()

    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            missing+=("$dep")
        fi
    done

    if [ ${#missing[@]} -ne 0 ]; then
        log "INFO" "正在安装必要工具: ${missing[*]}"
        apt-get update -qq && apt-get install -y -qq "${missing[@]}" || {
            log "ERROR" "工具安装失败"
            return 1
        }
    fi
    return 0
}

# 清理函数
cleanup() {
    rm -f "$LOCK_FILE"
}

# 测试单个IP
test_single_ip() {
    local ip="$1"
    
    echo -e "\n测试 IP: $ip"
    echo "===================="
    
    # 测试延迟
    local latency_info
    latency_info=$(test_network_quality "$ip")
    local avg_latency
    avg_latency=$(echo "$latency_info" | cut -d'|' -f2)
    
    # 获取数据中心信息
    local dc_info
    dc_info=$(identify_datacenter "$ip")
    local provider
    provider=$(echo "$dc_info" | cut -d'|' -f1)
    local location
    location=$(echo "$dc_info" | cut -d'|' -f3)
    
    echo "延迟: ${avg_latency}ms"
    echo "位置: $location"
    echo "供应商: $provider"
    echo "===================="
}

# 主菜单
show_menu() {
    echo -e "\n${BLUE}Solana 验证者节点延迟分析工具 ${VERSION}${NC}"
    echo "=================================="
    echo "1. 分析所有验证者节点延迟"
    echo "2. 测试指定IP的延迟"
    echo "3. 查看最新分析报告"
    echo "0. 退出"
    echo "=================================="
    echo -ne "请选择操作 [0-3]: "
}

# 主函数
main() {
    if [ "$EUID" -ne 0 ]; then 
        log "ERROR" "请使用root权限运行此脚本"
        exit 1
    fi
    
    trap cleanup EXIT
    trap 'echo -e "\n${RED}程序被中断${NC}"; exit 1' INT TERM
    
    if [ -f "$LOCK_FILE" ]; then
        log "ERROR" "程序已在运行中"
        exit 1
    fi
    
    touch "$LOCK_FILE"
    
    check_dependencies || exit 1
    install_solana_cli || exit 1
    
    while true; do
        show_menu
        read -r choice
        
        case $choice in
            1)  analyze_validators || {
                    log "ERROR" "分析失败"
                    read -rp "按回车键继续..."
                }
                ;;
            2)  echo -ne "\n请输入要测试的IP地址: "
                read -r test_ip
                if [[ $test_ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                    test_single_ip "$test_ip"
                else
                    log "ERROR" "无效的IP地址"
                fi
                read -rp "按回车键继续..."
                ;;
            3)  if [ -f "${LATEST_REPORT}" ]; then
                    clear
                    cat "${LATEST_REPORT}"
                else
                    log "ERROR" "未找到分析报告"
                fi
                read -rp "按回车键继续..."
                ;;
            0)  log "INFO" "感谢使用！"
                exit 0
                ;;
            *)  log "ERROR" "无效选择"
                sleep 1
                ;;
        esac
    done
}

# 启动程序
main "$@"
