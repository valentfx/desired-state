#!/usr/bin/env bash
set -euo pipefail
package_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd /home2/valentfx
umask 077
api_root=/home2/valentfx/public_html/desired-state-api
private_root=/home2/valentfx/desired-state-private
[[ -f "$private_root/config/backend.php" && -f "$api_root/index.php" ]] || { echo 'Existing backend installation required.' >&2; exit 1; }
php -l "$package_root/public/index.php"
php -l "$package_root/public/compression.php"
php -l "$package_root/tools/upgrade_compression.php"
php "$package_root/tools/compression_test.php"
backup="$private_root/backups/compression-$(date +%Y%m%d-%H%M%S)-$$"
mkdir -m 700 "$backup"
cp "$api_root/index.php" "$backup/index.php"
if [[ -f "$api_root/compression.php" ]]; then cp "$api_root/compression.php" "$backup/compression.php"; fi
php "$package_root/tools/upgrade_compression.php"
# Publish helper first; the old entry point ignores it. Switch entry point atomically.
cp "$package_root/public/compression.php" "$api_root/compression.php.new"
chmod 644 "$api_root/compression.php.new"
mv -f "$api_root/compression.php.new" "$api_root/compression.php"
cp "$package_root/public/index.php" "$api_root/index.php.new"
chmod 644 "$api_root/index.php.new"
mv -f "$api_root/index.php.new" "$api_root/index.php"
if ! php "$package_root/tools/smoke_test.php"; then
 cp "$backup/index.php" "$api_root/index.php.rollback"
 mv -f "$api_root/index.php.rollback" "$api_root/index.php"
 echo 'Smoke test failed. Previous API restored; additive columns and any synthetic uploads retained.' >&2
 exit 1
fi
echo "Compression API installed. Previous entry point: $backup/index.php"
echo 'Existing raw objects remain unchanged. Upload allowance now reserves the transferred/stored representation.'
