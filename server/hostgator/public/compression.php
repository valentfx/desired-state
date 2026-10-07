<?php
declare(strict_types=1);
// Bound memory and decoded length; never materialize the original on disk.
function decodedFile(string $path, string $encoding, int $expected, bool $manifest=false): array {
    if (!in_array($encoding,['identity','gzip'],true)) { throw new RuntimeException('Unsupported encoding'); }
    set_error_handler(static function(int $severity, string $message): bool {
        throw new RuntimeException('Compressed file read failed');
    });
    $stream=null;
    try {
        $stream=fopen($path,'rb');
        if (!$stream) { throw new RuntimeException('File unavailable'); }
        $inflate=$encoding==='gzip' ? inflate_init(ZLIB_ENCODING_GZIP) : null;
        if ($encoding==='gzip' && $inflate===false) { throw new RuntimeException('Inflater unavailable'); }
        $hash=hash_init('sha256'); $bytes=0; $inputBytes=0; $text=''; $ended=false;
        while (!feof($stream)) {
            // Small input bounds even highly compressible expansion per call.
            $input=fread($stream,$encoding==='gzip' ? 4096 : 65536);
            if ($input===false) { throw new RuntimeException('File read failed'); }
            if ($input==='') { continue; }
            if ($ended) { throw new RuntimeException('Trailing compressed bytes'); }
            $inputBytes+=strlen($input);
            $chunk=$inflate!==null ? inflate_add($inflate,$input,ZLIB_SYNC_FLUSH) : $input;
            if ($chunk===false) { throw new RuntimeException('File decode failed'); }
            if ($inflate!==null && inflate_get_status($inflate)===ZLIB_STREAM_END) {
                $ended=true;
                if (inflate_get_read_len($inflate)!==$inputBytes) { throw new RuntimeException('Trailing compressed bytes'); }
            }
            $bytes+=strlen($chunk);
            if ($bytes>$expected || ($manifest && $bytes>2097152)) { throw new RuntimeException('Decoded size exceeded'); }
            hash_update($hash,$chunk);
            if ($manifest) { $text.=$chunk; }
        }
        if (($inflate!==null && !$ended) || $bytes!==$expected) { throw new RuntimeException('Decoded size or gzip completion mismatch'); }
        return ['bytes'=>$bytes,'sha256'=>hash_final($hash),'text'=>$text];
    } finally {
        if (is_resource($stream)) { fclose($stream); }
        restore_error_handler();
    }
}
