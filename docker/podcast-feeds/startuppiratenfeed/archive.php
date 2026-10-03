<?php
$feed = file_get_contents('/var/www/data/startuppiraten_feed.xml');

// Replace feed self-links to our domain
$feed = str_replace("https://feeds.transistor.fm/digitales-standbein","https://startuppiratenfeed.simon-frey.com",$feed);
$feed = str_replace("https://feeds.transistor.fm/stylesheet.xsl","https://startuppiratenfeed.simon-frey.com/stylesheet.xsl",$feed);
$feed = str_replace("https://feeds.acast.com/public/shows/66c47e31a294c7a662d49dfc","https://startuppiratenfeed.simon-frey.com",$feed);
$feed = str_replace("https://feed.startuppiraten.de","https://startuppiratenfeed.simon-frey.com",$feed);
$feed = str_replace("/global/feed/rss.xslt","https://startuppiratenfeed.simon-frey.com/stylesheet.xsl",$feed);

header("content-type: text/xml; charset=utf-8");
echo $feed;
exit();
?>
