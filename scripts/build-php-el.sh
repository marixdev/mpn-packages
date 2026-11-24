#!/usr/bin/env bash
# Builds one old PHP (5.6 and 7.0 to 7.3, which Remi no longer has for EL 9 and 10) for an EL system, as a tarball that unpacks into
# /opt/mpn/php/<major.minor>. The extensions are the ones Mini Panel installs on Debian and Ubuntu: fpm, cli, mysqli and pdo_mysql,
# mbstring, xml, curl, zip, gd (with jpeg, png, webp, freetype) and opcache. OpenSSL 3 is too new for these versions, so an older
# OpenSSL (1.1.1 for PHP 7, 1.0.2 for PHP 5.6) is built here and linked in statically. Then the build is checked: php -v, every
# extension loads, php-fpm answers a page.
# Runs as root inside a container of that system.
#   build-php-el.sh <el9|el10> <php version> <php sha256> <outdir>
# Environment: OPENSSL_VERSION OPENSSL_SHA256 (for PHP 7), OPENSSL10_VERSION OPENSSL10_SHA256 (for PHP 5.6)
set -euo pipefail
el="${1:?el9 or el10}"
ver="${2:?php version, such as 7.3.33}"
sha="${3:?sha256 of php-<version>.tar.xz}"
out="${4:?output directory}"
case "$el" in el9 | el10) ;; *) echo "el must be el9 or el10" >&2; exit 2 ;; esac
[[ "$ver" =~ ^(5\.6|7\.[0-3])\.[0-9]+$ ]] || { echo "only PHP 5.6 and 7.0 to 7.3 are built here" >&2; exit 2; }
[[ "$sha" =~ ^[0-9a-f]{64}$ ]] || { echo "bad sha256" >&2; exit 2; }
mm="${ver%.*}"
php5=0
[ "$mm" = 5.6 ] && php5=1
if [ "$php5" = 1 ]; then
  # PHP 5.6 does not build against OpenSSL 1.1 (opaque structures); 1.0.2 is the last series it knows.
  : "${OPENSSL10_VERSION:?}" "${OPENSSL10_SHA256:?}"
  OPENSSL_VERSION="$OPENSSL10_VERSION" OPENSSL_SHA256="$OPENSSL10_SHA256"
  ossl_want="OpenSSL 1.0.2"
else
  : "${OPENSSL_VERSION:?}" "${OPENSSL_SHA256:?}"
  ossl_want="OpenSSL 1.1.1"
fi
case "$(uname -m)" in
  x86_64) suffix="" ;;
  aarch64) suffix="-arm64" ;;
  *) echo "unsupported CPU $(uname -m)" >&2; exit 2 ;;
esac
prefix="/opt/mpn/php/$mm"

dnf -y -q install epel-release > /dev/null
dnf config-manager --set-enabled crb
dnf -y -q install gcc gcc-c++ make autoconf bison re2c pkgconf-pkg-config file xz perl tar \
  libxml2-devel libcurl-devel sqlite-devel oniguruma-devel libzip-devel bzip2-devel \
  libpng-devel libjpeg-turbo-devel libwebp-devel freetype-devel libicu-devel > /dev/null
dnf -y -q install zlib-devel > /dev/null 2>&1 || dnf -y -q install zlib-ng-compat-devel > /dev/null

work="$(mktemp -d)"
cd "$work"
curl -fsSL --proto '=https' -o php.txz "https://www.php.net/distributions/php-${ver}.tar.xz"
echo "${sha}  php.txz" | sha256sum -c - > /dev/null || { echo "php-${ver}.tar.xz does not match its checksum" >&2; exit 1; }
curl -fsSL --proto '=https' -o openssl.tgz "https://github.com/openssl/openssl/releases/download/OpenSSL_${OPENSSL_VERSION//./_}/openssl-${OPENSSL_VERSION}.tar.gz"
echo "${OPENSSL_SHA256}  openssl.tgz" | sha256sum -c - > /dev/null || { echo "openssl-${OPENSSL_VERSION} does not match its checksum" >&2; exit 1; }
mkdir php openssl
tar xJf php.txz -C php --strip-components=1
tar xzf openssl.tgz -C openssl --strip-components=1
# PHP 5.6 multiplies with inline assembly on arm64 whose "X" constraints let GCC 11 and newer pick vector registers, which mul and smulh
# do not take ("operand 2 must be an integer register"). PHP 7.0 fixed it with "=&r" and "r"; the same change is made here.
if [ "$php5" = 1 ]; then
  sed -i 's/: "=X"(__tmpvar), "=X"(usedval)/: "=\&r"(__tmpvar), "=\&r"(usedval)/; s/: "X"(a), "X"(b));/: "r"(a), "r"(b));/' php/Zend/zend_multiply.h
  grep -q '"=&r"(__tmpvar), "=&r"(usedval)' php/Zend/zend_multiply.h || { echo "zend_multiply.h was not patched" >&2; exit 1; }
fi

# The old OpenSSL, static, inside the PHP folder so nothing else on the machine sees it. It reads the system's CA bundle.
# OpenSSL 1.0.2 has no "no-tests" option, does not build in parallel, and needs its own lib folder name.
ossl="$work/ossl"
if [ "$php5" = 1 ]; then
  (cd openssl && ./config --prefix="$ossl" --openssldir=/etc/pki/tls --libdir=lib no-shared no-ssl2 no-ssl3 -fPIC > "$work/openssl.log" 2>&1 &&
    make depend >> "$work/openssl.log" 2>&1 && make >> "$work/openssl.log" 2>&1 && make install_sw >> "$work/openssl.log" 2>&1) || { tail -30 "$work/openssl.log"; exit 1; }
else
  (cd openssl && ./config --prefix="$ossl" --openssldir=/etc/pki/tls no-shared no-tests -fPIC > "$work/openssl.log" 2>&1 &&
    make -j"$(nproc)" >> "$work/openssl.log" 2>&1 && make install_sw >> "$work/openssl.log" 2>&1) || { tail -30 "$work/openssl.log"; exit 1; }
fi

# intl is built only on EL9: ext/intl of PHP 7.0 to 7.3 does not compile against ICU 74 (EL10), which changed the return type
# of BreakIterator::operator== and removed TRUE and FALSE. Mini Panel does not install intl on Debian and Ubuntu either, so a site
# loses nothing it had there.
intl=()
[ "$el" = el9 ] && [ "$php5" = 0 ] && intl=(--enable-intl)
# PHP before 7.4 finds the image libraries by folder, and gd's options differ between 7.3 and older. PHP 5.6 has --with-vpx-dir in
# place of webp (its bundled gd has no WebP), and builds its own zip (it has no --with-libzip).
gd=(--with-gd --with-jpeg-dir=/usr --with-png-dir=/usr --with-webp-dir=/usr --with-freetype-dir=/usr)
zip=(--enable-zip --with-libzip)
if [ "$php5" = 1 ]; then
  gd=(--with-gd --with-jpeg-dir=/usr --with-png-dir=/usr --with-freetype-dir=/usr)
  zip=(--enable-zip)
fi
# PHP 5.6 looks for freetype-config, which freetype 2.10 and newer no longer install; a small one that asks pkg-config stands in.
if [ "$php5" = 1 ] && ! command -v freetype-config > /dev/null; then
  printf '#!/bin/sh\ncase "$1" in --cflags) exec pkg-config --cflags freetype2;; --libs) exec pkg-config --libs freetype2;; --version) exec pkg-config --modversion freetype2;; esac\n' > /usr/local/bin/freetype-config
  chmod +x /usr/local/bin/freetype-config
fi
# PHP 5.6 still has the old mysql_* functions (ext/mysql), which code written for it calls; built on mysqlnd like mysqli. Linking a
# static OpenSSL 1.0.2 also needs libdl and pthread named.
mysql=()
if [ "$php5" = 1 ]; then
  mysql=(--with-mysql=mysqlnd)
  export LIBS="-ldl -lpthread"
fi
# GCC 11 and newer reject some old code by default (GCC 14 on EL10 turns pointer type mismatches into errors, and libxml2 2.12
# made some pointers const); these keep the 2019 sources compiling as they did then. ICU 61 and newer no longer put their names
# in the global namespace, which ext/intl of PHP 7.0 and 7.1 expect.
export CFLAGS="-O2 -fPIC -fcommon -std=gnu99 -Wno-error -Wno-error=incompatible-pointer-types -Wno-error=int-conversion -Wno-error=implicit-function-declaration -Wno-error=implicit-int"
export CXXFLAGS="-O2 -fPIC -std=gnu++11 -DU_USING_ICU_NAMESPACE=1"
# The OpenSSL 1.1.1 linked into php must stay private: the system libcurl loads OpenSSL 3, and exported 1.1.1 names would take the
# place of its functions (https through curl then fails).
export LDFLAGS="-Wl,--exclude-libs,ALL"
export PKG_CONFIG_PATH="$ossl/lib64/pkgconfig:$ossl/lib/pkgconfig"
cd php
./configure --prefix="$prefix" --with-config-file-path="$prefix/etc" --with-config-file-scan-dir="$prefix/etc/conf.d" \
  --enable-fpm --with-fpm-user=nobody --with-fpm-group=nobody --with-fpm-systemd=no \
  --disable-cgi --disable-phpdbg --without-pear \
  --with-openssl="$ossl" --with-zlib --with-curl --with-libxml-dir=/usr \
  --enable-mbstring --enable-xml --enable-dom --enable-simplexml --enable-xmlreader --enable-xmlwriter \
  --with-mysqli=mysqlnd --with-pdo-mysql=mysqlnd "${mysql[@]}" --enable-mysqlnd --with-pdo-sqlite --with-sqlite3 \
  "${zip[@]}" --with-bz2 --enable-bcmath "${intl[@]}" --enable-exif --enable-ftp --enable-sockets \
  --enable-opcache "${gd[@]}" > "$work/configure.log" 2>&1 || { tail -40 "$work/configure.log"; exit 1; }
make -j"$(nproc)" > "$work/make.log" 2>&1 || { grep -m5 -B2 -A5 ' error' "$work/make.log" || tail -40 "$work/make.log"; exit 1; }
make install > "$work/install.log" 2>&1 || { tail -20 "$work/install.log"; exit 1; }
cd /

# Keep only what runs; the headers, man pages and build tools are not needed on a server.
rm -rf "$prefix/include" "$prefix/php/man" "$prefix/man" "$prefix/lib/php/build" "$prefix/bin/phpize" "$prefix/bin/php-config"
mkdir -p "$prefix/etc/conf.d" "$prefix/etc/php-fpm.d"
cp "$work/php/php.ini-production" "$prefix/etc/php.ini"
# The CA bundle of EL, for PHP's own OpenSSL (its built-in default path is the temporary build folder).
printf 'openssl.cafile=/etc/pki/tls/certs/ca-bundle.crt\ncurl.cainfo=/etc/pki/tls/certs/ca-bundle.crt\n' > "$prefix/etc/conf.d/00-ca.ini"
echo "zend_extension=opcache.so" > "$prefix/etc/conf.d/10-opcache.ini"
cat > "$prefix/etc/php-fpm.conf" << EOF
[global]
pid = /run/php-fpm-$mm.pid
error_log = syslog
syslog.ident = php-fpm$mm
include = $prefix/etc/php-fpm.d/*.conf
EOF
strip --strip-unneeded "$prefix/bin/php" "$prefix/sbin/php-fpm" "$prefix"/lib/php/extensions/*/*.so 2> /dev/null || true

# --- check ----------------------------------------------------------------------------------------------------------------------
fail=0
expect() { if [ "$2" = "$3" ]; then echo "ok    $1"; else echo "FAIL  $1 -> $3 (wanted $2)"; fail=1; fi; }
"$prefix/bin/php" -v
expect "php -v says $ver" "$ver" "$("$prefix/bin/php" -r 'echo PHP_VERSION;')"
exts=(curl gd mbstring mysqli pdo_mysql openssl xml dom simplexml zip zlib bcmath exif json "Zend OPcache")
[ "${#intl[@]}" = 0 ] || exts+=(intl)
[ "$php5" = 1 ] && exts+=(mysql) # the old mysql_* functions, which the code of PHP 5 sites still calls
for e in "${exts[@]}"; do
  expect "extension $e loads" yes "$("$prefix/bin/php" -r "echo extension_loaded('$e') ? 'yes' : 'no';")"
done
if [ "$php5" = 1 ]; then
  expect "gd has jpeg, png, freetype" 111 "$("$prefix/bin/php" -r '$i=gd_info(); echo (int)$i["JPEG Support"],(int)$i["PNG Support"],(int)$i["FreeType Support"];')"
else
  expect "gd has jpeg, png, webp, freetype" 1111 "$("$prefix/bin/php" -r '$i=gd_info(); echo (int)$i["JPEG Support"],(int)$i["PNG Support"],(int)$i["WebP Support"],(int)$i["FreeType Support"];')"
fi
# PHP's own TLS (streams, openssl_*) uses the old OpenSSL built above; the curl extension uses the system libcurl, which brings
# the system's OpenSSL 3 with it. Both must reach an HTTPS site with the system CA bundle.
ldd "$prefix/bin/php" | grep -E 'libssl|libcrypto|libcurl' || true
expect "PHP's OpenSSL is ${ossl_want#OpenSSL }" yes "$("$prefix/bin/php" -r 'echo strpos(OPENSSL_VERSION_TEXT, "'"$ossl_want"'") === 0 ? "yes" : OPENSSL_VERSION_TEXT;')"
expect "TLS 1.2 through PHP streams" yes "$("$prefix/bin/php" -r 'echo defined("STREAM_CRYPTO_METHOD_TLSv1_2_CLIENT") ? "yes" : "no";')"
expect "https through PHP streams" yes "$("$prefix/bin/php" -d openssl.cafile=/etc/pki/tls/certs/ca-bundle.crt -r 'echo @file_get_contents("https://www.php.net/", false, null, 0, 10) !== false ? "yes" : "no";')"
expect "https through curl" 200 "$("$prefix/bin/php" -r '$c=curl_init("https://www.php.net/"); curl_setopt($c, CURLOPT_RETURNTRANSFER, 1); curl_setopt($c, CURLOPT_NOBODY, 1); curl_setopt($c, CURLOPT_TIMEOUT, 20); curl_exec($c); echo curl_getinfo($c, CURLINFO_HTTP_CODE) ?: curl_error($c);')"

# php-fpm answers a request through its socket (cgi-fcgi is not installed, so a tiny FastCGI client in PHP itself is used).
mkdir -p /srv/t && echo '<?php echo "fpm ", PHP_VERSION;' > /srv/t/i.php
cat > "$prefix/etc/php-fpm.d/t.conf" << EOF
[t]
user = nobody
group = nobody
listen = /run/php-t.sock
listen.mode = 0666
pm = static
pm.max_children = 1
EOF
"$prefix/sbin/php-fpm" -t
"$prefix/sbin/php-fpm"
sleep 1
got="$("$prefix/bin/php" -r '
$s = stream_socket_client("unix:///run/php-t.sock"); $p = ["SCRIPT_FILENAME"=>"/srv/t/i.php","REQUEST_METHOD"=>"GET","SERVER_PROTOCOL"=>"HTTP/1.1"];
$rec = function($t,$c){ return pack("CCnnCx",1,$t,1,strlen($c),0).$c; };
$kv = ""; foreach ($p as $k=>$v) $kv .= chr(strlen($k)).chr(strlen($v)).$k.$v;
fwrite($s, $rec(1, pack("nCx5",1,0)).$rec(4,$kv).$rec(4,"").$rec(5,""));
$o = stream_get_contents($s); echo (strpos($o, "fpm '"$ver"'") !== false) ? "yes" : "no";')"
expect "php-fpm runs a page" yes "$got"
kill "$(cat "/run/php-fpm-$mm.pid")" 2> /dev/null || true
rm -f "$prefix/etc/php-fpm.d/t.conf"

[ "$fail" = 0 ] || exit 1
mkdir -p "$out"
tgz="$out/php-${ver}-${el}${suffix}.tar.xz"
tar -C / -cJf "$tgz" "opt/mpn/php/$mm"
ls -l "$tgz"
