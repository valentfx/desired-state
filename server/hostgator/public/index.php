<?php
declare(strict_types=1);
ini_set('display_errors', '0');
require __DIR__.'/compression.php';
header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store');
header('X-Content-Type-Options: nosniff');
$requestId = bin2hex(random_bytes(8));
function reply(int $code, array $data): void { http_response_code($code); echo json_encode($data, JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR); exit; }
function fail(int $code, string $message): void { global $requestId; reply($code, ['error'=>$message, 'request_id'=>$requestId]); }
function statement(string $sql, array $args=[]): PDOStatement { global $db; $q=$db->prepare($sql); $q->execute($args); return $q; }
function body(): array {
    if (stripos($_SERVER['CONTENT_TYPE'] ?? '', 'application/json') !== 0) { fail(415, 'application/json required'); }
    $input=fopen('php://input','rb'); $text=stream_get_contents($input,2097153); fclose($input);
    if (strlen($text)>2097152) { fail(413,'JSON body too large'); }
    try { $data=json_decode($text,true,64,JSON_THROW_ON_ERROR); } catch (Throwable $e) { fail(400,'Invalid JSON'); }
    if (!is_array($data)) { fail(400,'JSON object required'); } return $data;
}
function upload(): array {
    global $account;
    $id=$_GET['upload_id'] ?? '';
    if (!preg_match('/\A[a-f0-9]{32}\z/D',$id)) { fail(400,'Invalid upload ID'); }
    $row=statement('SELECT * FROM ds_uploads WHERE upload_id=? AND account_id=?',[$id,$account])->fetch(PDO::FETCH_ASSOC);
    if (!$row) { fail(404,'Upload not found'); } return $row;
}
function lockUpload(string $id) {
    global $config;
    $lock=fopen($config['private_root'].'/uploads/'.$id.'.lock','c');
    if (!$lock || !flock($lock,LOCK_EX)) { fail(503,'Upload lock unavailable'); } return $lock;
}
function lockedUpload(): array {
    global $uploadLock;
    $row=upload(); $uploadLock=lockUpload($row['upload_id']);
    return upload();
}
function offset(array $row): int {
    global $config;
    if ($row['status']==='verified') { return (int)$row['expected_bytes']; }
    $path=$config['private_root'].'/uploads/'.$row['upload_id'].'.part';
    clearstatcache(true,$path); return is_file($path) ? (int)filesize($path) : 0;
}
try {
    if (($_SERVER['HTTPS'] ?? '') !== 'on' && ($_SERVER['SERVER_PORT'] ?? '') !== '443') { fail(400,'HTTPS required'); }
    $config=require dirname(__DIR__,2).'/desired-state-private/config/backend.php';
    $db=new PDO($config['dsn'],$config['user'],$config['password'],[PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION,PDO::ATTR_EMULATE_PREPARES=>false]);
    $db->exec("SET time_zone = '+00:00'");
    $action=$_GET['action'] ?? 'health'; $method=$_SERVER['REQUEST_METHOD'] ?? 'GET';
    if ($action==='health' && $method==='GET') {
        $version=statement('SELECT MAX(version) FROM ds_schema_migrations')->fetchColumn();
        reply(200,['service'=>'desired-state','api_version'=>1,'schema_version'=>1,'storage_schema_version'=>(int)$version,'database'=>'ready','file_encodings'=>['identity','gzip']]);
    }
    $authorization=$_SERVER['HTTP_AUTHORIZATION'] ?? $_SERVER['REDIRECT_HTTP_AUTHORIZATION'] ?? '';
    if (!preg_match('/\ABearer ([a-f0-9]{64})\z/D',trim($authorization),$match)) { fail(401,'Upload token required'); }
    $account=statement('SELECT t.account_id FROM ds_tokens t JOIN ds_accounts a ON a.account_id=t.account_id WHERE t.token_hash=? AND t.revoked=0 AND a.enabled=1',[hash('sha256',$match[1])])->fetchColumn();
    if (!$account) { fail(401,'Invalid or revoked upload token'); }
    if ($action==='sessions' && $method==='GET') {
        $rows=statement('SELECT session_id,participant_id,manifest_json,updated_utc FROM ds_sessions WHERE account_id=? ORDER BY updated_utc DESC LIMIT 100',[$account])->fetchAll(PDO::FETCH_ASSOC);
        foreach ($rows as &$row) { $row['manifest']=json_decode($row['manifest_json'],true); unset($row['manifest_json']); } unset($row);
        reply(200,['sessions'=>$rows]);
    }
    if ($action==='session' && $method==='POST') {
        $data=body(); $manifest=$data['manifest'] ?? null;
        if (!is_array($manifest) || ($manifest['schema_version'] ?? null)!==1 || !is_string($manifest['session_id'] ?? null) || !preg_match('/\A[A-Za-z0-9_-]{1,128}\z/D',$manifest['session_id'])) { fail(400,'Unsupported session manifest'); }
        $id=$manifest['session_id']; $participant=$manifest['participant_id'] ?? null;
        if ($participant!==null && (!is_string($participant) || !preg_match('/\A[A-Za-z0-9_.=-]{1,128}\z/D',$participant))) { fail(400,'Invalid participant ID'); }
        if ($participant!==null) { statement('INSERT IGNORE INTO ds_participants(account_id,participant_id) VALUES(?,?)',[$account,$participant]); }
        statement('INSERT INTO ds_sessions(account_id,session_id,participant_id,manifest_json) VALUES(?,?,?,?) ON DUPLICATE KEY UPDATE participant_id=VALUES(participant_id),manifest_json=VALUES(manifest_json)',[$account,$id,$participant,json_encode($manifest,JSON_THROW_ON_ERROR)]);
        reply(200,['session_id'=>$id,'account_id'=>$account]);
    }
    if ($action==='file' && $method==='POST') {
        $data=body(); $session=$data['session_id'] ?? ''; $name=$data['file_name'] ?? ''; $hash=$data['sha256'] ?? ''; $bytes=$data['bytes'] ?? null;
        if (!is_string($session) || !preg_match('/\A[A-Za-z0-9_-]{1,128}\z/D',$session) || !is_string($name) || !preg_match('/\A[A-Za-z0-9_-][A-Za-z0-9_.-]{0,116}\.jsonl?\z/D',$name) || !is_string($hash) || !preg_match('/\A[a-f0-9]{64}\z/D',$hash) || !is_int($bytes) || $bytes<0 || $bytes>$config['max_file_bytes']) { fail(400,'Invalid file metadata'); }
        $encoding=$data['encoding'] ?? 'identity';
        $originalBytes=$data['original_bytes'] ?? $bytes;
        $originalHash=$data['original_sha256'] ?? $hash;
        if (!in_array($encoding,['identity','gzip'],true) || !is_int($originalBytes) || $originalBytes<0 || $originalBytes>$config['max_file_bytes'] || !is_string($originalHash) || !preg_match('/\A[a-f0-9]{64}\z/D',$originalHash) || ($encoding==='identity' && ($originalBytes!==$bytes || $originalHash!==$hash))) { fail(400,'Invalid original file metadata'); }
        // Preserve and resume old uncompressed uploads instead of duplicating them.
        if ($encoding==='gzip') {
            $prior=statement("SELECT * FROM ds_uploads WHERE account_id=? AND session_id=? AND file_name=? AND sha256=? AND encoding='identity'",[$account,$session,$name,$originalHash])->fetch(PDO::FETCH_ASSOC);
            if ($prior) {
                if ((int)$prior['expected_bytes']!==$originalBytes) { fail(409,'Existing original size mismatch'); }
                $lock=lockUpload($prior['upload_id']);
                $prior=statement('SELECT * FROM ds_uploads WHERE upload_id=?',[$prior['upload_id']])->fetch(PDO::FETCH_ASSOC);
                reply(200,['upload_id'=>$prior['upload_id'],'offset'=>offset($prior),'status'=>$prior['status'],'chunk_bytes'=>$config['max_chunk_bytes'],'encoding'=>'identity','expected_bytes'=>(int)$prior['expected_bytes'],'original_sha256'=>$originalHash]);
            }
        }
        if (!statement('SELECT session_id FROM ds_sessions WHERE account_id=? AND session_id=?',[$account,$session])->fetchColumn()) { fail(404,'Register session first'); }
        $db->beginTransaction();
        statement('SELECT account_id FROM ds_accounts WHERE account_id=? FOR UPDATE',[$account]);
        $existing=statement('SELECT upload_id FROM ds_uploads WHERE account_id=? AND session_id=? AND file_name=? AND sha256=?',[$account,$session,$name,$hash])->fetchColumn();
        if (!$existing) {
            $reserved=(int)statement('SELECT COALESCE(SUM(expected_bytes),0) FROM ds_uploads WHERE account_id=?',[$account])->fetchColumn();
            if ($reserved+$bytes>($config['max_account_bytes'] ?? 10737418240)) { $db->rollBack(); fail(413,'Account upload allowance exceeded'); }
        }
        $id=bin2hex(random_bytes(16));
        statement('INSERT IGNORE INTO ds_uploads(upload_id,account_id,session_id,file_name,expected_bytes,sha256,encoding,original_bytes,original_sha256) VALUES(?,?,?,?,?,?,?,?,?)',[$id,$account,$session,$name,$bytes,$hash,$encoding,$originalBytes,$originalHash]);
        $row=statement('SELECT * FROM ds_uploads WHERE account_id=? AND session_id=? AND file_name=? AND sha256=?',[$account,$session,$name,$hash])->fetch(PDO::FETCH_ASSOC);
        $db->commit();
        if ((int)$row['expected_bytes']!==$bytes || $row['encoding']!==$encoding || (int)($row['original_bytes'] ?? $row['expected_bytes'])!==$originalBytes || ($row['original_sha256'] ?? $row['sha256'])!==$originalHash) { fail(409,'Conflicting file metadata'); }
        $lock=lockUpload($row['upload_id']);
        $row=statement('SELECT * FROM ds_uploads WHERE upload_id=?',[$row['upload_id']])->fetch(PDO::FETCH_ASSOC);
        reply(200,['upload_id'=>$row['upload_id'],'offset'=>offset($row),'status'=>$row['status'],'chunk_bytes'=>$config['max_chunk_bytes'],'encoding'=>$row['encoding'],'expected_bytes'=>(int)$row['expected_bytes']]);
    }
    if ($action==='status' && $method==='GET') {
        $row=lockedUpload(); reply(200,['upload_id'=>$row['upload_id'],'offset'=>offset($row),'status'=>$row['status']]);
    }
    if ($action==='chunk' && $method==='POST') {
        $row=lockedUpload();
        if ($row['status']==='verified') { fail(409,'File already verified'); }
        $start=$_SERVER['HTTP_X_UPLOAD_OFFSET'] ?? ''; $chunkHash=$_SERVER['HTTP_X_CHUNK_SHA256'] ?? ''; $length=$_SERVER['CONTENT_LENGTH'] ?? '';
        if (!ctype_digit($start) || !ctype_digit($length) || !preg_match('/\A[a-f0-9]{64}\z/D',$chunkHash) || (int)$length<1 || (int)$length>$config['max_chunk_bytes']) { fail(400,'Invalid chunk headers'); }
        $current=offset($row);
        if ((int)$start!==$current) { reply(409,['error'=>'Offset mismatch','offset'=>$current]); }
        if ($current+(int)$length>(int)$row['expected_bytes']) { fail(413,'Chunk exceeds declared file size'); }
        $chunk=tempnam($config['private_root'].'/uploads','chunk-');
        $input=fopen('php://input','rb'); $output=fopen($chunk,'wb');
        $copied=stream_copy_to_stream($input,$output,$config['max_chunk_bytes']+1); fclose($input); fclose($output);
        if ($copied!==(int)$length || !hash_equals($chunkHash,hash_file('sha256',$chunk))) { unlink($chunk); fail(422,'Chunk integrity failed'); }
        $part=$config['private_root'].'/uploads/'.$row['upload_id'].'.part';
        $input=fopen($chunk,'rb'); $output=fopen($part,'ab');
        $written=stream_copy_to_stream($input,$output); fflush($output); fclose($input); fclose($output); unlink($chunk);
        if ($written!==$copied) { fail(500,'Incomplete disk write; query status before retry'); }
        statement("UPDATE ds_uploads SET status='uploading' WHERE upload_id=?",[$row['upload_id']]);
        reply(200,['offset'=>offset($row)]);
    }
    if ($action==='finish' && $method==='POST') {
        $row=lockedUpload();
        if ($row['status']==='verified') { reply(200,['status'=>'verified','sha256'=>$row['sha256'],'encoding'=>$row['encoding'],'original_sha256'=>$row['original_sha256'] ?? $row['sha256'],'original_bytes'=>(int)($row['original_bytes'] ?? $row['expected_bytes'])]); }
        $part=$config['private_root'].'/uploads/'.$row['upload_id'].'.part';
        $key=$account.'/'.substr($row['sha256'],0,2).'/'.$row['sha256'].($row['encoding']==='gzip' ? '.gz' : '');
        $destination=$config['private_root'].'/storage/'.$key;
        if (!is_file($part) && is_file($destination) && filesize($destination)===(int)$row['expected_bytes'] && hash_equals($row['sha256'],hash_file('sha256',$destination))) {
            // Re-create the staging reference so normal manifest checks still run.
            if (!link($destination,$part)) { fail(500,'Could not recover publication'); }
        }
        if ((int)$row['expected_bytes']===0 && !is_file($part)) { file_put_contents($part,''); }
        if (offset($row)!==(int)$row['expected_bytes']) { fail(409,'File incomplete'); }
        @set_time_limit(120);
        if (!hash_equals($row['sha256'],hash_file('sha256',$part))) { fail(422,'File integrity failed; reset and retry'); }
        $originalBytes=(int)($row['original_bytes'] ?? $row['expected_bytes']);
        $originalHash=$row['original_sha256'] ?? $row['sha256'];
        try { $decoded=decodedFile($part,$row['encoding'],$originalBytes,$row['file_name']==='manifest.json'); }
        catch (Throwable $e) { fail(422,'Decoded file integrity failed; reset and retry'); }
        if (!hash_equals($originalHash,$decoded['sha256'])) { fail(422,'Original file hash mismatch'); }
        if ($row['file_name']==='manifest.json') {
            $m=json_decode($decoded['text'],true);
            if (!is_array($m) || ($m['session_id'] ?? null)!==$row['session_id'] || ($m['schema_version'] ?? null)!==1) { fail(422,'Manifest identity mismatch'); }
        }
        if (!is_dir(dirname($destination))) { mkdir(dirname($destination),0700,true); }
        if (is_file($destination)) {
            if (!hash_equals($row['sha256'],hash_file('sha256',$destination))) { fail(500,'Stored object integrity failed'); }
            unlink($part);
        } elseif (!rename($part,$destination)) { fail(500,'Could not publish file'); }
        chmod($destination,0600);
        statement("UPDATE ds_uploads SET status='verified',storage_key=?,verified_utc=UTC_TIMESTAMP() WHERE upload_id=?",[$key,$row['upload_id']]);
        reply(200,['status'=>'verified','sha256'=>$row['sha256'],'bytes'=>(int)$row['expected_bytes'],'encoding'=>$row['encoding'],'original_sha256'=>$originalHash,'original_bytes'=>$originalBytes]);
    }
    if ($action==='reset' && $method==='POST') {
        $row=lockedUpload();
        if ($row['status']==='verified') { fail(409,'Verified files are immutable'); }
        $part=$config['private_root'].'/uploads/'.$row['upload_id'].'.part';
        if (is_file($part)) { unlink($part); }
        statement("UPDATE ds_uploads SET status='pending' WHERE upload_id=?",[$row['upload_id']]);
        reply(200,['offset'=>0,'status'=>'pending']);
    }
    fail(404,'Unknown action or method');
} catch (Throwable $e) {
    if (isset($db) && $db->inTransaction()) { $db->rollBack(); }
    error_log('Desired State ['.$requestId.'] '.get_class($e).': '.$e->getMessage());
    fail(500,'Server operation failed');
}
