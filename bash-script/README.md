# Automated Deployment Script

## Overview
This script automates the deployment of Dockerized applications to remote Linux servers.

## Prerequisites
- Git installed
- SSH access to remote server
- GitHub Personal Access Token

## Usage
```bash
chmod +x deploy.sh
./deploy.sh
```

Follow the prompts to provide:
- Repository URL
- Personal Access Token
- SSH credentials
- Application port

## Features
- Automated Docker setup
- Nginx reverse proxy configuration
- Error handling and logging
- Idempotent execution

## Testing
Tested on Ubuntu 22.04 with Node.js application.