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
        info "正在安装缺失组件: $cmd ..."
        if [[ "$cmd" == "docker" ]]; then
            curl -fsSL https://get.docker.com | bash -s docker >/dev/null 2>&1 || die "Docker 安装失败，请检查网络。"
        elif [[ "$cmd" == "docker-compose" ]]; then
            die "未检测到 docker-compose，请检查系统环境。"
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
                die "未能识别包管理器，无法安装 $cmd。"
            fi
        fi
        
        command -v "$cmd" >/dev/null 2>&1 || die "组件 $cmd 安装失败。"
        info "组件 $cmd 安装完成。"
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

check_deployed() {
    local wd=$(get_workdir)
    if [[ -z "$wd" ]]; then
        echo -e "\033[33m[提示] 未检测到 Forgejo 实例，请先执行 [1] 一键部署，或 [6] 恢复备份。\033[0m"
        sleep 2
        return 1
    fi
    return 0
}

deploy_forgejo() {
    info "== 启动 Forgejo 自动化部署 =="
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

    read -r -p "请输入 HTTP 访问端口 [默认: 3000]: " input_port
    local host_port=${input_port:-3000}
    
    read -r -p "请输入 Git SSH 协议端口 [默认: 2222]: " input_ssh_port
    local ssh_port=${input_ssh_port:-2222}

    info "正在生成配置与密钥..."
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

    info "正在启动容器 (首次需 1-3 分钟)..."
    $dc_cmd up -d || { err "启动失败，请检查端口是否被占用。"; return; }

    local server_ip=$(get_local_ip)

    echo -e "\n=================================================="
    echo -e "\033[32m部署完成！\033[0m"
    echo -e "访问地址: \033[36mhttp://${server_ip}:${host_port}\033[0m"
    echo -e "\033[33m提示: 请立即访问网页，首个注册用户即为超级管理员。\033[0m"
    echo -e "==================================================\n"
}

upgrade_service() {
    local workdir=$(get_workdir)
    cd "$workdir" || return
    info "正在拉取最新镜像并重建容器..."
    $(docker_compose_cmd) pull
    $(docker_compose_cmd) up -d
    info "升级完成！"
}

pause_service() {
    local workdir=$(get_workdir)
    cd "$workdir" && $(docker_compose_cmd) stop || true
    info "服务已停止。"
}

restart_service() {
    local workdir=$(get_workdir)
    cd "$workdir" && $(docker_compose_cmd) restart || true
    info "服务已重启。"
}

do_backup() {
    local workdir=$(get_workdir)
    require_cmd tar
    local backup_dir="${workdir}/backups"
    mkdir -p "$backup_dir"
    local timestamp=$(date +"%Y%m%d_%H%M%S")
    local backup_file="${backup_dir}/forgejo_backup_${timestamp}.tar.gz"
    
    info "开始执行备份..."
    cd "$workdir" || return
    
    $(docker_compose_cmd) stop >/dev/null 2>&1
    
    local target_files=$(ls -A | grep -E 'docker-compose.yml|\.env|data|postgres_data|github_accounts\.conf|forgejo_token\.conf' || true)
    if [[ -z "$target_files" ]]; then
        err "未找到核心数据，备份终止。"
        $(docker_compose_cmd) start >/dev/null 2>&1
        return
    fi
    
    tar -czf "$backup_file" $target_files
    
    $(docker_compose_cmd) start >/dev/null 2>&1
    
    cd "$backup_dir" || return
    ls -t forgejo_backup_*.tar.gz 2>/dev/null | awk 'NR>3' | xargs -I {} rm -f {}
    
    info "备份完毕。可用备份如下："
    for f in $(ls -t forgejo_backup_*.tar.gz 2>/dev/null); do
        local abs_path="${backup_dir}/${f}"
        local fsize=$(du -h "$f" | cut -f1)
        echo -e "  📦 \033[36m${abs_path}\033[0m (大小: ${fsize})"
    done
}

restore_backup() {
    info "== 恢复备份 =="
    require_cmd tar
    
    local default_backup=""
    local current_wd=$(get_workdir)
    local search_dir="${current_wd:-$DEFAULT_INSTALL_PATH}/backups"
    
    if [[ -d "$search_dir" ]]; then
        default_backup=$(ls -t "${search_dir}"/forgejo_backup_*.tar.gz 2>/dev/null | head -n 1 || true)
    fi
    
    local backup_path=""
    if [[ -n "$default_backup" ]]; then
        echo -e "检测到最新备份: \033[33m${default_backup}\033[0m"
        read -r -p "请输入备份文件路径 [直接回车使用默认]: " input_backup
        backup_path=${input_backup:-$default_backup}
    else
        read -r -p "请输入备份文件(.tar.gz)绝对路径: " backup_path
    fi
    
    if [[ ! -f "$backup_path" ]]; then 
        err "备份文件不存在。"
        return
    fi
    
    read -r -p "请输入恢复目标路径 [默认: $DEFAULT_INSTALL_PATH]: " input_path
    local target_dir=${input_path:-$DEFAULT_INSTALL_PATH}
    
    if [[ -d "$target_dir" && -f "$target_dir/docker-compose.yml" ]]; then
        warn "目标路径已存在实例，恢复将覆盖现有数据！"
        read -r -p "是否继续覆盖？(y/N): " force_override
        if [[ ! "$force_override" =~ ^[Yy]$ ]]; then
            info "已取消恢复。"
            return
        fi
        cd "$target_dir" && $(docker_compose_cmd) down >/dev/null 2>&1 || true
        rm -rf data postgres_data github_accounts.conf forgejo_token.conf
    fi
    
    mkdir -p "$target_dir"
    tar -xzf "$backup_path" -C "$target_dir" || { err "解压失败。"; return; }
    
    echo "$target_dir" > "/etc/forgejo_env"
    cd "$target_dir" || return
    
    chmod -R 777 data postgres_data || true
    
    $(docker_compose_cmd) up -d || { err "启动失败。"; return; }
    
    local server_ip=$(get_local_ip)
    local host_port=$(grep -oP '^SERVER_PORT=\K.*' .env || echo "3000")
    
    echo -e "\n=================================================="
    echo -e "\033[32m✅ 恢复完成！\033[0m"
    echo -e "访问地址: \033[36mhttp://${server_ip}:${host_port}\033[0m"
    echo -e "==================================================\n"
}

setup_auto_backup() {
    require_cmd crontab
    info "== 定时备份 =="

    local workdir=$(get_workdir)
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
        echo -e "\033[36m发现正在运行的定时任务:\033[0m"
        echo -e "\033[33m${existing_cron}\033[0m"
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
                info "已设置：每 ${min_interval} 分钟执行一次。"
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
        info "已设置：每天 ${cron_time} 执行一次。"

    elif [[ "$cron_type" == "3" ]]; then
        tmp_cron="$(mktemp)" || return
        crontab -l 2>/dev/null | sed "/^${CRON_TAG_BEGIN}$/,/^${CRON_TAG_END}$/d" > "$tmp_cron" || true
        crontab "$tmp_cron" 2>/dev/null || true
        rm -f "$tmp_cron" "$cron_script" 
        info "已删除定时备份任务。"
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

    info "定时备份设置完成。"
}

uninstall_service() {
    local workdir=$(get_workdir)
    echo -e "\033[31m⚠️ 警告：这将彻底摧毁所有容器、镜像及业务数据！\033[0m"
    read -r -p "确认完全卸载？(y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        info "操作已取消。"
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
    
    info "容器及数据已被彻底抹除。"
}

install_ftp(){
    clear
    require_cmd curl
    echo -e "\033[32m📂 FTP/SFTP 备份工具...\033[0m"
    bash <(curl -L https://raw.githubusercontent.com/hiapb/ftp/main/back.sh)
    sleep 2
    exit 0
}

github_sync_manager() {
    require_cmd jq
    require_cmd curl
    
    local workdir=$(get_workdir)
    local gh_conf="${workdir}/github_accounts.conf"
    local fg_conf="${workdir}/forgejo_token.conf"
    touch "$gh_conf" "$fg_conf"

    while true; do
        clear
        echo "==================================================="
        echo "              GitHub 账号同步管理               "
        echo "==================================================="
        echo "  1) 添加账号"
        echo "  2) 删除账号"
        echo "  3) 设置 Forgejo API Token"
        echo "  4) 同步仓库"
        echo "  0) 返回主菜单"
        echo "==================================================="
        read -r -p "请输入序号 [0-4]: " gh_choice
        
        case "$gh_choice" in
            1)
                read -r -p "请输入自定义名称 (如: 大号/外包号): " gh_alias
                read -r -p "请输入该账号的 GitHub 用户名: " gh_user
                read -r -p "请输入 GitHub PAT 密钥: " gh_pat
                sed -i "/^${gh_alias}:/d" "$gh_conf" 2>/dev/null || true
                echo "${gh_alias}:${gh_user}:${gh_pat}" >> "$gh_conf"
                info "账号 [${gh_alias}] 添加成功。"
                sleep 1
                ;;
            2)
                read -r -p "请输入要删除的自定义名称: " rm_alias
                sed -i "/^${rm_alias}:/d" "$gh_conf"
                info "账号 [${rm_alias}] 已删除。"
                sleep 1
                ;;
            3)
                echo -e "\033[33m提示：请在本地 Forgejo [设置]->[应用] 中生成带有 repo 权限的 API Token。\033[0m"
                read -r -p "请输入 Forgejo 管理员用户名: " fg_user
                read -r -p "请输入 Forgejo API Token: " fg_token
                echo "${fg_user}:${fg_token}" > "$fg_conf"
                info "Forgejo API Token 设置成功。"
                sleep 1
                ;;
            4)
                if [[ ! -s "$fg_conf" ]]; then
                    err "未检测到 Forgejo API Token，请先执行 [3] 设置。"
                    sleep 2
                    continue
                fi
                local local_fg_user=$(cut -d':' -f1 "$fg_conf")
                local local_fg_token=$(cut -d':' -f2 "$fg_conf")
                local host_port=$(cd "$workdir" && grep -oP '^SERVER_PORT=\K.*' .env || echo "3000")
                local local_api_base="http://127.0.0.1:${host_port}/api/v1"

                if [[ ! -s "$gh_conf" ]]; then
                    err "账号列表为空，请先执行 [1] 添加账号。"
                    sleep 2
                    continue
                fi

                echo "--- 当前账号列表 ---"
                cat "$gh_conf" | awk -F':' '{print $1 " (用户名: " $2 ")"}' | cat -n
                read -r -p "请选择要同步的账号序号: " acc_idx
                local selected_line=$(sed -n "${acc_idx}p" "$gh_conf")
                if [[ -z "$selected_line" ]]; then
                    err "输入无效。"
                    sleep 1
                    continue
                fi
                
                local current_gh_alias=$(echo "$selected_line" | cut -d':' -f1)
                local current_gh_user=$(echo "$selected_line" | cut -d':' -f2)
                local current_gh_pat=$(echo "$selected_line" | cut -d':' -f3)

                info "正在获取 [${current_gh_alias}] 的仓库列表..."
                local repos_json=$(curl -s -H "Authorization: token $current_gh_pat" "https://api.github.com/user/repos?per_page=100&affiliation=owner")
                local repo_count=$(echo "$repos_json" | jq '. | length')
                
                if [[ "$repo_count" == "0" || "$repo_count" == "" ]]; then
                    err "未找到任何仓库，或 PAT 密钥无效。"
                    sleep 2
                    continue
                fi
                
                info "共找到 $repo_count 个仓库。"
                echo " 同步方式:"
                echo "  1) 全部同步"
                echo "  2) 逐个询问同步"
                echo "  3) 指定仓库名称同步"
                read -r -p "请选择 [1/2/3]: " sync_mode

                if [[ "$sync_mode" != "1" && "$sync_mode" != "2" && "$sync_mode" != "3" ]]; then
                    err "非法的选项，已终止同步请求。"
                    sleep 2
                    continue
                fi

                local exclude_forks="y"
                if [[ "$sync_mode" == "1" || "$sync_mode" == "2" ]]; then
                    read -r -p "➤ 是否排除 Fork 的项目？(Y/n，默认排除): " ask_fork
                    if [[ "$ask_fork" == "n" || "$ask_fork" == "N" ]]; then
                        exclude_forks="n"
                    fi
                fi

                local keep_syncing="y"
                while [[ "$keep_syncing" == "y" || "$keep_syncing" == "Y" ]]; do
                    local target_repo_name=""
                    if [[ "$sync_mode" == "3" ]]; then
                        read -r -p "请输入您要精确同步的仓库名称: " target_repo_name
                        if [[ -z "$target_repo_name" ]]; then
                            err "仓库名称不能为空。"
                            sleep 1
                            continue
                        fi
                    fi

                    local matched_count=0

                    for (( i=0; i<$repo_count; i++ )); do
                        local r_name=$(echo "$repos_json" | jq -r ".[$i].name")
                        local r_url=$(echo "$repos_json" | jq -r ".[$i].clone_url")
                        local is_fork=$(echo "$repos_json" | jq -r ".[$i].fork")
                        
                        if [[ "$sync_mode" == "3" && "$r_name" != "$target_repo_name" ]]; then
                            continue
                        fi
                        
                        if [[ "$exclude_forks" == "y" && "$is_fork" == "true" && "$sync_mode" != "3" ]]; then
                            echo -e "   \033[35m[-] [Fork跳过] \033[36m$r_name\033[0m\033[0m"
                            continue
                        fi

                        matched_count=$((matched_count + 1))

                        local exist_code=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: token ${local_fg_token}" "${local_api_base}/repos/${local_fg_user}/${r_name}")
                        if [[ "$exist_code" == "200" ]]; then
                            echo -e "   \033[33m[-] [本地已存在] \033[36m$r_name\033[0m，自动跳过。\033[0m"
                            continue
                        fi

                        if [[ "$sync_mode" == "2" ]]; then
                            echo -e -n "➤ 是否同步仓库 [\033[36m${r_name}\033[0m] ? (y/n/q退出): "
                            read -r ask_sync
                            
                            if [[ "$ask_sync" == "q" || "$ask_sync" == "Q" ]]; then
                                info "已终止同步。"
                                keep_syncing="n"
                                break
                            fi
                            if [[ "$ask_sync" != "y" && "$ask_sync" != "Y" ]]; then
                                continue
                            fi
                        fi
                        
                        while true; do
                            info "正在同步 -> $r_name"
                            
                            local payload=$(jq -n \
                                --arg clone_addr "$r_url" \
                                --arg auth_token "$current_gh_pat" \
                                --arg repo_name "$r_name" \
                                --arg service "github" \
                                --arg repo_owner "$local_fg_user" \
                                '{clone_addr: $clone_addr, auth_token: $auth_token, repo_name: $repo_name, service: $service, mirror: false, repo_owner: $repo_owner}')

                            local http_code=$(curl -s -o /dev/null -w "%{http_code}" -X POST "${local_api_base}/repos/migrate" \
                                -H "Authorization: token ${local_fg_token}" \
                                -H "Content-Type: application/json" \
                                -d "$payload")

                            if [[ "$http_code" == "201" ]]; then
                                echo -e "   \033[32m[✓] $r_name 同步成功。\033[0m"
                                break
                            elif [[ "$http_code" == "409" ]]; then
                                echo -e "   \033[33m[-] 仓库 $r_name 已存在，跳过。\033[0m"
                                break
                            else
                                echo -e "   \033[31m[x] $r_name 同步失败，错误码: $http_code\033[0m"
                                echo -e -n "   ➤ 是否重新尝试同步该仓库? (y/n): "
                                read -r retry_ans
                                if [[ "$retry_ans" != "y" && "$retry_ans" != "Y" ]]; then
                                    break
                                fi
                            fi
                        done
                    done
                    
                    if [[ "$sync_mode" == "3" ]]; then
                        if [[ "$matched_count" == "0" ]]; then
                            warn "在 GitHub 账号 [${current_gh_alias}] 中未找到名为 [${target_repo_name}] 的仓库，请核对拼写。"
                        fi
                        echo -e -n "➤ 是否继续指定同步其他仓库？(y/n): "
                        read -r keep_syncing
                    else
                        keep_syncing="n"
                    fi
                done
                
                info "同步任务处理完毕！"
                read -r -p "按回车键返回..."
                ;;
            0)
                return
                ;;
            *)
                warn "无效的输入。"
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
    echo -e " 实例路径: \033[36m${wd:-未部署 (请先执行部署或恢复)}\033[0m"
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
    echo " 10) GitHub 账号同步管理"
    echo "  0) 退出脚本"
    echo "==================================================="
    
    read -r -p "请输入序号 [0-10]: " choice
    case "$choice" in
        1) deploy_forgejo ;;
        2) check_deployed && upgrade_service ;;
        3) check_deployed && pause_service ;;
        4) check_deployed && restart_service ;;
        5) check_deployed && do_backup ;;
        6) restore_backup ;;
        7) check_deployed && setup_auto_backup ;;
        8) check_deployed && uninstall_service ;;
        9) install_ftp ;;
        10) check_deployed && github_sync_manager ;;
        0) info "欢迎下次使用，再见!"; exit 0 ;;
        *) warn "无效的指令，请重新输入。" ;;
    esac
}

if [[ "${1:-}" == "run-backup" ]]; then
    do_backup
else
    if [[ $EUID -ne 0 ]]; then die "权限不足：请使用 root 权限执行脚本。"; fi
    while true; do
        main_menu
        echo ""
        read -r -p "➤ 按回车键返回主菜单..."
    done
fi
