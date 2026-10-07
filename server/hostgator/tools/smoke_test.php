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
    $health=request('action=health');
    if (!in_array('gzip',$health['file_encodings'] ?? [],true)) { throw new RuntimeException('Gzip capability missing'); }
    $original=str_repeat("{\"eeg\":[1.23456789,2.3456789]}\n",10000);
    $packed=gzencode($original,6);
    $metadata=['session_id'=>$id,'file_name'=>'synthetic_eeg.jsonl','sha256'=>hash('sha256',$packed),'bytes'=>strlen($packed),'encoding'=>'gzip','original_bytes'=>strlen($original),'original_sha256'=>hash('sha256',$original)];
    $upload=postJson('action=file',$metadata); $uid=$upload['upload_id'];
    $split=max(1,intdiv(strlen($packed),2));
    $first=substr($packed,0,$split); $last=substr($packed,$split);
    request('action=chunk&upload_id='.$uid,'POST',$first,['Content-Type: application/octet-stream','X-Upload-Offset: 0','X-Chunk-Sha256: '.hash('sha256',$first)]);
    $resume=postJson('action=file',$metadata);
    if ($resume['upload_id']!==$uid || $resume['offset']!==$split) { throw new RuntimeException('Compressed resume failed'); }
    request('action=chunk&upload_id='.$uid,'POST',$last,['Content-Type: application/octet-stream','X-Upload-Offset: '.$split,'X-Chunk-Sha256: '.hash('sha256',$last)]);
    $done=request('action=finish&upload_id='.$uid,'POST','');
    if (($done['original_sha256'] ?? '')!==hash('sha256',$original) || ($done['original_bytes'] ?? 0)!==strlen($original)) { throw new RuntimeException('Original verification failed'); }
    $repeat=postJson('action=file',$metadata);
    if ($repeat['upload_id']!==$uid || $repeat['status']!=='verified' || $repeat['offset']!==strlen($packed)) { throw new RuntimeException('Compressed duplicate suppression failed'); }
    // Reuse the legacy uncompressed manifest, rather than store it twice.
    $mPacked=gzencode($content,6);
    $reuse=postJson('action=file',['session_id'=>$id,'file_name'=>'manifest.json','sha256'=>hash('sha256',$mPacked),'bytes'=>strlen($mPacked),'encoding'=>'gzip','original_bytes'=>strlen($content),'original_sha256'=>hash('sha256',$content)]);
    if ($reuse['encoding']!=='identity' || $reuse['status']!=='verified') { throw new RuntimeException('Legacy revision reuse failed'); }
    // A valid gzip transport with a false original hash must never verify.
    $bad=$metadata; $bad['file_name']='synthetic_bad.jsonl'; $bad['original_sha256']=str_repeat('0',64);
    $badUpload=postJson('action=file',$bad); $badId=$badUpload['upload_id'];
    request('action=chunk&upload_id='.$badId,'POST',$packed,['Content-Type: application/octet-stream','X-Upload-Offset: 0','X-Chunk-Sha256: '.hash('sha256',$packed)]);
    request('action=finish&upload_id='.$badId,'POST','',[],true,422);
    echo "PASS: compressed resume, original hash/length, repeated revision, legacy reuse and false-original rejection.\n";
    echo "PASS: HTTPS, authentication, unknown upload, chunk resume, offset rejection, corrupt chunk rejection, final hash and immutable verified file.\nSynthetic test session: $id\n";
} catch (Throwable $e) { fwrite(STDERR,$e->getMessage()."\n"); exit(1); }
