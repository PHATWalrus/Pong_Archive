#!/bin/bash
# Modified by Spike based on Luk1337 & arter97ˈs dump scripts with improvements and added functionality
set -ex

download_and_extract() {
    local url=$1
    local output_dir=$2
    
    # Download the ota.zip file to the working directory
    aria2c -x5 $url -o ota.zip
    
    # For the first link ($1), create the 'fullota' directory and copy the ota.zip file
    if [ "$url" == "$full_url" ]; then
        mkdir fullota
        cp ota.zip fullota
    fi
    
    # Check if ota.zip exists before trying to unzip
    if [ -e "ota.zip" ]; then
        # Continue with extracting the payload
        unzip ota.zip payload.bin
        mv payload.bin payload_working.bin
        TAG=$(unzip -p ota.zip payload_properties.txt | grep ^POST_OTA_VERSION= | cut -b 18-)
        rm ota.zip
        mkdir $output_dir
        (
            ./bin/ota_extractor -output_dir $output_dir -payload payload_working.bin
            rm payload_working.bin
        ) &
    else
        echo "Error: ota.zip not found."
    fi
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
    mkdir out dyn syn  # Create these directories in the working directory
    cd ota

    # Calculate hash
    for h in md5 sha1 sha256 xxh128; do
        if [ "$h" = "xxh128" ]; then
            ls * | parallel xxh128sum | sort -k2 -V > ../out/${TAG}-hash.$h
        else
            ls * | parallel "openssl dgst -${h} -r" | sort -k2 -V > ../out/${TAG}-hash.${h}
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
    local full_url=$1
    local incrementals=("${@:2}")
    local key=$3
    local TAG=""
    local BODY=""

    download_and_extract "$full_url" "ota"
    apply_incremental_updates "$full_url" "${incrementals[@]}"

    create_and_upload_images $TAG
    make_splitted_full_ota_package $TAG
    
    # Echo tag name and release body
    echo "tag=$TAG" >> "$GITHUB_OUTPUT"
    echo "body=$BODY" >> "$GITHUB_OUTPUT"
    
    cd ../fullota/
    
    bash <(curl -s https://devuploads.com/upload.sh) -f ./${TAG}-FullOTA.zip -k $2
    rm -rf ../fullota/ ../ota ../dyn ../syn
}
main "${@}"
