<?php
function isMobile() {
    // List of mobile indicators in User-Agent
    $mobileAgents = [
        'iPhone', 'iPad', 'iPod', 'Android', 'BlackBerry', 
        'Opera Mini', 'IEMobile', 'Mobile', 'Silk', 'Kindle'
    ];

    $userAgent = $_SERVER['HTTP_USER_AGENT'] ?? '';

    foreach ($mobileAgents as $device) {
        if (stripos($userAgent, $device) !== false) {
            return true; // Mobile detected
        }
    }
    return false; // Assume PC if no match
}

// Example usage
// if (isMobile()) {
//     echo "You are using a mobile device.";
// } else {
//     echo "You are using a PC (desktop).";
// }

echo $_SERVER['HTTP_USER_AGENT'];
file_put_contents('ua.txt',  $_SERVER['HTTP_USER_AGENT'].PHP_EOL, FILE_APPEND);
?>
