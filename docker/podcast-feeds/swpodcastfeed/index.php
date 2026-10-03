<?php

$createEpisodesFromStartDate = new DateTime('2023-12-20');
/*
ini_set('display_errors', '1');
ini_set('display_startup_errors', '1');
error_reporting(E_ALL);
*/
function getWeekHash($date) {
    return md5($date->format('Y-W'));
}

function parseRSSFeed($xmlString) {
    $xml = new SimpleXMLElement($xmlString, LIBXML_NOCDATA);
    $episodes = [];
    foreach ($xml->channel->item as $item) {
        $pubDate = new DateTime($item->pubDate);
        $episodes[] = [
            'title' => (string)$item->title,
            'pubDate' => $pubDate,
            'fullItem' => $item->asXML()  // Store the full item as XML text
        ];
    }
    return ['xml' => $xml, 'episodes' => $episodes];
}

function getAllTuesdays($startDate, $endDate) {
    $tuesdays = [];
    $current = clone $startDate;
    while ($current->format('N') != 2) {
        $current->modify('+1 day');
    }
    while ($current <= $endDate) {
        $tuesdays[] = clone $current;
        $current->modify('+1 week');
    }
    return $tuesdays;
}

function replaceItemDetails($item, $dateKey, $tuesday) {
    $newTitle = '[BestOf]';
    $newPubDate = $tuesday->format('D, d M Y H:i:s O');

    // Replace title and pubDate
    $item = preg_replace('/<title>(.*?)<\/title>/', "<title>$newTitle \$1</title>", $item);
    $item = preg_replace('/<itunes:title>(.*?)<\/itunes:title>/', "<itunes:title>$newTitle \$1</itunes:title>", $item);
    $item = preg_replace('/<pubDate>(.*?)<\/pubDate>/', "<pubDate>$newPubDate</pubDate>", $item);
    $item = preg_replace('/<itunes:image(.*?)\/>/', '<itunes:image href="https://simon-frey.com/files/swpod_bestof_cover.jpg"/>', $item);

    // Update GUID to reflect replay and avoid conflicts with the original item
    $item = preg_replace('/<guid(.*?)>(.*?)<\/guid>/', "<guid\$1>\$2-replay-$dateKey</guid>", $item);

    return $item;
}

// Enable proper XML handling
libxml_use_internal_errors(true);

// Get and process the feed from local backup
$feedContent = file_get_contents('/var/www/data/swpodcast_feed.xml');

// Parse the feed
$parsedFeed = parseRSSFeed($feedContent);
$xml = $parsedFeed['xml'];
$episodes = $parsedFeed['episodes'];

// Sort episodes by date
usort($episodes, function($a, $b) {
    return $a['pubDate'] <=> $b['pubDate'];
});

// Get start and end dates
$startDate = clone $episodes[0]['pubDate'];
$startDate = $startDate->setTime(8, 0, 0);
$endDate = new DateTime();

// Get all Tuesdays
$allTuesdays = getAllTuesdays($startDate, $endDate);

// Create episodes map
$episodesByDate = [];
$allValidEpisodes = [];
foreach ($episodes as $episode) {
	  if (strpos($episode['title'], "[BestOf]") !== false) {
        continue;
    }
    $dateKey = $episode['pubDate']->format('Y-m-d');
    $episodesByDate[$dateKey] = $episode;
    array_push($allValidEpisodes,$episode);
}

// Insert all items into a chronological list
$allItems = [];
foreach ($allTuesdays as $k => $tuesday) {
    $dateKey = $tuesday->format('Y-m-d');
    if (isset($episodesByDate[$dateKey])) {
        $newItem = $episodesByDate[$dateKey]['fullItem'];
    } else {
	// Only have an episode for the last thursday
	if ($k != count($allTuesdays)-1){
		continue;
	}

	// Only do it for tuesdays after the startDate. If is before startDate. Continue
	if ($tuesday < $createEpisodesFromStartDate){
		continue;
	}
        $randomIndex = (($k+3)*3) % count($allValidEpisodes);
        $fillerEpisode = $allValidEpisodes[$randomIndex];

        // Create new filler item by treating it as text
        $newItem = replaceItemDetails($fillerEpisode['fullItem'], $dateKey, $tuesday);
    }
    $newItem = preg_replace('/<itunes:episode>(.*?)<\/itunes:episode>/', "<itunes:episode>$k</itunes:episode>", $newItem);

    $allItems[] = $newItem;
}

usort($allItems, function($a, $b) use ($episodes) {
    $pubDateA = (new DateTime(preg_match('/<pubDate>(.*?)<\/pubDate>/', $a, $match) ? $match[1] : ''))->getTimestamp();
    $pubDateB = (new DateTime(preg_match('/<pubDate>(.*?)<\/pubDate>/', $b, $match) ? $match[1] : ''))->getTimestamp();
    return $pubDateB <=> $pubDateA; // Sort descending
});

// Remove all existing items from the feed content
$channelContent = preg_replace('/<item>.*?<\/item>/s', '', $xml->channel->asXML());

// Re-insert all items in the correct order
$itemsStr = implode('', $allItems);
$feedContent = strstr($feedContent, '<channel>', true) . '<channel>' . strstr($channelContent, '<title>');
$feedContent = str_replace('</channel>', $itemsStr . '</channel>', $feedContent);
$feedContent = $feedContent."</rss>";

// Perform replacements - point feed self-links to our domain
$feedContent = str_replace("https://feeds.transistor.fm/schwarz-auf-weiss-der-bucherpodcast","https://swpodcastfeed.simon-frey.com",$feedContent);
$feedContent = str_replace("https://feeds.transistor.fm/stylesheet.xsl","https://swpodcastfeed.simon-frey.com/stylesheet.xsl",$feedContent);
$feedContent = str_replace("https://feeds.acast.com/public/shows/66c2f1cbbc2cd0e1690dd4b1","https://swpodcastfeed.simon-frey.com",$feedContent);
$feedContent = str_replace("https://feed.swpodcast.de","https://swpodcastfeed.simon-frey.com",$feedContent);
$feedContent = str_replace("/global/feed/rss.xslt","https://swpodcastfeed.simon-frey.com/stylesheet.xsl",$feedContent);

// Output the modified feed
header("content-type: text/xml; charset=utf-8");
echo $feedContent;
exit();
?>
