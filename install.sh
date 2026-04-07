#!/usr/bin/env bash

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
DEFAULT_INSTALL_PATH="/opt/forgejo"

CRON_TAG_BEGIN="# FORGEJO_BACKUP_BEGIN"
CRON_TAG_END="# FORGEJO_BACKUP_END"
BACKUP_LOG="/var/log/forgejo_backup.log"

info() { echo -e "\033[32m[INFO]\033[0m $1"; }
warn() { echo -e "\033[33m[WARN]\033[0m $1" >&2; }
err()  { echo -e "\033[31m[ERROR]\033[0m $1" >&2; }
die()  { echo -e "\033[31m[FATAL]\033[0m $1" >&2; exit 1; }

require_cmd() {
    local cmd=$1
    if ! command -v "$cmd" >/dev/null 2>&1; then
        info "探测到缺失底层组件: $cmd，正在唤醒自动化装载引擎..."
        if [[ "$cmd" == "docker" ]]; then
            curl -fsSL https://get.docker.com | bash -s docker >/dev/null 2>&1 || die "Docker 核心引擎注入失败，请检查网络。"
        elif [[ "$cmd" == "docker-compose" ]]; then
            die "未检测到 docker-compose 调度器，此组件通常随 Docker 并发安装，请检查系统环境。"
        else
            if command -v apt-get >/dev/null 2>&1; then
                export DEBIAN_FRONTEND=noninteractive
                apt-get update -qq >/dev/null 2>&1
                apt-get install -y -qq "$cmd" >/dev/null 2>&1
            elif command -v yum >/dev/null 2>&1; then
                yum install -y -q "$cmd" >/dev/null 2>&1
            elif command -v apk >/dev/null 2>&1; then
                apk add -q "$cmd" >/dev/null 2>&1
            else
                die "未能识别宿主机包管理器，无法静默安装 $cmd。"
            fi
        fi
        
        command -v "$cmd" >/dev/null 2>&1 || die "组件 $cmd 强行挂载失败，可能存在进程死锁。"
        info "组件 $cmd 已无缝装载完毕。"
    fi
}

get_local_ip() {
    hostname -I | awk '{print $1}' || echo "127.0.0.1"
}

docker_compose_cmd() {
    if command -v docker-compose >/dev/null 2>&1; then
        echo "docker-compose"
    else
        echo "docker compose"
    fi
}

get_workdir() {
    if [[ -f "/etc/forgejo_env" ]]; then
        local dir=$(cat "/etc/forgejo_env")
        if [[ -d "$dir" ]]; then
            echo "$dir"
            return
        fi
    fi
    echo ""
}

deploy_forgejo() {
    info "== 启动 Forgejo 自动化部署编排 =="
    require_cmd curl
    require_cmd docker
    require_cmd openssl
    
    local dc_cmd=$(docker_compose_cmd)

    read -r -p "请输入安装路径 [默认: $DEFAULT_INSTALL_PATH]: " input_path
    local install_path=${input_path:-$DEFAULT_INSTALL_PATH}
    
    if [[ -d "$install_path" && -f "$install_path/docker-compose.yml" ]]; then
        err "该路径已存在部署实例，请先执行 [8] 卸载。"
        return 
    fi

    mkdir -p "$install_path"
    echo "$install_path" > "/etc/forgejo_env"
    cd "$install_path" || return

    read -r -p "请输入对外 HTTP 访问端口 [默认: 3000]: " input_port
    local host_port=${input_port:-3000}
    
    read -r -p "请输入 Git SSH 协议端口 [默认: 2222]: " input_ssh_port
    local ssh_port=${input_ssh_port:-2222}

    info "正在生成核心配置与高强度密钥..."
    local db_pass=$(openssl rand -hex 24)
    
    cat > .env <<EOF
SERVER_PORT=${host_port}
SSH_PORT=${ssh_port}
POSTGRES_PASSWORD=${db_pass}
EOF

    cat > docker-compose.yml <<'EOF'
version: '3.8'
services:
  server:
    image: codeberg.org/forgejo/forgejo:9
    container_name: forgejo
    environment:
      - USER_UID=1000
      - USER_GID=1000
      - FORGEJO__database__DB_TYPE=postgres
      - FORGEJO__database__HOST=db:5432
      - FORGEJO__database__NAME=forgejo
      - FORGEJO__database__USER=forgejo
      - FORGEJO__database__PASSWD=${POSTGRES_PASSWORD}
      - FORGEJO__server__HTTP_PORT=3000
      - FORGEJO__server__SSH_PORT=${SSH_PORT}
    restart: always
    networks:
      - forgejo_net
    volumes:
      - ./data:/data
      - /etc/timezone:/etc/timezone:ro
      - /etc/localtime:/etc/localtime:ro
    ports:
      - "${SERVER_PORT}:3000"
      - "${SSH_PORT}:22"
    depends_on:
      - db

  db:
    image: postgres:15-alpine
    container_name: forgejo_db
    restart: always
    environment:
      - POSTGRES_USER=forgejo
      - POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
      - POSTGRES_DB=forgejo
    networks:
      - forgejo_net
    volumes:
      - ./postgres_data:/var/lib/postgresql/data

networks:
  forgejo_net:
    driver: bridge
EOF

    mkdir -p data postgres_data
    chmod -R 777 data postgres_data

    info "正在拉起微服务矩阵 (首次拉取需 1-3 分钟)..."
    $dc_cmd up -d || { err "容器启动失败，请检查端口是否被占用。"; return; }

    local server_ip=$(get_local_ip)

    echo -e "\n=================================================="
    echo -e "\033[32m部署指令已下发！服务正在启动。\033[0m"
    echo -e "请务必在服务器防火墙中放行 \033[31m${host_port}\033[0m 和 \033[31m${ssh_port}\033[0m 端口！"
    echo -e "访问地址: \033[36mhttp://${server_ip}:${host_port}\033[0m"
    echo -e "\033[33m提示: 请立即访问网页，首个注册用户即为超级管理员。\033[0m"
    echo -e "==================================================\n"
}

upgrade_service() {
    local workdir=$(get_workdir)
    if [[ -z "$workdir" ]]; then
        err "未检测到运行环境，请先部署。"
        return
    fi
    cd "$workdir" || return
    info "正在拉取最新镜像并重建容器..."
    $(docker_compose_cmd) pull
    $(docker_compose_cmd) up -d
    info "平滑升级完成！"
}

pause_service() {
    local workdir=$(get_workdir)
    [[ -z "$workdir" ]] && return
    cd "$workdir" && $(docker_compose_cmd) stop || true
    info "服务已静默。"
}

restart_service() {
    local workdir=$(get_workdir)
    [[ -z "$workdir" ]] && return
    cd "$workdir" && $(docker_compose_cmd) restart || true
    info "服务已重启。"
}

do_backup() {
    local workdir=$(get_workdir)
    if [[ -z "$workdir" ]]; then
        err "未检测到部署环境，操作终止。"
        return
    fi
    
    require_cmd tar
    local backup_dir="${workdir}/backups"
    mkdir -p "$backup_dir"
    local timestamp=$(date +"%Y%m%d_%H%M%S")
    local backup_file="${backup_dir}/forgejo_backup_${timestamp}.tar.gz"
    
    info "开始提取全局物理快照..."
    cd "$workdir" || return
    
    $(docker_compose_cmd) stop >/dev/null 2>&1
    
    local target_files=$(ls -A | grep -E 'docker-compose.yml|\.env|data|postgres_data|github_accounts\.conf|forgejo_token\.conf' || true)
    if [[ -z "$target_files" ]]; then
        err "未发现有效业务卷，提取失败。"
        $(docker_compose_cmd) start >/dev/null 2>&1
        return
    fi
    
    tar -czf "$backup_file" $target_files
    
    $(docker_compose_cmd) start >/dev/null 2>&1
    
    cd "$backup_dir" || return
    ls -t forgejo_backup_*.tar.gz 2>/dev/null | awk 'NR>3' | xargs -I {} rm -f {}
    
    info "备份执行完毕。含 GitHub 密钥、数据库、代码资产的全量胶囊已生成："
    for f in $(ls -t forgejo_backup_*.tar.gz 2>/dev/null); do
        local abs_path="${backup_dir}/${f}"
        local fsize=$(du -h "$f" | cut -f1)
        echo -e "  📦 \033[36m${abs_path}\033[0m (大小: ${fsize})"
    done
}

restore_backup() {
    info "== 灾备恢复引擎 =="
    require_cmd tar
    
    local default_backup=""
    local current_wd=$(get_workdir)
    local search_dir="${current_wd:-$DEFAULT_INSTALL_PATH}/backups"
    
    if [[ -d "$search_dir" ]]; then
        default_backup=$(ls -t "${search_dir}"/forgejo_backup_*.tar.gz 2>/dev/null | head -n 1 || true)
    fi
    
    local backup_path=""
    if [[ -n "$default_backup" ]]; then
        echo -e "已嗅探到可用快照: \033[33m${default_backup}\033[0m"
        read -r -p "请输入备份文件路径 [直接回车使用默认]: " input_backup
        backup_path=${input_backup:-$default_backup}
    else
        read -r -p "请输入备份文件(.tar.gz)绝对路径: " backup_path
    fi
    
    if [[ ! -f "$backup_path" ]]; then 
        err "目标快照不存在或已损坏。"
        return
    fi
    
    read -r -p "请输入恢复目标路径 [默认: $DEFAULT_INSTALL_PATH]: " input_path
    local target_dir=${input_path:-$DEFAULT_INSTALL_PATH}
    
    if [[ -d "$target_dir" && -f "$target_dir/docker-compose.yml" ]]; then
        warn "目标路径存在旧星系，强行恢复将覆盖原有文明！"
        read -r -p "是否强制覆盖？(y/N): " force_override
        if [[ ! "$force_override" =~ ^[Yy]$ ]]; then
            info "已取消回滚。"
            return
        fi
        cd "$target_dir" && $(docker_compose_cmd) down >/dev/null 2>&1 || true
        rm -rf data postgres_data github_accounts.conf forgejo_token.conf
    fi
    
    mkdir -p "$target_dir"
    tar -xzf "$backup_path" -C "$target_dir" || { err "快照解压溃灭。"; return; }
    
    echo "$target_dir" > "/etc/forgejo_env"
    cd "$target_dir" || return
    
    chmod -R 777 data postgres_data || true
    
    $(docker_compose_cmd) up -d || { err "引擎点火失败。"; return; }
    
    local server_ip=$(get_local_ip)
    local host_port=$(grep -oP '^SERVER_PORT=\K.*' .env || echo "3000")
    
    echo -e "\n=================================================="
    echo -e "\033[32m✅ 资产快照已成功回滚注入！包含所有同步密钥配置。\033[0m"
    echo -e "访问地址: \033[36mhttp://${server_ip}:${host_port}\033[0m"
    echo -e "==================================================\n"
}

setup_auto_backup() {
    require_cmd crontab
    info "== 定时备份策略管控 =="

    local workdir=$(get_workdir)
    if [[ -z "$workdir" ]]; then
        err "未检测到部署环境，无法配置。"
        return
    fi

    local existing_cron=""
    local reset_cron=""
    local cron_type=""
    local cron_spec=""
    local min_interval=""
    local cron_time=""
    local hour=""
    local minute=""
    local tmp_cron=""
    
    local cron_script="${workdir}/cron_backup.sh"

    existing_cron="$(crontab -l 2>/dev/null | sed -n "/^${CRON_TAG_BEGIN}$/,/^${CRON_TAG_END}$/p" | grep -v "^#" || true)"

    if [[ -n "$existing_cron" ]]; then
        echo -e "\033[36m>>> 发现正在运行的定时任务:\033[0m"
        echo -e "\033[33m${existing_cron}\033[0m"
        echo -e "---------------------------------------------------"
        read -r -p "是否覆盖/重置？(y/N): " reset_cron
        if [[ ! "$reset_cron" =~ ^[Yy]$ ]]; then
            info "已保留当前配置。"
            return
        fi
    fi

    echo " 1) 按固定分钟步进备份（推荐：1/2/3/4/5/6/10/12/15/20/30）"
    echo " 2) 按每日固定时间点备份（例如：每天 04:30）"
    echo " 3) 删除当前的定时备份任务"
    read -r -p "请选择策略 [1/2/3]: " cron_type

    if [[ "$cron_type" == "1" ]]; then
        read -r -p "请输入间隔分钟数: " min_interval
        case "$min_interval" in
            1|2|3|4|5|6|10|12|15|20|30)
                cron_spec="*/${min_interval} * * * *"
                info "已下发指令：每 ${min_interval} 分钟执行一次。"
                ;;
            *)
                err "不支持的分钟间隔。"
                return
                ;;
        esac

    elif [[ "$cron_type" == "2" ]]; then
        read -r -p "请输入每天固定备份时间 (格式 HH:MM): " cron_time
        if [[ ! "$cron_time" =~ ^([0-1][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
            err "时间格式不正确。"
            return
        fi
        hour="${cron_time%:*}"
        minute="${cron_time#*:}"
        hour="$(echo "$hour" | sed 's/^0*//')"
        minute="$(echo "$minute" | sed 's/^0*//')"
        [[ -z "$hour" ]] && hour="0"
        [[ -z "$minute" ]] && minute="0"
        cron_spec="${minute} ${hour} * * *"
        info "已下发指令：每天 ${cron_time} 执行一次。"

    elif [[ "$cron_type" == "3" ]]; then
        tmp_cron="$(mktemp)" || return
        crontab -l 2>/dev/null | sed "/^${CRON_TAG_BEGIN}$/,/^${CRON_TAG_END}$/d" > "$tmp_cron" || true
        crontab "$tmp_cron" 2>/dev/null || true
        rm -f "$tmp_cron" "$cron_script" 
        info "定时调度链已被彻底剥离。"
        return
    else
        err "无效的选择。"
        return
    fi

    cat > "$cron_script" << EOF
#!/usr/bin/env bash
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:\$PATH"
WORKDIR="${workdir}"
cd "\$WORKDIR" || exit 1

BACKUP_DIR="\${WORKDIR}/backups"
mkdir -p "\$BACKUP_DIR"
TIMESTAMP=\$(date +"%Y%m%d_%H%M%S")
BACKUP_FILE="\${BACKUP_DIR}/forgejo_backup_\${TIMESTAMP}.tar.gz"

if command -v docker-compose >/dev/null 2>&1; then
    DC_CMD="docker-compose"
else
    DC_CMD="docker compose"
fi

\$DC_CMD stop >/dev/null 2>&1

TARGET_FILES=\$(ls -A | grep -E 'docker-compose.yml|\.env|data|postgres_data|github_accounts\.conf|forgejo_token\.conf' || true)
if [[ -n "\$TARGET_FILES" ]]; then
    tar -czf "\$BACKUP_FILE" \$TARGET_FILES
    \$DC_CMD start >/dev/null 2>&1
    cd "\$BACKUP_DIR" || exit 1
    ls -t forgejo_backup_*.tar.gz 2>/dev/null | awk 'NR>3' | xargs -I {} rm -f {}
else
    \$DC_CMD start >/dev/null 2>&1
fi
EOF
    chmod +x "$cron_script"

    tmp_cron="$(mktemp)" || return
    crontab -l 2>/dev/null | sed "/^${CRON_TAG_BEGIN}$/,/^${CRON_TAG_END}$/d" > "$tmp_cron" || true
    cat >> "$tmp_cron" <<EOF
${CRON_TAG_BEGIN}
${cron_spec} bash ${cron_script} >> ${BACKUP_LOG} 2>&1
${CRON_TAG_END}
EOF
    crontab "$tmp_cron" 2>/dev/null
    rm -f "$tmp_cron"

    info "调度链路锚定完毕。"
}

uninstall_service() {
    local workdir=$(get_workdir)
    if [[ -z "$workdir" ]]; then
        err "未检测到活跃实例，无法执行摧毁。"
        return
    fi
    
    echo -e "\033[31m⚠️ 焦土级警告：此操作将执行 --rmi all 和卷删除，彻底粉碎容器、镜像层及所有物理账本！\033[0m"
    read -r -p "请再次确认是否化为灰烬？(y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        info "终止核爆倒计时。"
        return
    fi
    
    cd "$workdir" || return
    $(docker_compose_cmd) down -v --rmi all >/dev/null 2>&1 || true
    
    cd /
    rm -rf "$workdir" || true
    rm -f "/etc/forgejo_env" || true
    
    local tmp_cron=$(mktemp)
    crontab -l 2>/dev/null | sed "/^${CRON_TAG_BEGIN}$/,/^${CRON_TAG_END}$/d" > "$tmp_cron" || true
    crontab "$tmp_cron" 2>/dev/null || true
    rm -f "$tmp_cron" || true
    
    info "物理销毁完毕，环境已绝对净化。"
}

install_ftp(){
    clear
    require_cmd curl
    echo -e "\033[32m📂 触发外部存储传送门...\033[0m"
    bash <(curl -L https://raw.githubusercontent.com/hiapb/ftp/main/back.sh)
    sleep 2
    exit 0
}

github_sync_manager() {
    require_cmd jq
    require_cmd curl
    
    local workdir=$(get_workdir)
    if [[ -z "$workdir" ]]; then
        err "未检测到主基地运行环境，请先执行部署。"
        return
    fi
    
    local gh_conf="${workdir}/github_accounts.conf"
    local fg_conf="${workdir}/forgejo_token.conf"
    touch "$gh_conf" "$fg_conf"

    while true; do
        clear
        echo "==================================================="
        echo "              GitHub 多账号同步中心               "
        echo "==================================================="
        echo "  1) 录入 GitHub 账号 (需 PAT Token)"
        echo "  2) 剥离 GitHub 账号"
        echo "  3) 锚定本地 Forgejo API Token"
        echo "  4) 执行跨星系仓库牵引"
        echo "  0) 撤回主菜单"
        echo "==================================================="
        read -r -p "下达指令 [0-4]: " gh_choice
        
        case "$gh_choice" in
            1)
                read -r -p "请输入 GitHub 用户名: " gh_user
                read -r -p "请输入该账号的 PAT 密钥: " gh_pat
                if grep -q "^${gh_user}:" "$gh_conf"; then
                    sed -i "/^${gh_user}:/d" "$gh_conf"
                fi
                echo "${gh_user}:${gh_pat}" >> "$gh_conf"
                info "账号 $gh_user 的量子纠缠已建立。"
                sleep 1
                ;;
            2)
                read -r -p "请输入要剥离的 GitHub 用户名: " rm_user
                sed -i "/^${rm_user}:/d" "$gh_conf"
                info "账号 $rm_user 的链接已被切断。"
                sleep 1
                ;;
            3)
                echo -e "\033[33m前置：请前往本地 Forgejo [设置]->[应用] 生成 repo 权限令牌。\033[0m"
                read -r -p "请输入 Forgejo 管理员用户名: " fg_user
                read -r -p "请输入 Forgejo API Token: " fg_token
                echo "${fg_user}:${fg_token}" > "$fg_conf"
                info "主基地中枢令牌已锁定。"
                sleep 1
                ;;
            4)
                if [[ ! -s "$fg_conf" ]]; then
                    err "未检测到中枢令牌，请先执行 [3]。"
                    sleep 2
                    continue
                fi
                local local_fg_user=$(cut -d':' -f1 "$fg_conf")
                local local_fg_token=$(cut -d':' -f2 "$fg_conf")
                local host_port=$(cd "$workdir" && grep -oP '^SERVER_PORT=\K.*' .env || echo "3000")
                local local_api_base="http://127.0.0.1:${host_port}/api/v1"

                if [[ ! -s "$gh_conf" ]]; then
                    err "探测列表为空，请先录入异星节点。"
                    sleep 2
                    continue
                fi

                echo "--- 当前锁定的异星节点列表 ---"
                cat "$gh_conf" | cut -d':' -f1 | cat -n
                read -r -p "请指定要牵引的节点序号: " acc_idx
                local selected_line=$(sed -n "${acc_idx}p" "$gh_conf")
                if [[ -z "$selected_line" ]]; then
                    err "越界输入。"
                    sleep 1
                    continue
                fi
                
                local current_gh_user=$(echo "$selected_line" | cut -d':' -f1)
                local current_gh_pat=$(echo "$selected_line" | cut -d':' -f2)

                echo "正在向 $current_gh_user 辐射探测波段..."
                local repos_json=$(curl -s -H "Authorization: token $current_gh_pat" "https://api.github.com/user/repos?per_page=100&affiliation=owner")
                local repo_count=$(echo "$repos_json" | jq '. | length')
                
                if [[ "$repo_count" == "0" || "$repo_count" == "" ]]; then
                    err "该节点没有反馈任何物资，或令牌权限衰减。"
                    sleep 2
                    continue
                fi
                
                info "雷达反馈：扫描到 $repo_count 个高能资源包。"
                echo " 牵引策略:"
                echo "  1) 无人值守全量吞噬"
                echo "  2) 手工点选精确制导"
                read -r -p "确定执行路径 [1/2]: " sync_mode

                for (( i=0; i<$repo_count; i++ )); do
                    local r_name=$(echo "$repos_json" | jq -r ".[$i].name")
                    local r_url=$(echo "$repos_json" | jq -r ".[$i].clone_url")
                    
                    if [[ "$sync_mode" == "2" ]]; then
                        read -r -p "➤ 是否跨界跳跃仓库 [\033[36m$r_name\033[0m] ? (y/n/q中止): " ask_sync
                        if [[ "$ask_sync" == "q" || "$ask_sync" == "Q" ]]; then
                            info "引力波发生器已强行关停。"
                            break
                        fi
                        if [[ "$ask_sync" != "y" && "$ask_sync" != "Y" ]]; then
                            continue
                        fi
                    fi
                    
                    info "引擎正在接管流管束 -> $r_name"
                    local payload=$(jq -n \
                        --arg clone_addr "$r_url" \
                        --arg auth_token "$current_gh_pat" \
                        --arg repo_name "$r_name" \
                        --arg service "github" \
                        '{clone_addr: $clone_addr, auth_token: $auth_token, repo_name: $repo_name, service: $service, mirror: false}')

                    local http_code=$(curl -s -o /dev/null -w "%{http_code}" -X POST "${local_api_base}/repos/migrate" \
                        -H "Authorization: token ${local_fg_token}" \
                        -H "Content-Type: application/json" \
                        -d "$payload")

                    if [[ "$http_code" == "201" ]]; then
                        echo -e "   \033[32m[✓] $r_name 实体重塑完成，基因序列完整。\033[0m"
                    elif [[ "$http_code" == "409" ]]; then
                        echo -e "   \033[33m[-] 本地时间线已存在该实体，剥离。\033[0m"
                    else
                        echo -e "   \033[31m[x] $r_name 跃迁失败，空间断层报错码: $http_code\033[0m"
                    fi

                    if [[ "$sync_mode" == "2" && $((i + 1)) -lt $repo_count ]]; then
                        read -r -p "    回车进入下一序列，输入 'q' 阻断充能..." ask_continue
                        if [[ "$ask_continue" == "q" || "$ask_continue" == "Q" ]]; then
                            info "队列处理强行干预跳出。"
                            break
                        fi
                    fi
                done
                
                info "本轮迁徙战役顺利结束。"
                read -r -p "按回车键撤离战场..."
                ;;
            0)
                return
                ;;
            *)
                warn "逻辑冲突，拒绝执行。"
                sleep 1
                ;;
        esac
    done
}

main_menu() {
    clear
    echo "==================================================="
    echo "                 Forgejo 一键管理                 "
    echo "==================================================="
    local wd=$(get_workdir)
    echo -e " 实例运行路径: \033[36m${wd:-未部署}\033[0m"
    echo "---------------------------------------------------"
    echo "  1) 一键部署"
    echo "  2) 升级服务"
    echo "  3) 停止服务"
    echo "  4) 重启服务"
    echo "  5) 手动备份"
    echo "  6) 恢复备份"
    echo "  7) 定时备份"
    echo "  8) 完全卸载"
    echo "  9) 📂 FTP/SFTP 备份工具"
    echo " 10) 🐙 GitHub 多账号同步中心"
    echo "  0) 退出脚本"
    echo "==================================================="
    
    read -r -p "请输入操作序号 [0-10]: " choice
    case "$choice" in
        1) deploy_forgejo ;;
        2) upgrade_service ;;
        3) pause_service ;;
        4) restart_service ;;
        5) do_backup ;;
        6) restore_backup ;;
        7) setup_auto_backup ;;
        8) uninstall_service ;;
        9) install_ftp ;;
        10) github_sync_manager ;;
        0) info "通信切断，随时待命。"; exit 0 ;;
        *) warn "无效的指令，请重新输入。" ;;
    esac
}

if [[ "${1:-}" == "run-backup" ]]; then
    do_backup
else
    if [[ $EUID -ne 0 ]]; then die "权限收敛：系统拒绝普通权限访问，请使用 Root。"; fi
    while true; do
        main_menu
        echo ""
        read -r -p "➤ 按回车键返回主菜单..."
    done
fi
