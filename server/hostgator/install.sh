#!/usr/bin/env bash
set -euo pipefail
package_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd /home2/valentfx
umask 077
private_root=/home2/valentfx/desired-state-private
api_root=/home2/valentfx/public_html/desired-state-api
if [[ -e "$api_root" ]]; then
    echo 'API destination already exists. Preserved; do not overwrite it blindly.' >&2
    exit 1
fi
mkdir -p "$private_root"/{config,storage,uploads,backups}
chmod 700 "$private_root" "$private_root"/{config,storage,uploads,backups}
php -l "$package_root/tools/configure.php"
php -l "$package_root/public/index.php"
if [[ ! -f "$private_root/config/backend.php" ]]; then
    read -r -s -p 'Database user password (hidden): ' ds_database_password
    printf '\n'
    printf '%s' "$ds_database_password" | php "$package_root/tools/configure.php"
    unset ds_database_password
fi
php -r '$c=require "/home2/valentfx/desired-state-private/config/backend.php"; $db=new PDO($c["dsn"],$c["user"],$c["password"],[PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION]); echo "Schema version: ",$db->query("SELECT MAX(version) FROM ds_schema_migrations")->fetchColumn(),PHP_EOL;'
publish_root="$(mktemp -d /home2/valentfx/public_html/.desired-state-api-XXXXXXXX)"
trap 'rm -rf -- "$publish_root"' EXIT
cp "$package_root/public/index.php" "$publish_root/index.php"
cp "$package_root/public/.htaccess" "$publish_root/.htaccess"
chmod 644 "$publish_root/index.php" "$publish_root/.htaccess"
chmod 755 "$publish_root"
mv -T "$publish_root" "$api_root"
trap - EXIT
echo 'API installed: https://valentfx.com/desired-state-api/index.php?action=health'
echo 'Keep upload-token.txt private. Never paste the token or database password into chat.'
