<?php
declare(strict_types=1);
if (PHP_SAPI !== 'cli') { exit(1); }
umask(0077);
$root = '/home2/valentfx/desired-state-private';
$configPath = "$root/config/backend.php";
if (file_exists($configPath)) { fwrite(STDERR, "Configuration already exists; preserved.\n"); exit(1); }
$password = rtrim(stream_get_contents(STDIN), "\r\n");
if ($password === '') { fwrite(STDERR, "Empty database password.\n"); exit(1); }
$config = ['dsn' => 'mysql:host=localhost;dbname=valentfx_desiredstate;charset=utf8mb4', 'user' => 'valentfx_valentfx_dsapp', 'password' => $password, 'private_root' => $root, 'max_account_bytes' => 10737418240, 'max_file_bytes' => 4294967296, 'max_chunk_bytes' => 8388608];
try {
    $db = new PDO($config['dsn'], $config['user'], $config['password'], [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION, PDO::ATTR_EMULATE_PREPARES => false]);
    $db->exec("SET time_zone = '+00:00'");
    $sql = file_get_contents(dirname(__DIR__) . '/schema.sql');
    foreach (explode(';', $sql) as $statement) { if (trim($statement) !== '') { $db->exec($statement); } }
    $account = bin2hex(random_bytes(16));
    $token = bin2hex(random_bytes(32));
    $db->beginTransaction();
    $q = $db->prepare('INSERT INTO ds_accounts(account_id,label) VALUES(?,?)'); $q->execute([$account, 'Owner']);
    $q = $db->prepare('INSERT INTO ds_tokens(token_hash,account_id,label) VALUES(?,?,?)'); $q->execute([hash('sha256', $token), $account, 'Initial Windows upload token']);
    if (file_put_contents("$root/config/upload-token.txt", $token . "\n", LOCK_EX) === false) { throw new RuntimeException("Cannot save upload token"); }
    chmod("$root/config/upload-token.txt", 0600);
    $db->commit();
    if (file_put_contents($configPath, "<?php\nreturn " . var_export($config, true) . ";\n", LOCK_EX) === false) { throw new RuntimeException("Cannot save backend configuration"); }
    chmod($configPath, 0600);
    echo "Database schema and owner account ready.\nAccount: $account\nToken saved privately: $root/config/upload-token.txt\n";
} catch (Throwable $e) {
    if (isset($db) && $db->inTransaction()) { $db->rollBack(); }
    fwrite(STDERR, "Setup failed: " . $e->getMessage() . "\n"); exit(1);
}
