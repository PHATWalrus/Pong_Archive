#!/bin/bash
# Script has been modified by Spike for additional functionality and clarity, originally by arter97 and luk1337.

set -e  # Exit on any error
trap 'echo "An error occurred. Exiting..."; exit 1;' ERR

# Function to set execute permissions for ota_extractor
set_permissions() {
    chmod +x ./bin/ota_extractor
}

# Function to download OTA package
download_file() {
    local url="$1"
    if [[ "$url" == *"drive.google.com"* ]]; then
        gdown --fuzzy "$url" -O ota.zip
    else
        aria2c -x5 "$url" -o ota.zip
    fi
}

# Function to extract payload from OTA zip
extract_payload() {
    unzip ota.zip payload.bin
    mv payload.bin payload_working.bin
    TAG=$(unzip -p ota.zip payload_properties.txt | grep ^POST_OTA_VERSION= | cut -b 18-)
    BODY="[$TAG]($1) (full)"
    rm ota.zip
}

# Function to process incremental updates
apply_incrementals() {
    for url in "${@:2}"; do
        download_file "$url"
        extract_payload "$url"
        mkdir ota_new
        ./bin/ota_extractor -input-dir ota -output_dir ota_new -payload payload_working.bin
        rm -rf ota
        mv ota_new ota
        rm payload_working.bin
    done
}

# Main script execution
set_permissions
download_file "$1"
mkdir -p fullota
cp ota.zip fullota
extract_payload "$1"
mkdir -p ota
./bin/ota_extractor -output_dir ota -payload payload_working.bin
apply_incrementals "$@"

# Create necessary directories
mkdir -p out dyn syn

# Calculate hashes
cd ota
for hash_algo in md5 sha1 sha256 xxh128; do
    if [ "$hash_algo" = "xxh128" ]; then
        ls | parallel xxh128sum | sort -k2 -V > ../out/${TAG}-hash.$hash_algo
    else
        ls | parallel "openssl dgst -${hash_algo} -r" | sort -k2 -V > ../out/${TAG}-hash.${hash_algo}
    fi
done

# Move images to respective directories
for img in boot dtbo recovery vendor_boot vbmeta vbmeta_system vbmeta_vendor; do
    mv ${img}.img ../syn
done

cd ../ota
for img in system system_ext product vendor vendor_dlkm odm; do
    mv ${img}.img ../dyn
done

# Archive images
cd ../syn
7z a -mmt4 -mx6 ../out/${TAG}-image-boot.7z *
rm -rf ../syn

cd ../ota
7z a -mmt4 -mx6 ../out/${TAG}-image-firmware.7z *
rm -rf ../ota

cd ../dyn
7z a -mmt4 -mx6 -v1g ../out/${TAG}-image-logical.7z *
rm -rf ../dyn

# Handle FullOTA package
cd ../fullota
cp ota.zip "./${TAG}-FullOTA.zip"
SHA1_HASH=$(openssl dgst -sha1 -r "${TAG}-FullOTA.zip" | cut -d ' ' -f 1)
echo "${SHA1_HASH}" > "../out/${TAG}-FullOTA-hash.sha1"
7z a -mmt4 -mx6 -v1g "../out/${TAG}-FullOTA.7z" "${TAG}-FullOTA.zip"
rm -rf ../fullota

# Output tag and body
echo "tag=$TAG" >> "$GITHUB_OUTPUT"
echo "body=$BODY" >> "$GITHUB_OUTPUT"
