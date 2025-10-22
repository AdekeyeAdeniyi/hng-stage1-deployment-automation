#!/bin/bash

################################################################################
# Automated Docker Deployment Script
# Description: ...
# Author: DevOps Automation
# Version: 1.0.0
################################################################################

#Safety Flags
set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Global variables
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_FILE="${SCRIPT_DIR}/deploy_$(date +%Y%m%d_%H%M%S).log"
CLEANUP_MODE=false
TEMP_DIR=""

################################################################################
# Logging Functions
################################################################################

log() {
    local level=$1
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${timestamp} [${level}] ${message}" | tee -a "${LOG_FILE}"
}

log_info() {
    echo -e "${BLUE}[INFO]${NC} $*" | tee -a "${LOG_FILE}"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*" | tee -a "${LOG_FILE}"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $*" | tee -a "${LOG_FILE}"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" | tee -a "${LOG_FILE}"
}

################################################################################
# Error Handling
################################################################################

cleanup() {
    local exit_code=$?
    if [ -n "${TEMP_DIR}" ] && [ -d "${TEMP_DIR}" ]; then
        log_info "Cleaning up temporary directory: ${TEMP_DIR}"
        rm -rf "${TEMP_DIR}"
    fi

    if [ ${exit_code} -ne 0 ]; then
        log_error "Script failed with exit code ${exit_code}"
        log_error "Check log file: ${LOG_FILE}"
    fi

    exit ${exit_code}
}

trap cleanup EXIT INT TERM

error_exit() {
    log_error "$1"
    exit "${2:-1}"
}

################################################################################
# Validation Functions
################################################################################

validate_url() {
    local url=$1
    if [[ ! "$url" =~ ^https?:// ]]; then
        return 1
    fi
    return 0
}

validate_ip() {
    local ip=$1
    if [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        return 0
    fi
    return 1
}

validate_port() {
    local port=$1
    if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
        return 0
    fi
    return 1
}

validate_ssh_key() {
    local key_path=$1
    if [ ! -f "$key_path" ]; then
        return 1
    fi

    # Check if file is a valid SSH key
    if ssh-keygen -l -f "$key_path" &>/dev/null; then
        return 0
    fi
    return 1
}

################################################################################
# User Input Collection
################################################################################

collect_parameters() {
    log_info "=== Collecting Deployment Parameters ==="

    # Git Repository URL
    while true; do
        read -p "Enter Git Repository URL: " GIT_REPO_URL
        if validate_url "$GIT_REPO_URL"; then
            log_success "Valid repository URL provided"
            break
        else
            log_error "Invalid URL format. Please use http:// or https://"
        fi
    done

    # Personal Access Token
    read -sp "Enter Personal Access Token (PAT): " GIT_PAT
    echo ""
    if [ -z "$GIT_PAT" ]; then
        error_exit "PAT cannot be empty" 2
    fi
    log_success "PAT received"

    # Branch name
    read -p "Enter branch name [default: main]: " GIT_BRANCH
    GIT_BRANCH=${GIT_BRANCH:-main}
    log_info "Using branch: ${GIT_BRANCH}"

    # Remote server username
    read -p "Enter remote server username: " REMOTE_USER
    if [ -z "$REMOTE_USER" ]; then
        error_exit "Username cannot be empty" 2
    fi

    # Remote server IP
    while true; do
        read -p "Enter remote server IP address: " REMOTE_IP
        if validate_ip "$REMOTE_IP"; then
            log_success "Valid IP address provided"
            break
        else
            log_error "Invalid IP address format"
        fi
    done

    # SSH key path
    while true; do
        read -p "Enter SSH private key path [default: ~/.ssh/id_rsa]: " SSH_KEY_PATH
        SSH_KEY_PATH=${SSH_KEY_PATH:-~/.ssh/id_rsa}
        SSH_KEY_PATH="${SSH_KEY_PATH/#\~/$HOME}"

        if validate_ssh_key "$SSH_KEY_PATH"; then
            log_success "Valid SSH key found"
            break
        else
            log_error "Invalid or missing SSH key at: ${SSH_KEY_PATH}"
        fi
    done

    # Application port
    while true; do
        read -p "Enter application internal port: " APP_PORT
        if validate_port "$APP_PORT"; then
            log_success "Valid port number provided"
            break
        else
            log_error "Invalid port number (must be 1-65535)"
        fi
    done

    # Domain/App name for Nginx
    read -p "Enter domain or app name for Nginx config: " APP_NAME
    APP_NAME=${APP_NAME:-myapp}
    APP_NAME=$(echo "$APP_NAME" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g')

    log_success "All parameters collected successfully"
}

################################################################################
# Git Operations
################################################################################

clone_repository() {
    log_info "=== Cloning Repository ==="

    # Create temporary directory
    TEMP_DIR=$(mktemp -d)
    cd "${TEMP_DIR}"

    # Extract repository name
    REPO_NAME=$(basename "${GIT_REPO_URL}" .git)
    PROJECT_DIR="${TEMP_DIR}/${REPO_NAME}"

    # Prepare authenticated URL
    local auth_url
    if [[ "$GIT_REPO_URL" =~ ^https:// ]]; then
        auth_url=$(echo "$GIT_REPO_URL" | sed "s|https://|https://${GIT_PAT}@|")
    else
        auth_url="https://${GIT_PAT}@${GIT_REPO_URL#*://}"
    fi

    if [ -d "${PROJECT_DIR}" ]; then
        log_info "Repository already exists, pulling latest changes..."
        cd "${PROJECT_DIR}"
        git pull origin "${GIT_BRANCH}" 2>&1 | tee -a "${LOG_FILE}" || error_exit "Failed to pull repository" 3
    else
        log_info "Cloning repository..."
        git clone -b "${GIT_BRANCH}" "${auth_url}" "${PROJECT_DIR}" 2>&1 | tee -a "${LOG_FILE}" || error_exit "Failed to clone repository" 3
        cd "${PROJECT_DIR}"
    fi

    log_success "Repository cloned/updated successfully"
    log_info "Current directory: $(pwd)"
}

verify_docker_files() {
    log_info "=== Verifying Docker Configuration Files ==="

    if [ -f "Dockerfile" ]; then
        log_success "Dockerfile found"
        DOCKER_FILE_EXISTS=true
    else
        log_warning "Dockerfile not found"
        DOCKER_FILE_EXISTS=false
    fi

    if [ -f "docker-compose.yml" ] || [ -f "docker-compose.yaml" ]; then
        log_success "docker-compose.yml found"
        COMPOSE_FILE_EXISTS=true
        COMPOSE_FILE=$([ -f "docker-compose.yml" ] && echo "docker-compose.yml" || echo "docker-compose.yaml")
    else
        log_warning "docker-compose.yml not found"
        COMPOSE_FILE_EXISTS=false
    fi

    if [ "$DOCKER_FILE_EXISTS" = false ] && [ "$COMPOSE_FILE_EXISTS" = false ]; then
        error_exit "Neither Dockerfile nor docker-compose.yml found in repository" 4
    fi

    log_success "Docker configuration files verified"
}

################################################################################
# SSH Connection Functions
################################################################################

test_ssh_connection() {
    log_info "=== Testing SSH Connection ==="

    if ssh -i "${SSH_KEY_PATH}" -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
        "${REMOTE_USER}@${REMOTE_IP}" "echo 'SSH connection successful'" 2>&1 | tee -a "${LOG_FILE}"; then
        log_success "SSH connection established successfully"
        return 0
    else
        error_exit "Failed to establish SSH connection" 5
    fi
}

remote_execute() {
    local command=$1
    ssh -i "${SSH_KEY_PATH}" -o StrictHostKeyChecking=no \
        "${REMOTE_USER}@${REMOTE_IP}" "${command}" 2>&1 | tee -a "${LOG_FILE}"
    return ${PIPESTATUS[0]}
}

################################################################################
# Remote Environment Setup
################################################################################

setup_remote_environment() {
    log_info "=== Setting Up Remote Environment ==="

    log_info "Updating system packages..."
    remote_execute "sudo apt-get update -y" || log_warning "Failed to update packages"

    log_info "Installing Docker..."
    remote_execute "
        if ! command -v docker &> /dev/null; then
            curl -fsSL https://get.docker.com -o get-docker.sh
            sudo sh get-docker.sh
            rm get-docker.sh
            sudo systemctl enable docker
            sudo systemctl start docker
            echo 'Docker installed successfully'
        else
            echo 'Docker already installed'
        fi
    " || error_exit "Failed to install Docker" 6

    log_info "Installing Docker Compose..."
    remote_execute "
        if ! command -v docker-compose &> /dev/null; then
            sudo curl -L \"https://github.com/docker/compose/releases/latest/download/docker-compose-\$(uname -s)-\$(uname -m)\" -o /usr/local/bin/docker-compose
            sudo chmod +x /usr/local/bin/docker-compose
            echo 'Docker Compose installed successfully'
        else
            echo 'Docker Compose already installed'
        fi
    " || error_exit "Failed to install Docker Compose" 6

    log_info "Installing Nginx..."
    remote_execute "
        if ! command -v nginx &> /dev/null; then
            sudo apt-get install -y nginx
            sudo systemctl enable nginx
            sudo systemctl start nginx
            echo 'Nginx installed successfully'
        else
            echo 'Nginx already installed'
        fi
    " || error_exit "Failed to install Nginx" 6

    log_info "Adding user to Docker group..."
    remote_execute "
        sudo usermod -aG docker ${REMOTE_USER}
        echo 'User added to Docker group'
    "

    log_info "Verifying installations..."
    remote_execute "
        echo 'Docker version:'
        docker --version
        echo 'Docker Compose version:'
        docker-compose --version
        echo 'Nginx version:'
        nginx -v
    " || log_warning "Failed to verify some installations"

    log_success "Remote environment setup completed"
}

################################################################################
# File Transfer and Deployment
################################################################################

transfer_files() {
    log_info "=== Transferring Project Files ==="

    local remote_dir="/home/${REMOTE_USER}/deployments/${APP_NAME}"

    # Create remote directory
    remote_execute "mkdir -p ${remote_dir}"

    # Transfer files using rsync
    log_info "Syncing files to remote server..."
    rsync -avz --progress -e "ssh -i ${SSH_KEY_PATH} -o StrictHostKeyChecking=no" \
        "${PROJECT_DIR}/" "${REMOTE_USER}@${REMOTE_IP}:${remote_dir}/" 2>&1 | tee -a "${LOG_FILE}" || \
        error_exit "Failed to transfer files" 7

    REMOTE_PROJECT_DIR="${remote_dir}"
    log_success "Files transferred successfully to ${REMOTE_PROJECT_DIR}"
}

deploy_application() {
    log_info "=== Deploying Application ==="

    # Stop and remove existing containers
    log_info "Stopping existing containers (if any)..."
    remote_execute "
        cd ${REMOTE_PROJECT_DIR}
        docker ps -a | grep ${APP_NAME} | awk '{print \$1}' | xargs -r docker stop
        docker ps -a | grep ${APP_NAME} | awk '{print \$1}' | xargs -r docker rm
    " || log_warning "No existing containers to stop"

    if [ "$COMPOSE_FILE_EXISTS" = true ]; then
        log_info "Deploying with Docker Compose..."
        remote_execute "
            cd ${REMOTE_PROJECT_DIR}
            docker-compose -f ${COMPOSE_FILE} down 2>/dev/null || true
            docker-compose -f ${COMPOSE_FILE} up -d --build
        " || error_exit "Failed to deploy with Docker Compose" 8
    elif [ "$DOCKER_FILE_EXISTS" = true ]; then
        log_info "Building Docker image..."
        remote_execute "
            cd ${REMOTE_PROJECT_DIR}
            docker build -t ${APP_NAME}:latest .
        " || error_exit "Failed to build Docker image" 8

        log_info "Running Docker container..."
        remote_execute "
            docker run -d --name ${APP_NAME} \
                --restart unless-stopped \
                -p ${APP_PORT}:${APP_PORT} \
                ${APP_NAME}:latest
        " || error_exit "Failed to run Docker container" 8
    fi

    log_success "Application deployed successfully"
}

validate_deployment() {
    log_info "=== Validating Deployment ==="

    sleep 5  # Wait for container to start

    log_info "Checking Docker service status..."
    remote_execute "sudo systemctl is-active docker" || error_exit "Docker service is not running" 9

    log_info "Checking container status..."
    if remote_execute "docker ps | grep ${APP_NAME}"; then
        log_success "Container is running"
    else
        log_error "Container is not running. Checking logs..."
        remote_execute "docker logs ${APP_NAME} 2>&1 | tail -20"
        error_exit "Container failed to start" 9
    fi

    log_info "Testing application endpoint..."
    if remote_execute "curl -f http://localhost:${APP_PORT} -o /dev/null -s -w '%{http_code}\n' || echo 'Connection failed'"; then
        log_success "Application is responding"
    else
        log_warning "Application may not be ready yet or not responding on port ${APP_PORT}"
    fi

    log_success "Deployment validation completed"
}

################################################################################
# Nginx Configuration
################################################################################

configure_nginx() {
    log_info "=== Configuring Nginx Reverse Proxy ==="

    local nginx_config="/etc/nginx/sites-available/${APP_NAME}"
    local nginx_enabled="/etc/nginx/sites-enabled/${APP_NAME}"

    log_info "Creating Nginx configuration..."
    remote_execute "
        sudo tee ${nginx_config} > /dev/null <<'NGINX_EOF'
server {
    listen 80;
    server_name _;

    client_max_body_size 100M;

    location / {
        proxy_pass http://localhost:${APP_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_cache_bypass \$http_upgrade;
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }

    # Health check endpoint
    location /health {
        access_log off;
        return 200 'OK';
        add_header Content-Type text/plain;
    }
}
NGINX_EOF
    " || error_exit "Failed to create Nginx configuration" 10

    log_info "Enabling Nginx site..."
    remote_execute "
        sudo ln -sf ${nginx_config} ${nginx_enabled}
        sudo rm -f /etc/nginx/sites-enabled/default
    " || log_warning "Failed to enable site or remove default"

    log_info "Testing Nginx configuration..."
    remote_execute "sudo nginx -t" || error_exit "Nginx configuration test failed" 10

    log_info "Reloading Nginx..."
    remote_execute "sudo systemctl reload nginx" || error_exit "Failed to reload Nginx" 10

    log_success "Nginx configured and reloaded successfully"
}

validate_nginx() {
    log_info "=== Validating Nginx Setup ==="

    log_info "Checking Nginx status..."
    remote_execute "sudo systemctl is-active nginx" || error_exit "Nginx is not running" 11

    log_info "Testing reverse proxy..."
    sleep 2
    if remote_execute "curl -f http://localhost -o /dev/null -s -w 'HTTP Status: %{http_code}\n'"; then
        log_success "Nginx reverse proxy is working"
    else
        log_warning "Nginx proxy may not be fully configured"
    fi

    log_info "Testing external access..."
    if curl -f "http://${REMOTE_IP}" -o /dev/null -s -w "HTTP Status: %{http_code}\n" 2>&1 | tee -a "${LOG_FILE}"; then
        log_success "Application is accessible externally at http://${REMOTE_IP}"
    else
        log_warning "External access test failed. Check firewall settings."
    fi

    log_success "Nginx validation completed"
}

################################################################################
# Cleanup Functions
################################################################################

cleanup_deployment() {
    log_info "=== Cleaning Up Deployment ==="

    read -p "Are you sure you want to remove all deployed resources? (yes/no): " confirm
    if [ "$confirm" != "yes" ]; then
        log_info "Cleanup cancelled"
        return
    fi

    log_info "Stopping and removing containers..."
    remote_execute "
        docker stop ${APP_NAME} 2>/dev/null || true
        docker rm ${APP_NAME} 2>/dev/null || true
        cd ${REMOTE_PROJECT_DIR} && docker-compose down 2>/dev/null || true
    "

    log_info "Removing images..."
    remote_execute "docker rmi ${APP_NAME}:latest 2>/dev/null || true"

    log_info "Removing Nginx configuration..."
    remote_execute "
        sudo rm -f /etc/nginx/sites-enabled/${APP_NAME}
        sudo rm -f /etc/nginx/sites-available/${APP_NAME}
        sudo systemctl reload nginx
    "

    log_info "Removing project files..."
    remote_execute "rm -rf ${REMOTE_PROJECT_DIR}"

    log_success "Cleanup completed"
}

################################################################################
# Main Function
################################################################################

display_banner() {
    echo -e "${BLUE}"
    cat << "EOF"
╔══════════════════════════════════════════════════════════════╗
║          Automated Docker Deployment Script v1.0            ║
║                                                              ║
║  Deploy containerized applications to remote servers with   ║
║  automated Nginx reverse proxy configuration                ║
╚══════════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
}

display_summary() {
    log_info ""
    log_info "=== Deployment Summary ==="
    log_info "Repository: ${GIT_REPO_URL}"
    log_info "Branch: ${GIT_BRANCH}"
    log_info "Remote Server: ${REMOTE_USER}@${REMOTE_IP}"
    log_info "Application: ${APP_NAME}"
    log_info "Internal Port: ${APP_PORT}"
    log_info "External URL: http://${REMOTE_IP}"
    log_info "Log File: ${LOG_FILE}"
    log_info ""
    log_success "Deployment completed successfully!"
    log_info ""
    log_info "Next steps:"
    log_info "1. Access your application at: http://${REMOTE_IP}"
    log_info "2. Configure DNS if using a domain name"
    log_info "3. Set up SSL certificate (e.g., using Let's Encrypt)"
    log_info "4. Review logs: ${LOG_FILE}"
}

main() {
    display_banner

    # Parse command line arguments
    if [ "${1:-}" = "--cleanup" ]; then
        CLEANUP_MODE=true
        collect_parameters
        test_ssh_connection
        cleanup_deployment
        exit 0
    fi

    log_info "Starting deployment process at $(date)"
    log_info "Log file: ${LOG_FILE}"

    # Step 1: Collect parameters
    collect_parameters

    # Step 2: Clone repository
    clone_repository

    # Step 3: Verify Docker files
    verify_docker_files

    # Step 4: Test SSH connection
    test_ssh_connection

    # Step 5: Setup remote environment
    setup_remote_environment

    # Step 6: Transfer files
    transfer_files

    # Step 7: Deploy application
    deploy_application

    # Step 8: Validate deployment
    validate_deployment

    # Step 9: Configure Nginx
    configure_nginx

    # Step 10: Validate Nginx
    validate_nginx

    # Display summary
    display_summary
}

# Run main function
main "$@"
