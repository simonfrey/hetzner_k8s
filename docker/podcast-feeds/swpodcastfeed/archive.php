<?php
$feed = file_get_contents('/var/www/data/swpodcast_feed.xml');

// Replace feed self-links to our domain
$feed = str_replace("https://feeds.transistor.fm/schwarz-auf-weiss-der-bucherpodcast","https://swpodcastfeed.simon-frey.com",$feed);
$feed = str_replace("https://feeds.transistor.fm/stylesheet.xsl","https://swpodcastfeed.simon-frey.com/stylesheet.xsl",$feed);
$feed = str_replace("https://feeds.acast.com/public/shows/66c2f1cbbc2cd0e1690dd4b1","https://swpodcastfeed.simon-frey.com",$feed);
$feed = str_replace("https://feed.swpodcast.de","https://swpodcastfeed.simon-frey.com",$feed);
$feed = str_replace("/global/feed/rss.xslt","https://swpodcastfeed.simon-frey.com/stylesheet.xsl",$feed);

header("content-type: text/xml; charset=utf-8");
echo $feed;
exit();
?>
