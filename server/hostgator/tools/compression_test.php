<?php
declare(strict_types=1);
if (PHP_SAPI!=='cli') { exit(1); }
require dirname(__DIR__).'/public/compression.php';
$path=tempnam(sys_get_temp_dir(),'ds-gzip-test-');
try {
 $original=str_repeat("{\"sensor\":\"EEG\",\"value\":1.23456789}\n",10000);
 $packed=gzencode($original,6);
 file_put_contents($path,$packed);
 $decoded=decodedFile($path,'gzip',strlen($original));
 if ($decoded['sha256']!==hash('sha256',$original)) { throw new RuntimeException('Lossless hash failed'); }
 $rejected=false;
 try { decodedFile($path,'gzip',32); } catch (RuntimeException $e) { $rejected=true; }
 if (!$rejected) { throw new RuntimeException('Decoded size bound failed'); }
 file_put_contents($path,substr($packed,0,-8));
 $rejected=false;
 try { decodedFile($path,'gzip',strlen($original)); } catch (RuntimeException $e) { $rejected=true; }
 if (!$rejected) { throw new RuntimeException('Truncated gzip accepted'); }
 file_put_contents($path,$original);
 $decoded=decodedFile($path,'identity',strlen($original));
 if ($decoded['sha256']!==hash('sha256',$original)) { throw new RuntimeException('Identity compatibility failed'); }
 echo "PASS: lossless decoding, decoded bounds, truncated gzip rejection, identity compatibility.\n";
} finally { unlink($path); }
