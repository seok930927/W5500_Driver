#!/bin/bash
set -e

WIZNET_DIR="/lib/modules/$(uname -r)/kernel/drivers/net/ethernet/wiznet"
REPO_URL="https://github.com/seok930927/W5500_Driver"
TMP_DIR=$(mktemp -d)

echo "=== W5500 Driver Build & Install ==="
echo "Kernel: $(uname -r)"
echo ""

# 의존성 확인
echo "[1/5] 빌드 의존성 확인 중..."
for pkg in git make gcc; do
    if ! command -v $pkg &>/dev/null; then
        echo "  설치 중: $pkg"
        sudo apt-get install -y $pkg
    fi
done

KHEADERS="linux-headers-$(uname -r)"
if [ ! -d "/lib/modules/$(uname -r)/build" ]; then
    echo "  커널 헤더 설치 중: $KHEADERS"
    sudo apt-get install -y $KHEADERS
fi

# 소스 클론
echo "[2/5] 소스 다운로드 중..."
git clone "$REPO_URL" "$TMP_DIR/W5500_Driver"

# 빌드
echo "[3/5] 빌드 중..."
cd "$TMP_DIR/W5500_Driver/source"
make DEBUG=0

# 백업
echo "[4/5] 기존 드라이버 백업 중..."
if [ -f "$WIZNET_DIR/w5100.ko.xz" ]; then
    sudo mv "$WIZNET_DIR/w5100.ko.xz"     "$WIZNET_DIR/w5100.ko.xz.bak"
    echo "  백업: w5100.ko.xz → w5100.ko.xz.bak"
fi
if [ -f "$WIZNET_DIR/w5100-spi.ko.xz" ]; then
    sudo mv "$WIZNET_DIR/w5100-spi.ko.xz" "$WIZNET_DIR/w5100-spi.ko.xz.bak"
    echo "  백업: w5100-spi.ko.xz → w5100-spi.ko.xz.bak"
fi

# 설치
echo "[5/5] 드라이버 설치 중..."
sudo cp build/w5100.ko     "$WIZNET_DIR/w5100.ko"
sudo cp build/w5100_spi.ko "$WIZNET_DIR/w5100_spi.ko"
sudo depmod -a

rm -rf "$TMP_DIR"

echo ""
echo "=== 설치 완료 ==="
read -p "지금 재부팅하시겠습니까? (y/N): " reboot
[[ "$reboot" == "y" || "$reboot" == "Y" ]] && sudo reboot
