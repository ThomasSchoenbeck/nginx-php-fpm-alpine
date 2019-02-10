FROM alpine:3.9
LABEL Maintainer="Tim de Pater <code@trafex.nl>" \
      Description="Lightweight container with Nginx 1.14 & PHP-FPM 7.2 based on Alpine Linux."

ENV PHPIZE_DEPS \
		autoconf \
		dpkg-dev dpkg \
		file \
		g++ \
		gcc \
		libc-dev \
		make \
		pkgconf \
		re2c

ENV PHP_INI_DIR /usr/local/etc/php
ENV PHP_EXTRA_CONFIGURE_ARGS --enable-fpm --with-fpm-user=www-data --with-fpm-group=www-data --disable-cgi

ENV PHP_CFLAGS="-fstack-protector-strong -fpic -fpie -O2"
ENV PHP_CPPFLAGS="$PHP_CFLAGS"
ENV PHP_LDFLAGS="-Wl,-O1 -Wl,--hash-style=both -pie"

ENV GPG_KEYS CBAF69F173A0FEA4B537F470D66C9593118BCCB6 F38252826ACD957EF380D39F2F7956BC5DA04B5D

ENV PHP_VERSION 7.3.2
ENV PHP_URL="https://secure.php.net/get/php-7.3.2.tar.xz/from/this/mirror" PHP_ASC_URL="https://secure.php.net/get/php-7.3.2.tar.xz.asc/from/this/mirror"
ENV PHP_SHA256="010b868b4456644ae227d05ad236c8b0a1f57dc6320e7e5ad75e86c5baf0a9a8" PHP_MD5=""

# COPY docker-php-source /usr/local/bin/
# COPY php-7.3.2.tar.xz /usr/src/php.tar.xz

COPY --chown=nobody files-to-copy/root/ /

RUN mv /usr/src/php-7.3.2.tar.xz /usr/src/php.tar.xz \
	&& set -eux \
	&& echo ${PHP_INI_DIR} \
	&& mkdir -p "$PHP_INI_DIR/conf.d" \
# allow running as an arbitrary user (https://github.com/docker-library/php/issues/743)
	&& mkdir -p /var/www/html \
	&& chown -R nobody:nobody /var/www/html \
	&& chmod -R 777 /var/www/html

# Setup document root
RUN mkdir -p /var/www/html /usr/src/php/ext /conf.d

RUN set -e \
	&& apk add --no-cache --virtual .build-deps \
		$PHPIZE_DEPS \
		argon2-dev \
		coreutils \
		curl-dev \
		libedit-dev \
		libsodium-dev \
		libxml2-dev \
		openssl-dev \
		sqlite-dev \
		\
	&& export CFLAGS="$PHP_CFLAGS" \
		CPPFLAGS="$PHP_CPPFLAGS" \
		LDFLAGS="$PHP_LDFLAGS" \
	&& docker-php-source extract \
	&& cd /usr/src/php \
	&& gnuArch="$(dpkg-architecture --query DEB_BUILD_GNU_TYPE)" \
	&& ./configure \
		--build="$gnuArch" \
		--with-config-file-path="$PHP_INI_DIR" \
		--with-config-file-scan-dir="$PHP_INI_DIR/conf.d" \
		\
# make sure invalid --configure-flags are fatal errors intead of just warnings
		--enable-option-checking=fatal \
		\
# https://github.com/docker-library/php/issues/439
		--with-mhash \
		\
# --enable-ftp is included here because ftp_ssl_connect() needs ftp to be compiled statically (see https://github.com/docker-library/php/issues/236)
		--enable-ftp \
# --enable-mbstring is included here because otherwise there's no way to get pecl to use it properly (see https://github.com/docker-library/php/issues/195)
		--enable-mbstring \
# --enable-mysqlnd is included here because it's harder to compile after the fact than extensions are (since it's a plugin for several extensions, not an extension in itself)
		--enable-mysqlnd \
# https://wiki.php.net/rfc/argon2_password_hash (7.2+)
		--with-password-argon2 \
# https://wiki.php.net/rfc/libsodium
		--with-sodium=shared \
		\
		--with-curl \
		--with-libedit \
		--with-openssl \
		--with-zlib \
		\
# bundled pcre does not support JIT on s390x
# https://manpages.debian.org/stretch/libpcre3-dev/pcrejit.3.en.html#AVAILABILITY_OF_JIT_SUPPORT
		$(test "$gnuArch" = 's390x-linux-gnu' && echo '--without-pcre-jit') \
		\
		$PHP_EXTRA_CONFIGURE_ARGS \
	&& make -j "$(nproc)" \
	&& make install \
	&& { find /usr/local/bin /usr/local/sbin -type f -perm +0111 -exec strip --strip-all '{}' + || true; } \
	&& make clean \
	\
# https://github.com/docker-library/php/issues/692 (copy default example "php.ini" files somewhere easily discoverable)
	&& cp -v php.ini-* "$PHP_INI_DIR/" \
	\
	&& cd / \
	&& docker-php-source delete \
	\
	&& runDeps="$( \
		scanelf --needed --nobanner --format '%n#p' --recursive /usr/local \
			| tr ',' '\n' \
			| sort -u \
			| awk 'system("[ -e /usr/local/lib/" $1 " ]") == 0 { next } { print "so:" $1 }' \
	)" \
	&& apk add --no-cache --virtual .php-rundeps $runDeps \
	\
	&& apk del .build-deps \
	\
# https://github.com/docker-library/php/issues/443
	&& pecl update-channels \
	&& rm -rf /tmp/pear ~/.pearrc

# Configure nginx
# COPY config/nginx.conf /etc/nginx/nginx.conf
COPY files-to-copy/root/etc/nginx/nginx.conf /etc/nginx/nginx.conf

# Install packages
RUN apk add --no-cache php7 php7-fpm php7-mysqli php7-json php7-openssl php7-curl \
    php7-zlib php7-xml php7-phar php7-intl php7-dom php7-xmlreader php7-ctype \
    php7-mbstring php7-gd nginx supervisor curl tini

# Configure PHP-FPM
# COPY config/fpm-pool.conf /etc/php7/php-fpm.d/www.conf
COPY files-to-copy/root/etc/php7/php-fpm.d/www.conf /etc/php7/php-fpm.d/www.conf
# COPY config/php.ini /etc/php7/conf.d/zzz_custom.ini
COPY files-to-copy/root/etc/php7/conf.d/zzz_custom.ini /etc/php7/conf.d/zzz_custom.ini

# Configure supervisord
# COPY config/supervisord.conf /etc/supervisor/conf.d/supervisord.conf

# Make sure files/folders needed by the processes are accessable when they run under the nobody user
RUN chown -R nobody:nobody \
		/run \
		/var/lib/nginx \
  	/var/tmp/nginx  \
  	/var/log/nginx

RUN chmod -R 777 /usr/local/bin/* \
# sodium was built as a shared module (so that it can be replaced later if so desired), so let's enable it too (https://github.com/docker-library/php/issues/598)
&& docker-php-ext-enable sodium

# Switch to use a non-root user from here on
USER nobody

# Add application
WORKDIR /var/www/html
# COPY --chown=nobody src/ /var/www/html/

# COPY docker-php-* /usr/local/bin/


# Expose the port nginx is reachable on
EXPOSE 8080 9000

# let tini handle all the zombies
ENTRYPOINT ["/sbin/tini", "--"]

# Let supervisord start nginx & php-fpm
CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/conf.d/supervisord.conf"]

# Configure a healthcheck to validate that everything is up&running
HEALTHCHECK --timeout=10s CMD curl --silent --fail http://127.0.0.1:8080/fpm-ping
