#!/bin/bash
set -e

# Install PowerShell 7 on Ubuntu
apt-get update -y
apt-get install -y wget apt-transport-https software-properties-common
wget -q "https://packages.microsoft.com/config/ubuntu/22.04/packages-microsoft-prod.deb" -O packages-microsoft-prod.deb
dpkg -i packages-microsoft-prod.deb
apt-get update -y
apt-get install -y powershell

# Install AWS Tools for PowerShell explicitly under pwsh's module path -
pwsh -Command "Install-Module -Name AWS.Tools.Installer -Force -Scope AllUsers; Install-AWSToolsModule AWS.Tools.S3,AWS.Tools.EC2 -CleanUp -Force -Scope AllUsers"
