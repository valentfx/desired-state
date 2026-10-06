<?php
declare(strict_types=1);
if (PHP_SAPI!=='cli') { exit(1); }
$c=require '/home2/valentfx/desired-state-private/config/backend.php';
$db=new PDO($c['dsn'],$c['user'],$c['password'],[PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION]);
$columns=$db->query('SHOW COLUMNS FROM ds_uploads')->fetchAll(PDO::FETCH_COLUMN);
foreach ([
 'encoding'=>"VARCHAR(16) NOT NULL DEFAULT 'identity'",
 'original_bytes'=>'BIGINT UNSIGNED NULL',
 'original_sha256'=>'CHAR(64) CHARACTER SET ascii COLLATE ascii_bin NULL',
] as $name=>$definition) {
 if (!in_array($name,$columns,true)) { $db->exec("ALTER TABLE ds_uploads ADD COLUMN `$name` $definition"); }
}
$db->exec('INSERT IGNORE INTO ds_schema_migrations(version) VALUES(2)');
echo "Additive compression schema ready. Existing uploads retained.\n";
