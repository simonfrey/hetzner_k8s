# Pinned to a patch release so upgrades are explicit (8.2.35 fixes CVE-2026-109618/109619 "php2shell")
FROM php:8.2.35-apache

RUN a2enmod rewrite headers

COPY vhosts.conf /etc/apache2/sites-available/000-default.conf

COPY data/ /var/www/data/
COPY startuppiratenfeed/ /var/www/startuppiratenfeed/
COPY swpodcastfeed/ /var/www/swpodcastfeed/

EXPOSE 80
