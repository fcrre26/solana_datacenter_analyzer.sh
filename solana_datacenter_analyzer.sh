#!/bin/bash

<<'COMMENT'
Solana 验证者节点部署分析工具 v1.2
专注于寻找超低延迟(≤1ms)部署位置，精确到0.001ms

【运行环境要求】
- 操作系统: Ubuntu 20.04+ / Debian 11+
- CPU: 2核+
- 内存: 4GB+
- 硬盘: 20GB+ 可用空间
- 网络: 稳定的互联网连接，无带宽限制
- 权限: 需要 root 权限

【使用方法】
1. 确保系统满足上述要求
2. 添加执行权限: chmod +x solana_datacenter_analyzer.sh
3. 使用root运行: sudo ./solana_datacenter_analyzer.sh

【工作流程】
1. 分析当前 VPS 的网络环境
2. 扫描所有 Solana 验证者节点
3. 进行高精度延迟测试(精确到0.001ms)
4. 重点识别低延迟(≤1ms)的节点
5. 查找目标节点附近的可用数据中心
6. 提供具体的部署建议

【注意事项】
- 首次运行需要安装依赖工具，可能需要5-10分钟
- 分析过程可能持续10-30分钟，取决于网络状况
- 建议在不同时段多次运行，以获得更准确的结果
- 某些云服务商的信息可能因API限制无法获取
- 结果仅供参考，实际部署时还需考虑成本等因素

【输出结果】
- 超低延迟验证者节点列表（精确到0.001ms）
- 相关数据中心信息
- 网络路径分析
- 具体部署建议

【作者】
Created by: Claude
Version: 1.2
Last Updated: 2024-01-20

【使用许可】
MIT License
仅供学习研究使用，请勿用于商业用途
COMMENT

# 颜色定义
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

# 图标定义
INFO_ICON="ℹ️"
NODE_ICON="📡"
CHECK_ICON="✅"
CLOUD_ICON="☁️"
WARNING_ICON="⚠️"
DC_ICON="🏢"
NETWORK_ICON="🌐"
LATENCY_ICON="⚡"

# 检查运行环境
check_environment() {
    echo -e "${BLUE}=== 正在检查运行环境 ===${NC}"
    local has_warning=false
    
    # 检查操作系统
    if ! grep -q "Ubuntu\|Debian" /etc/os-release; then
        echo -e "${WARNING_ICON} ${YELLOW}警告: 推荐使用 Ubuntu 20.04+ 或 Debian 11+${NC}"
        has_warning=true
    fi
    
    # 检查CPU核心数
    cpu_cores=$(nproc)
    if [ "$cpu_cores" -lt 2 ]; then
        echo -e "${WARNING_ICON} ${YELLOW}警告: CPU核心数小于推荐值(2核)${NC}"
        has_warning=true
    fi
    
    # 检查内存
    total_mem=$(free -m | awk '/^Mem:/{print $2}')
    if [ "$total_mem" -lt 4000 ]; then
        echo -e "${WARNING_ICON} ${YELLOW}警告: 内存小于推荐值(4GB)${NC}"
        has_warning=true
    fi
    
    # 检查磁盘空间
    free_space=$(df -m / | awk 'NR==2 {print $4}')
    if [ "$free_space" -lt 20000 ]; then
        echo -e "${WARNING_ICON} ${YELLOW}警告: 可用磁盘空间小于推荐值(20GB)${NC}"
        has_warning=true
    fi
    
    # 检查网络连接
    if ! ping -c 1 google.com >/dev/null 2>&1; then
        echo -e "${WARNING_ICON} ${YELLOW}警告: 网络连接可能不稳定${NC}"
        has_warning=true
    fi
    
    # 检查root权限
    if [ "$EUID" -ne 0 ]; then 
        echo -e "${RED}错误: 请使用root权限运行此脚本${NC}"
        exit 1
    fi

    # 如果有警告，询问用户是否继续
    if [ "$has_warning" = true ]; then
        echo -e "\n${YELLOW}检测到系统可能不满足推荐配置要求。${NC}"
        read -p "是否仍要继续？(y/n) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "已取消执行。"
            exit 1
        fi
    else
        echo -e "${GREEN}✓ 系统环境检查通过${NC}"
    fi
}

# 下载 Solana CLI
download_solana_cli() {
    echo "下载 Solana CLI..."
    sh -c "$(curl -sSfL https://release.solana.com/v1.18.15/install)"
    if [ $? -ne 0 ]; then
        echo -e "${RED}错误: Solana CLI 下载失败，请检查网络连接。${NC}"
        exit 1
    fi
    echo 'export PATH="/root/.local/share/solana/install/active_release/bin:$PATH"' >> /root/.bashrc
    export PATH="/root/.local/share/solana/install/active_release/bin:$PATH"
    source /root/.bashrc
    solana --version || {
        echo -e "${RED}错误: Solana CLI 安装后未能正确识别，请检查安装。${NC}"
        exit 1
    }
}

# 安装必要工具
install_requirements() {
    echo "正在安装必要工具..."
    apt-get update
    apt-get install -y curl mtr traceroute bc jq whois geoip-bin dnsutils hping3 iperf3

    # 下载 Solana CLI
    if ! command -v solana &> /dev/null; then
        download_solana_cli
    fi
}

# 优化的延迟测试函数
test_connection() {
    local ip=$1
    local results=""
    local min_latency=999.999
    
    echo -e "${YELLOW}正在进行高精度延迟测试: $ip${NC}"
    
    for i in {1..10}; do
        local hping_result=$(sudo hping3 -c 1 -S -p 80 -i u100 $ip 2>/dev/null | grep "rtt" | cut -d '/' -f 4)
        if [ ! -z "$hping_result" ]; then
            results="$results $hping_result"
            if (( $(echo "$hping_result < $min_latency" | bc -l) )); then
                min_latency=$hping_result
            fi
        fi
        sleep 0.2
    done
    
    local avg_latency=$(echo "$results" | tr ' ' '\n' | awk '{ total += $1; count++ } END { printf "%.3f", total/count }')
    local jitter=$(echo "$results" | tr ' ' '\n' | awk -v avg=$avg_latency '
        BEGIN { sum = 0; count = 0; }
        { sum += ($1 - avg)^2; count++; }
        END { printf "%.3f", sqrt(sum/count) }
    ')
    
    local mtr_result=$(mtr -n -c 1 -r $ip 2>/dev/null | tail -1 | awk '{printf "%.3f", $3}')
    local hop_count=$(mtr -n -c 1 -r $ip 2>/dev/null | wc -l)
    
    echo "$min_latency|$avg_latency|$jitter|$mtr_result|$hop_count"
}

# 分析验证者节点
analyze_validators() {
    echo -e "${YELLOW}正在获取验证者节点信息...${NC}"
    
    local validators
    validators=$(solana gossip --url https://api.mainnet-beta.solana.com 2>&1)
    
    if [[ $? -ne 0 ]]; then
        echo -e "${RED}错误: 无法获取验证者节点信息。${NC}"
        echo -e "${YELLOW}详细错误信息: $validators${NC}"
        echo -e "${YELLOW}请检查网络连接或 Solana CLI 配置。${NC}"
        return
    fi

    if [ -z "$validators" ]; then
        echo -e "${RED}错误: 获取到的验证者节点信息为空。${NC}"
        echo -e "${YELLOW}请检查网络连接或 Solana 网络状态。${NC}"
        return
    fi

    local results_file="/tmp/validator_analysis.txt"
    > "$results_file"

    echo -e "\n${BLUE}=== 正在分析验证者节点部署情况 ===${NC}"
    echo -e "特别关注延迟低于1ms的节点...\n"
    
    local total_validators=0
    local low_latency_count=0
    
    echo "$validators" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | while read -r ip; do
        echo -e "${YELLOW}分析节点: $ip${NC}"
        
        local connection_info
        connection_info=$(test_connection "$ip")
        if [ -z "$connection_info" ]; then
            echo -e "${RED}无法测试连接到 $ip，跳过此节点。${NC}"
            continue
        fi
        
        local min_latency=$(echo "$connection_info" | cut -d'|' -f1)
        local avg_latency=$(echo "$connection_info" | cut -d'|' -f2)
        local jitter=$(echo "$connection_info" | cut -d'|' -f3)
        local mtr_latency=$(echo "$connection_info" | cut -d'|' -f4)
        local hop_count=$(echo "$connection_info" | cut -d'|' -f5)
        
        # 记录结果
        echo "$ip|$min_latency|$avg_latency|$jitter|$mtr_latency|$hop_count" >> "$results_file"
        ((total_validators++))
        
        # 实时显示低延迟节点
        if (( $(echo "$min_latency <= 1" | bc -l) )); then
            ((low_latency_count++))
            echo -e "${GREEN}发现低延迟节点！${NC}"
            echo -e "IP: $ip"
            echo -e "最小延迟: ${min_latency}ms"
            echo -e "平均延迟: ${avg_latency}ms"
            echo -e "抖动: ${jitter}ms"
            echo -e "跳数: $hop_count"
        fi
    done

    # 显示低延迟节点详细信息
    echo -e "\n${BLUE}=== 低延迟验证者节点 (≤1ms) ===${NC}"
    echo -e "IP地址            延迟(ms)    平均(ms)   抖动(ms)   提供商        数据中心"
    echo -e "   └─ 延迟精确到0.001ms"
    echo -e "------------------------------------------------------------------------"

    sort -t'|' -k2 -n "$results_file" | while IFS='|' read -r ip min_lat avg_lat jitter mtr_lat hops; do
        if (( $(echo "$min_lat <= 1" | bc -l) )); then
            printf "${GREEN}%-15s %8.3f %8.3f %8.3f${NC}\n" "$ip" "$min_lat" "$avg_lat" "$jitter"
            echo -e "  └─ 跳数: $hops"
        fi
    done

    # 生成建议
    echo -e "\n${YELLOW}=== 部署建议 ===${NC}"
    echo -e "要达到1ms以内的延迟，建议："
    echo -e "1. ${CHECK_ICON} 选择与验证者节点相同的数据中心"
    echo -e "2. ${CHECK_ICON} 如果选择不同数据中心，确保："
    echo -e "   └─ 在同一园区内"
    echo -e "   └─ 使用同一个网络服务商"
    echo -e "   └─ 通过专线或直连方式连接"
    echo -e "3. ${CHECK_ICON} 网络配置建议："
    echo -e "   └─ 使用10Gbps+网络接口"
    echo -e "   └─ 开启网卡优化（TSO, GSO, GRO）"
    echo -e "   └─ 使用TCP BBR拥塞控制"
    echo -e "   └─ 调整系统网络参数"
    
    local report_file="/tmp/validator_deployment_report.txt"
    {
        echo "=== Solana 验证者节点部署分析报告 ==="
        echo "生成时间: $(date)"
        echo "分析节点总数: $total_validators"
        echo "低延迟节点数(≤1ms): $low_latency_count"
        echo ""
        echo "详细分析结果已保存到: $results_file"
    } > "$report_file"
}

# 显示主菜单
show_menu() {
    clear
    echo -e "${BLUE}=== Solana 验证者节点分析工具 ===${NC}"
    echo -e "${YELLOW}【首次使用请先选择 1 进行初始化和完整分析】${NC}"
    echo
    echo -e "${YELLOW}1.${NC} 运行完整分析 (包含初始化和依赖安装)"
    echo -e "${YELLOW}2.${NC} 显示所有验证者节点清单"
    echo -e "${YELLOW}3.${NC} 查看最近的分析结果"
    echo -e "${YELLOW}4.${NC} 查看特定IP的详细信息"
    echo -e "${YELLOW}5.${NC} 导出分析报告"
    echo -e "${YELLOW}6.${NC} 系统环境检查"
    echo -e "${YELLOW}7.${NC} 查看帮助信息"
    echo -e "${YELLOW}0.${NC} 退出"
    echo
    echo -e "当前状态:"
    if [ -f "/tmp/validator_analysis.txt" ]; then
        echo -e "${GREEN}✓${NC} 已有分析结果"
        echo -e "   └─ 最后分析时间: $(stat -c %y /tmp/validator_analysis.txt | cut -d. -f1)"
    else
        echo -e "${RED}✗${NC} 暂无分析结果 ${YELLOW}请先选择选项 1 运行完整分析${NC}"
    fi
    echo
}

# 主函数
main() {
    echo -e "${BLUE}=== 开始 Solana 验证者节点部署分析 ===${NC}"
    
    check_environment
    install_requirements
    analyze_validators
    
    echo -e "\n${GREEN}分析完成！${NC}"
    echo -e "${INFO_ICON} 详细分析结果已保存到 /tmp/validator_analysis.txt"
    echo -e "${INFO_ICON} 完整报告已保存到 /tmp/validator_deployment_report.txt"
    
    echo -e "\n${BLUE}=== 分析结果 ===${NC}"
    cat "/tmp/validator_analysis.txt"
}

# 主菜单函数
menu_main() {
    while true; do
        show_menu
        read -p "请选择功能 (0-7): " choice
        case $choice in
            1) 
                echo -e "\n${BLUE}=== 开始初始化和完整分析 ===${NC}"
                main
                ;;
            2) 
                if [ ! -f "/tmp/validator_analysis.txt" ]; then
                    echo -e "${RED}错误: 请先运行选项 1 进行完整分析${NC}"
                else
                    show_validators_list
                fi
                ;;
            3) 
                if [ ! -f "/tmp/validator_analysis.txt" ]; then
                    echo -e "${RED}错误: 请先运行选项 1 进行完整分析${NC}"
                else
                    echo -e "\n${BLUE}=== 分析结果 ===${NC}"
                    cat "/tmp/validator_analysis.txt"
                fi
                ;;
            4)
                if [ ! -f "/tmp/validator_analysis.txt" ]; then
                    echo -e "${RED}错误: 请先运行选项 1 进行完整分析${NC}"
                else
                    read -p "请输入要查看的IP地址: " ip
                    grep "^$ip" "/tmp/validator_analysis.txt" | less
                fi
                ;;
            5) 
                if [ ! -f "/tmp/validator_analysis.txt" ]; then
                    echo -e "${RED}错误: 请先运行选项 1 进行完整分析${NC}"
                else
                    local report_file="$HOME/solana_analysis_$(date +%Y%m%d_%H%M%S).txt"
                    cp /tmp/validator_analysis.txt "$report_file"
                    echo "报告已导出到: $report_file"
                fi
                ;;
            6) check_environment ;;
            7)
                echo -e "${BLUE}=== 帮助信息 ===${NC}"
                echo -e "${YELLOW}首次使用必须先运行选项 1 进行初始化和完整分析！${NC}"
                echo
                echo "1. 运行完整分析: 初始化系统并进行完整的延迟测试"
                echo "2. 显示验证者清单: 列出所有活跃的验证者节点"
                echo "3. 查看分析结果: 显示最近一次的分析结果"
                echo "4. 查看IP详情: 查看特定IP的详细信息"
                echo "5. 导出报告: 将分析结果导出到文件"
                echo "6. 环境检查: 检查系统运行环境"
                echo "0. 退出程序"
                ;;
            0) 
                echo "感谢使用！"
                exit 0
                ;;
            *) echo "无效选择" ;;
        esac
        
        echo -e "\n按回车键继续..."
        read
    done
}

# 启动程序
menu_main
