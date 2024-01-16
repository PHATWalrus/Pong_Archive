#!/bin/bash
# Modified by Spike based on Luk1337 & arter97ˈs dump scripts with improvements and added functionality
set -ex
THREADS=$(nproc)
download_and_extract() {
    local url=$1
    local output_dir=$2
    local ota_zip="ota.zip"

    echo "Downloading OTA from $url..."
    if ! aria2c -x5 "$url" -o "$ota_zip"; then
        echo "Error: Download failed for $url"
        return 1
    fi

    if [ "$url" == "$full_url" ]; then
        mkdir -p fullota && cp "$ota_zip" fullota/
    fi

    if [ ! -e "$ota_zip" ]; then
        echo "Error: $ota_zip not found."
        return 1
    fi

    echo "Extracting payload from $ota_zip..."
    unzip "$ota_zip" payload.bin
    mv payload.bin payload_working.bin
    TAG=$(unzip -p "$ota_zip" payload_properties.txt | grep ^POST_OTA_VERSION= | cut -b 18-)
    rm "$ota_zip"

    mkdir -p "$output_dir"
    ./bin/ota_extractor -output_dir "$output_dir" -payload payload_working.bin &
}


apply_incremental_updates() {
    local incremental_urls=("${@:2}")

    local release_history="[${TAG}]($full_url) (full)"

    for inc_url in "${incremental_urls[@]}"; do
        aria2c -x5 $inc_url -o ota.zip
        unzip ota.zip payload.bin
        wait
        mv payload.bin payload_working.bin
        TAG=$(unzip -p ota.zip payload_properties.txt | grep ^POST_OTA_VERSION= | cut -b 18-)
        rm ota.zip
        release_history="$release_history -> [${TAG}]($inc_url)"

        (
            mkdir ota_new
            ./bin/ota_extractor -input-dir ota -output_dir ota_new -payload payload_working.bin

            rm -rf ota
            mv ota_new ota

            rm payload_working.bin
        ) &
    done
    wait

    # Output the release history
    echo "$release_history"
}



create_and_upload_images() {
    local TAG=$1
    mkdir -p out dyn syn
    cd ota || exit 1

    # Calculate hash with parallel processing
    for h in md5 sha1 sha256 xxh128; do
        if [ "$h" = "xxh128" ]; then
            ls * | parallel -j "$THREADS" xxh128sum | sort -k2 -V > "../out/${TAG}-hash.$h"
        else
            ls * | parallel -j "$THREADS" "openssl dgst -${h} -r" | sort -k2 -V > "../out/${TAG}-hash.${h}"
        fi
    done

    # Copy boot, vendor_boot, vbmeta, and recovery images to syn directory
    cp boot.img ../syn/
    cp vendor_boot.img ../syn/
    cp vbmeta.img ../syn/
    cp recovery.img ../syn/

    # Create compressed images individually in syn directory and move them to out directory
    cd ../syn
    for f in boot vendor_boot vbmeta recovery; do
        7z a -mmt4 -mx5 ${f}.img.zip ${f}.img
        mv ${f}.img.zip ../out
    done
    
    # Move specific files (system.img, system_ext.img, product.img, etc.) to ../dyn/ directory
    cd ../ota
    for f in system system_ext product vendor vendor_dlkm odm; do
        mv ${f}.img ../dyn
    done

    # Change back to ../ota/ directory and create the split image
    cd ../ota
    7z a -mmt4 -mx6 ../out/${TAG}-image.7z *

    # Change to ../dyn/ directory and create the split logical image
    cd ../dyn
    7z a -mmt4 -mx6 -v1g ../out/${TAG}-image-logical.7z *
}

make_splitted_full_ota_package() {
    local TAG=$1
    
    # Switch to the 'fullota' directory
    cd ../fullota/
    
    # Copy ota.zip to a new file named "${TAG}-FullOTA.zip"
    cp ota.zip "./${TAG}-FullOTA.zip"
    
    # Create the split Full OTA Package for the specific file
    7z a -mmt4 -mx0 -v1g "../out/${TAG}-FullOTA.7z" "${TAG}-FullOTA.zip"
    
    
}
main() {
    local full_url=$2
    local incrementals=("${@:3}")
    local key=$3
    local TAG=""
    local BODY=""

    if ! download_and_extract "$full_url" "ota"; then
        echo "Failed to download and extract full OTA."
        return 1
    fi

    if ! apply_incremental_updates "$full_url" "${incrementals[@]}"; then
        echo "Failed to apply incremental updates."
        return 1
    fi

    create_and_upload_images "$TAG"
    make_splitted_full_ota_package "$TAG"

    echo "tag=$TAG" >> "$GITHUB_OUTPUT"
    echo "body=$BODY" >> "$GITHUB_OUTPUT"
    
    cd ../fullota/ || exit 1
    bash <(curl -s https://devuploads.com/upload.sh) -f "./${TAG}-FullOTA.zip" -k "$1"
    rm -rf ../fullota/ ../ota ../dyn ../syn
}
main "${@}"
