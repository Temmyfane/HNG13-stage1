#!/bin/bash

###########################################
# Automated Deployment Script
# DevOps Stage 1 Task
###########################################

set -euo pipefail  # Exit on error, undefined vars, pipe failures

# Color codes for better readability
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Log file with timestamp
readonly LOG_FILE="deploy_$(date +%Y%m%d_%H%M%S).log"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

###########################################
# Utility Functions
###########################################

log() {
    local message="[$(date +'%Y-%m-%d %H:%M:%S')] $1"
    echo -e "${GREEN}✓${NC} $message" | tee -a "$LOG_FILE"
}

info() {
    local message="[$(date +'%Y-%m-%d %H:%M:%S')] $1"
    echo -e "${BLUE}ℹ${NC} $message" | tee -a "$LOG_FILE"
}

warning() {
    local message="[$(date +'%Y-%m-%d %H:%M:%S')] WARNING: $1"
    echo -e "${YELLOW}⚠${NC} $message" | tee -a "$LOG_FILE"
}

error() {
    local message="[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $1"
    echo -e "${RED}✗${NC} $message" | tee -a "$LOG_FILE"
    exit 1
}

cleanup() {
    if [ $? -ne 0 ]; then
        error "Script failed. Check $LOG_FILE for details."
    fi
}

trap cleanup EXIT

###########################################
# Input Validation Functions
###########################################

validate_url() {
    local url="$1"
    if [[ ! "$url" =~ ^https?:// ]]; then
        return 1
    fi
    return 0
}

validate_ip() {
    local ip="$1"
    if [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        return 0
    fi
    return 1
}

validate_port() {
    local port="$1"
    if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
        return 0
    fi
    return 1
}

###########################################
# File Transfer Function
###########################################

transfer_files() {
    local ssh_key="$1"
    local ssh_user="$2"
    local server_ip="$3"
    
    # Check if rsync is available
    if command -v rsync &> /dev/null; then
        log "Using rsync for file transfer..."
        rsync -avz --delete -e "ssh -i $ssh_key -o StrictHostKeyChecking=no" \
            --exclude='.git' \
            --exclude='node_modules' \
            --exclude='*.log' \
            ./ "${ssh_user}@${server_ip}:~/app/" || error "Failed to transfer files with rsync"
    else
        log "rsync not found, using tar+ssh for file transfer..."
        
        # Create temporary directory on remote
        ssh -i "$ssh_key" -o StrictHostKeyChecking=no "${ssh_user}@${server_ip}" \
            "mkdir -p ~/app" || error "Failed to create remote directory"
        
        # Create tar archive excluding unnecessary files and transfer
        tar czf - --exclude='.git' --exclude='node_modules' --exclude='*.log' . | \
            ssh -i "$ssh_key" -o StrictHostKeyChecking=no "${ssh_user}@${server_ip}" \
            "cd ~/app && tar xzf -" || error "Failed to transfer files with tar"
    fi
}

###########################################
# Main Script
###########################################

main() {
    log "========================================="
    log "DevOps Automated Deployment Script"
    log "========================================="
    
    # Step 1: Collect and validate parameters
    info "Step 1: Collecting deployment parameters..."
    
    read -p "Enter Git Repository URL: " REPO_URL
    validate_url "$REPO_URL" || error "Invalid repository URL"
    
    read -sp "Enter Personal Access Token (PAT): " PAT
    echo
    [ -z "$PAT" ] && error "PAT cannot be empty"
    
    read -p "Enter Branch name [main]: " BRANCH
    BRANCH=${BRANCH:-main}
    
    read -p "Enter SSH Username: " SSH_USER
    [ -z "$SSH_USER" ] && error "SSH username cannot be empty"
    
    read -p "Enter Server IP address: " SERVER_IP
    validate_ip "$SERVER_IP" || error "Invalid IP address format"
    
    read -p "Enter SSH Key Path: " SSH_KEY_PATH
    SSH_KEY_PATH="${SSH_KEY_PATH/#\~/$HOME}"  # Expand tilde
    [ ! -f "$SSH_KEY_PATH" ] && error "SSH key file not found at: $SSH_KEY_PATH"
    
    read -p "Enter Application Port [3000]: " APP_PORT
    APP_PORT=${APP_PORT:-3000}
    validate_port "$APP_PORT" || error "Invalid port number"
    
    log "All parameters validated successfully"
    
    # Step 2: Clone or update repository
    info "Step 2: Cloning/updating repository..."
    
    REPO_NAME=$(basename "$REPO_URL" .git)
    AUTH_URL=$(echo "$REPO_URL" | sed "s|https://|https://${PAT}@|")
    
    if [ -d "$REPO_NAME" ]; then
        log "Repository directory exists. Pulling latest changes..."
        cd "$REPO_NAME"
        git fetch origin || error "Failed to fetch from origin"
        git checkout "$BRANCH" || error "Failed to checkout branch: $BRANCH"
        git pull origin "$BRANCH" || error "Failed to pull latest changes"
    else
        log "Cloning repository..."
        git clone -b "$BRANCH" "$AUTH_URL" "$REPO_NAME" || error "Failed to clone repository"
        cd "$REPO_NAME"
    fi
    
    log "Repository ready: $(pwd)"
    
    # Step 3: Verify Dockerfile exists
    info "Step 3: Verifying Docker configuration..."
    
    if [ -f "Dockerfile" ]; then
        log "Dockerfile found"
        DEPLOY_METHOD="dockerfile"
    elif [ -f "docker-compose.yml" ] || [ -f "docker-compose.yaml" ]; then
        log "docker-compose.yml found"
        DEPLOY_METHOD="compose"
    else
        error "No Dockerfile or docker-compose.yml found in repository"
    fi
    
    # Step 4: Test SSH connection
    info "Step 4: Testing SSH connection to remote server..."
    
    chmod 600 "$SSH_KEY_PATH"
    
    if ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
        -o BatchMode=yes "${SSH_USER}@${SERVER_IP}" "echo 'Connection successful'" &>/dev/null; then
        log "SSH connection verified successfully"
    else
        error "Failed to establish SSH connection to ${SSH_USER}@${SERVER_IP}"
    fi
    
    # Step 5: Prepare remote environment
    info "Step 5: Preparing remote server environment..."
    
    ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no "${SSH_USER}@${SERVER_IP}" bash << 'ENDSSH'
        set -e
        
        echo "Updating system packages..."
        sudo apt-get update -y >/dev/null 2>&1
        
        # Install Docker
        if ! command -v docker &> /dev/null; then
            echo "Installing Docker..."
            curl -fsSL https://get.docker.com -o get-docker.sh
            sudo sh get-docker.sh
            rm get-docker.sh
            sudo usermod -aG docker $USER
        else
            echo "Docker already installed"
        fi
        
        # Install Docker Compose
        if ! command -v docker-compose &> /dev/null; then
            echo "Installing Docker Compose..."
            sudo apt-get install -y docker-compose
        else
            echo "Docker Compose already installed"
        fi
        
        # Install Nginx
        if ! command -v nginx &> /dev/null; then
            echo "Installing Nginx..."
            sudo apt-get install -y nginx
        else
            echo "Nginx already installed"
        fi
        
        # Start and enable services
        sudo systemctl enable docker >/dev/null 2>&1 || true
        sudo systemctl start docker
        sudo systemctl enable nginx >/dev/null 2>&1 || true
        sudo systemctl start nginx
        
        # Verify installations
        echo "=== Installed Versions ==="
        docker --version
        docker-compose --version
        nginx -v 2>&1
        echo "=========================="
ENDSSH
    
    log "Remote environment prepared successfully"
    
    # Step 6: Deploy the application
    info "Step 6: Deploying Dockerized application..."
    
    log "Transferring project files to server..."
    transfer_files "$SSH_KEY_PATH" "$SSH_USER" "$SERVER_IP"
    
    log "Files transferred successfully"
    
    log "Building and running Docker container..."
    ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no "${SSH_USER}@${SERVER_IP}" \
        "REPO_NAME='$REPO_NAME' APP_PORT='$APP_PORT'" bash << 'ENDSSH'
        set -e
        cd ~/app
        
        # Stop and remove old containers
        echo "Cleaning up old containers..."
        docker stop ${REPO_NAME}-container 2>/dev/null || true
        docker rm ${REPO_NAME}-container 2>/dev/null || true
        
        # Remove old images (keep last 2)
        docker images | grep "^${REPO_NAME}" | tail -n +3 | awk '{print $3}' | xargs -r docker rmi 2>/dev/null || true
        
        # Build new image
        echo "Building Docker image..."
        docker build -t ${REPO_NAME}:latest . || exit 1
        
        # Run container
        echo "Starting container..."
        docker run -d \
            --name ${REPO_NAME}-container \
            -p ${APP_PORT}:${APP_PORT} \
            -e PORT=${APP_PORT} \
            --restart unless-stopped \
            ${REPO_NAME}:latest || exit 1
        
        # Wait for container to be ready
        echo "Waiting for container to start..."
        sleep 10
        
        # Verify container is running
        if docker ps | grep -q ${REPO_NAME}-container; then
            echo "Container is running"
            docker ps | grep ${REPO_NAME}-container
        else
            echo "Container failed to start"
            docker logs ${REPO_NAME}-container
            exit 1
        fi
ENDSSH
    
    log "Application deployed successfully"
    
    # Step 7: Configure Nginx reverse proxy
    info "Step 7: Configuring Nginx reverse proxy..."
    
    ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no "${SSH_USER}@${SERVER_IP}" \
        "APP_PORT='$APP_PORT'" bash << 'ENDSSH'
        set -e
        
        echo "Creating Nginx configuration..."
        sudo tee /etc/nginx/sites-available/app > /dev/null << EOF
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    
    server_name _;
    
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
    }
}
EOF
        
        # Enable site and remove default
        sudo ln -sf /etc/nginx/sites-available/app /etc/nginx/sites-enabled/app
        sudo rm -f /etc/nginx/sites-enabled/default
        
        # Test Nginx configuration
        echo "Testing Nginx configuration..."
        sudo nginx -t || exit 1
        
        # Reload Nginx
        echo "Reloading Nginx..."
        sudo systemctl reload nginx
        
        echo "Nginx configured successfully"
ENDSSH
    
    log "Nginx reverse proxy configured successfully"
    
    # Step 8: Validate deployment
    info "Step 8: Validating deployment..."
    
    log "Checking Docker service..."
    ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no "${SSH_USER}@${SERVER_IP}" \
        "sudo systemctl is-active docker" >/dev/null || error "Docker service is not running"
    
    log "Checking container health..."
    ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no "${SSH_USER}@${SERVER_IP}" \
        "docker ps | grep ${REPO_NAME}-container" >/dev/null || error "Container is not running"
    
    log "Testing application endpoint..."
    sleep 5  # Give app time to fully start
    
    if ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no "${SSH_USER}@${SERVER_IP}" \
        "curl -f -s http://localhost:${APP_PORT}" >/dev/null 2>&1; then
        log "Application responding on port ${APP_PORT}"
    else
        warning "Application may not be responding correctly on port ${APP_PORT}"
    fi
    
    log "Testing Nginx proxy..."
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 10 "http://${SERVER_IP}" 2>/dev/null || echo "000")
    
    if [ "$HTTP_CODE" = "200" ]; then
        log "Nginx proxy working correctly (HTTP $HTTP_CODE)"
    elif [ "$HTTP_CODE" = "000" ]; then
        warning "Could not connect to server. Check firewall/security group settings."
    else
        warning "Nginx returned HTTP $HTTP_CODE"
    fi
    
    log "========================================="
    log "DEPLOYMENT COMPLETED SUCCESSFULLY!"
    log "========================================="
    echo ""
    info "Access your application at: http://${SERVER_IP}"
    info "Application internal port: ${APP_PORT}"
    info "Log file: $LOG_FILE"
    echo ""
    info "To check container logs, run:"
    echo "  ssh -i $SSH_KEY_PATH ${SSH_USER}@${SERVER_IP} 'docker logs ${REPO_NAME}-container'"
    echo ""
}

###########################################
# Script Entry Point
###########################################

# Handle cleanup flag
if [ "${1:-}" = "--cleanup" ]; then
    info "Cleanup mode activated"
    read -p "Enter Server IP: " SERVER_IP
    read -p "Enter SSH Username: " SSH_USER
    read -p "Enter SSH Key Path: " SSH_KEY_PATH
    
    ssh -i "$SSH_KEY_PATH" "${SSH_USER}@${SERVER_IP}" << 'ENDSSH'
        docker stop $(docker ps -aq) 2>/dev/null || true
        docker rm $(docker ps -aq) 2>/dev/null || true
        docker system prune -af
        sudo rm -f /etc/nginx/sites-enabled/app
        sudo systemctl reload nginx
        rm -rf ~/app
        echo "Cleanup completed"
ENDSSH
    
    log "Cleanup completed successfully"
    exit 0
fi

# Run main function
main "$@"