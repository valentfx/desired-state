<?php
declare(strict_types=1);
if (PHP_SAPI !== 'cli') { exit(1); }
// No real recordings are uploaded. The synthetic session remains labelled as a test.
$base='https://valentfx.com/desired-state-api/index.php';
$token=trim(file_get_contents('/home2/valentfx/desired-state-private/config/upload-token.txt'));
function request(string $action, string $method='GET', ?string $body=null, array $headers=[], bool $authenticated=true, int $expected=200): array {
    global $base,$token;
    if ($authenticated) { $headers[]='Authorization: Bearer '.$token; }
    $headers[]='Connection: close';
    if ($body!==null) { $headers[]='Content-Length: '.strlen($body); }
    $options=['http'=>['method'=>$method,'header'=>implode("\r\n",$headers),'ignore_errors'=>true,'timeout'=>60], 'ssl'=>['verify_peer'=>true,'verify_peer_name'=>true]];
    if ($body!==null) { $options['http']['content']=$body; }
    $response=@file_get_contents($base.'?'.$action,false,stream_context_create($options));
    $status=0;
    foreach ($http_response_header ?? [] as $line) { if (preg_match('/^HTTP\/\S+ (\d+)/',$line,$m)) { $status=(int)$m[1]; } }
    if ($response===false || $status!==$expected) { throw new RuntimeException("Request failed: $method $action; HTTP $status (expected $expected)"); }
    $data=json_decode($response,true,64,JSON_THROW_ON_ERROR);
    if (!is_array($data)) { throw new RuntimeException('Invalid API response'); }
    return $data;
}
function postJson(string $action,array $body): array { return request($action,'POST',json_encode($body,JSON_THROW_ON_ERROR),['Content-Type: application/json']); }
try {
    request('action=health');
    request('action=sessions','GET',null,[],false,401);
    request('action=status&upload_id='.str_repeat('0',32),'GET',null,[],true,404);
    $id='backend_smoke_'.bin2hex(random_bytes(8));
    $manifest=['schema_version'=>1,'session_id'=>$id,'purpose'=>'backend_smoke_test','synthetic'=>true];
    postJson('action=session',['manifest'=>$manifest]);
    $content=json_encode($manifest,JSON_THROW_ON_ERROR)."\n";
    $metadata=['session_id'=>$id,'file_name'=>'manifest.json','sha256'=>hash('sha256',$content),'bytes'=>strlen($content)];
    $upload=postJson('action=file',$metadata); $uid=$upload['upload_id'];
    $first=substr($content,0,16); $last=substr($content,16);
    request('action=chunk&upload_id='.$uid,'POST',$first,['Content-Type: application/octet-stream','X-Upload-Offset: 0','X-Chunk-Sha256: '.hash('sha256',$first)]);
    $resume=postJson('action=file',$metadata);
    if ($resume['upload_id']!==$uid || $resume['offset']!==16) { throw new RuntimeException('Resume offset failed'); }
    request('action=chunk&upload_id='.$uid,'POST',$last,['Content-Type: application/octet-stream','X-Upload-Offset: 0','X-Chunk-Sha256: '.hash('sha256',$last)],true,409);
    request('action=chunk&upload_id='.$uid,'POST',$last,['Content-Type: application/octet-stream','X-Upload-Offset: 16','X-Chunk-Sha256: '.str_repeat('0',64)],true,422);
    request('action=chunk&upload_id='.$uid,'POST',$last,['Content-Type: application/octet-stream','X-Upload-Offset: 16','X-Chunk-Sha256: '.hash('sha256',$last)]);
    $result=request('action=finish&upload_id='.$uid,'POST','');
    if (($result['status'] ?? null)!=='verified') { throw new RuntimeException('Final verification failed'); }
    request('action=finish&upload_id='.$uid,'POST','');
    request('action=reset&upload_id='.$uid,'POST','',[],true,409);
    echo "PASS: HTTPS, authentication, unknown upload, chunk resume, offset rejection, corrupt chunk rejection, final hash and immutable verified file.\nSynthetic test session: $id\n";
} catch (Throwable $e) { fwrite(STDERR,$e->getMessage()."\n"); exit(1); }
