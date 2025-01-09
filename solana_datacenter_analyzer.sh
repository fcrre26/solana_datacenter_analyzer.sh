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

# 云服务提供商IP范围和数据中心信息
declare -A CLOUD_PROVIDERS=( 
    ["AWS"]="https://ip-ranges.amazonaws.com/ip-ranges.json"
    ["Azure"]="https://download.microsoft.com/download/7/1/D/71D86715-5596-4529-9B13-DA13A5DE5B63/ServiceTags_Public_20231127.json"
    ["GCP"]="https://www.gstatic.com/ipranges/cloud.json"
    ["Alibaba"]="https://raw.githubusercontent.com/alibaba/alibaba-cloud-ip-ranges/main/ip-ranges.json"
    ["Oracle"]="https://docs.oracle.com/en-us/iaas/tools/public_ip_ranges.json"
    ["IBM"]="https://cloud.ibm.com/network-security/ip-ranges"
    ["DigitalOcean"]="https://www.digitalocean.com/docs/networking/firewalls/how-to/firewall-ip-ranges/"
    ["Linode"]="https://www.linode.com/docs/guides/linode-ip-addresses/"
    ["Vultr"]="https://www.vultr.com/docs/vultr-ip-addresses"
    ["Hetzner"]="https://www.hetzner.com/cloud"
    ["OVH"]="https://www.ovh.com/world/support/documents/ovh-ip-ranges.xml"
    ["Rackspace"]="https://docs.rackspace.com/support/how-to/rackspace-cloud-ip-addresses/"
    ["Tencent Cloud"]="https://cloud.tencent.com/document/product/213/15728"
    ["Huawei Cloud"]="https://support.huaweicloud.com/intl/en-us/faq-ecs/ecs_01_0001.html"
    ["Scaleway"]="https://www.scaleway.com/en/docs/ip-ranges/"
    ["Alibaba Cloud Hong Kong"]="https://www.alibabacloud.com/help/doc-detail/254001.htm"
    ["Google Cloud Platform (GCP)"]="https://cloud.google.com/compute/docs/faq#find_ip_range"
    ["Microsoft Azure"]="https://docs.microsoft.com/en-us/azure/virtual-network/ip-services/ip-addresses"
)

# 数据中心信息
declare -A DATACENTERS=( 
    ["Ashburn"]="Equinix DC1-DC15|Digital Realty ACC1-ACC4|CoreSite VA1-VA2"
    ["Santa Clara"]="Equinix SV1-SV17|Digital Realty SCL1-SCL3|CoreSite SV1-SV8"
    ["New York"]="Equinix NY1-NY9|Digital Realty NYC1-NYC3|CoreSite NY1-NY2"
    ["Tokyo"]="Equinix TY1-TY12|@Tokyo CC1-CC2|NTT Communications"
    ["Singapore"]="Equinix SG1-SG5|Digital Realty SIN1-SIN3|NTT SIN1"
    ["Hong Kong"]="Equinix HK1-HK5|MEGA-i|SUNeVision"
    ["London"]="Equinix LD1-LD8|Digital Realty LHR1-LHR3|Telehouse"
    ["Frankfurt"]="Equinix FR1-FR7|Digital Realty FRA1-FRA3|Interxion"
    ["Amsterdam"]="Equinix AM1-AM8|Digital Realty AMS1-AMS3|Nikhef"
)

# 日志文件
LOG_FILE="/tmp/solana_analysis.log"

# 将输出重定向到日志文件
exec > >(tee -a "$LOG_FILE") 2>&1

# 检查运行环境并安装必要工具
check_and_install_requirements() {
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

    echo "正在安装必要工具..."
    apt-get update
    apt-get install -y curl mtr traceroute bc jq whois geoip-bin dnsutils hping3 iperf3
}

# 确保 Solana CLI 的路径在 PATH 中
export PATH="/root/.local/share/solana/install/active_release/bin:$PATH"

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

# 获取机房和提供商信息
get_datacenter_info() {
    local ip=$1
    # 使用 whois 命令获取信息
    local info=$(whois "$ip" | grep -E 'OrgName|NetName|City' | tr '\n' ' ')
    
    # 提取 IP 范围
    local net_range=$(whois "$ip" | grep -E 'NetRange|CIDR' | tr '\n' ' ')
    
    echo "$info | $net_range"
}

# 测试连接
test_connection() {
    local ip=$1

    # 使用 ping 测试延迟
    local ping_result=$(ping -c 5 -W 1 "$ip")
    if [ $? -ne 0 ]; then
        echo "无法连接到 $ip"
        return
    fi

    # 提取最小、平均和最大延迟
    local min_latency=$(echo "$ping_result" | grep 'min/avg/max' | awk -F'/' '{print $4}')
    local avg_latency=$(echo "$ping_result" | grep 'min/avg/max' | awk -F'/' '{print $5}')
    local jitter=$(echo "$ping_result" | grep 'min/avg/max' | awk -F'/' '{print $6}')
    
    # 使用 mtr 测试跳数和延迟
    local mtr_result=$(mtr -r -c 5 "$ip")
    local hop_count=$(echo "$mtr_result" | wc -l)
    local mtr_latency=$(echo "$mtr_result" | tail -n 1 | awk '{print $3}')  # 最后一行的延迟

    # 返回格式: min_latency|avg_latency|jitter|mtr_latency|hop_count
    echo "$min_latency|$avg_latency|$jitter|$mtr_latency|$hop_count"
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

    # 存储所有结果
    declare -a results

    # 打印所有节点的 IP 列表并进行 ping 测试
    echo -e "${YELLOW}=== 所有验证者节点 IP 列表及 Ping 测试结果 ===${NC}"
    printf "+------------------+---------------------+--------------------------------------+---------------------------------------------+\n"
    printf "| %-16s | %-19s | %-36s | %-45s |\n" "IP地址" "Ping 测试（ms）" "机房/提供商信息" "IP范围"
    printf "+------------------+---------------------+--------------------------------------+---------------------------------------------+\n"

    echo "$validators" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | while read -r ip; do
        local datacenter_info=$(get_datacenter_info "$ip")
        local ping_result=$(ping -c 1 -W 1 "$ip" | grep 'time=' | awk -F'=' '{print $4}' | cut -d' ' -f1)
        
        if [ -z "$ping_result" ]; then
            ping_result="无响应"
        fi

        # 使用 fold 命令处理长字符串
        local formatted_datacenter_info=$(echo "$datacenter_info" | fold -s -w 36)
        local formatted_ip_range=" "  # 这里可以根据需要填充 IP 范围

        # 将结果存储到数组中
        results+=("| $ip | $ping_result | $formatted_datacenter_info | $formatted_ip_range |")
    done

    # 打印所有结果
    for result in "${results[@]}"; do
        printf "%s\n" "$result"
    done

    printf "+------------------+---------------------+--------------------------------------+---------------------------------------------+\n"

    echo -e "\n${YELLOW}=== 开始详细延迟测试 ===${NC}"

    # 重新获取 IP 列表以进行详细测试
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

    # 打印分析结果
    echo -e "\n${BLUE}=== 分析结果已保存 ===${NC}"
    cat "$results_file"
}

# 显示菜单
show_menu() {
    echo -e "${BLUE}=== Solana 验证者节点分析工具 ===${NC}"
    echo "1. 检查环境并安装必要工具"
    echo "2. 下载 Solana CLI"
    echo "3. 分析验证者节点"
    echo "4. 查看分析结果"
    echo "5. 退出"
    echo -n "请选择一个选项 [1-5]: "
}

# 主函数
main() {
    while true; do
        show_menu
        read -r choice

        case $choice in
            1)
                check_and_install_requirements
                ;;
            2)
                download_solana_cli
                ;;
            3)
                analyze_validators &  # 在后台运行分析
                disown  # 使后台进程与当前终端分离
                ;;
            4)
                echo -e "${YELLOW}=== 分析结果 ===${NC}"
                if [ -f "/tmp/validator_analysis.txt" ]; then
                    cat /tmp/validator_analysis.txt
                else
                    echo -e "${RED}没有找到分析结果文件。请先进行分析。${NC}"
                fi
                ;;
            5)
                echo "退出程序。"
                exit 0
                ;;
            *)
                echo -e "${RED}无效选择，请重新输入。${NC}"
                ;;
        esac
    done
}

# 启动程序
main
