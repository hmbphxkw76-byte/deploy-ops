Install Docker CE

1. Update and Install Dependencies

sudo apt update && sudo apt -y full-upgrade
sudo apt install curl gnupg2 apt-transport-https software-properties-common ca-certificates


2. Add Docker GPG Key and Repository

curl -fsSL https://download.docker.com/linux/debian/gpg | \
sudo gpg --dearmor -o /etc/apt/trusted.gpg.d/docker.gpg

echo "deb [arch=$(dpkg --print-architecture)] https://download.docker.com/linux/debian bullseye stable" | \
sudo tee /etc/apt/sources.list.d/docker.list


3. Install Docker

sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io


4. Enable and Start Docker

sudo systemctl enable --now docker
sudo usermod -aG docker $USER
newgrp docker



5. Verify:

docker version

docker compose version