<?php

// $client_ip = $_SERVER['REMOTE_ADDR'];
// $client_ip = getUserIpAddr();

// if ($_GET['pass'] != 'admin1235') {
//     mlog("$client_ip\tNotallowed"); // write visited ips to log
//     exit('Forbidden');
// } else {
//     mlog("$client_ip"); // write visited ips to log
// }

// header('Content-Type: text/plain');
define('ROOT',__DIR__);
$server_ip = $_SERVER['SERVER_ADDR'];
$server_name = $_SERVER['SERVER_NAME'];
$http_host = $_SERVER['HTTP_HOST'];


$dir2scan = 'site';
//$filelist = 'list.txt';
$file_configs = 'file_configs.txt';
$array = 'site';
$elems[] = 'template_dir';
$elems[] = 'site_name';
$elems[] = 'templatefanmulu_dir';

$array2 = 'seo';
$elems[] = 'open';
$elems[] = 'jump';
$elems[] = 'indexhide';
$elems[] = 'userhide';
$elems[] = 'jumpfilm';
$elems[] = 'indexjump';
$elems[] = 'gg';

$scan = scandir($dir2scan);
$site_tpl_configs = array();

$type = '正规';
$base = basename(ROOT);
$dir = $base;


// if (strpos($dir,'fanmulu') || strpos($dir,'fml')) {
//     $elem = 'tpl';
// }

// if ($dir == "public") {
//     $dir = basename(substr(ROOT,0,strrpos(ROOT,'/')));
//     $elem = 'tpl'; // ---泛目录模板
// }

if ($dir == "public") {
    $dir = $_SERVER['SERVER_NAME'];
	$type = '泛目录';
	$elems[2] = 'tpl';
}

echo "<h1>$server_ip</h1>";
echo "<h2>$type: $dir</h2>";

echo "<style>body{padding:10px;}</style>";
echo "<style>table,th,td {border: 1px dashed grey;border-collapse: collapse;}</style>";
echo "<style>th:nth-child(1) {width:20px!important;}</style>";
echo "<table style='border-spacing: 30px;'>";
$header = [
    '序号',
    '域名',
    'IP',
    '模板',
    '网名',
    '泛目录模板',
    '泛目录状态',
    '跳转状态',
    '首页隐藏',
    '内页隐藏',
    '正片跳转',
    '首页跳转',
    '广告跳转',
    ];
foreach ($header as $head) {
    $str_header .= "<th style='padding:5px;width:100px;'>$head</th>";
}
echo "<tr>$str_header</tr>";

$index = 0;
foreach($scan as $obj) {
    
   if (is_dir("$dir2scan/$obj") && $obj != '.' && $obj != '..') {
      //echo $obj.'';
    //   file_put_contents($filelist,$obj);
        $file2get = "$dir2scan/$obj/config.php";
        //echo $file2get;
      //$config = file_get_contents($file2get);
      //echo $config;
        $cells = [];
        if (file_exists($file2get)) {
            $index++;
            $config = include($file2get);
            $cells[] = $config[$array][$elems[0]];
            $cells[] = $config[$array][$elems[1]];
            $cells[] = json_encode($config[$array][$elems[2]]);
            $cells[] = $config[$array2][$elems[3]];
            
            for ($i = 4; $i < count($elems); $i++) {
                $cells[] = $config[$array][$elems[$i]];
            }

            $url = '<a target="_blank" href="http://'.$obj.'">'.$obj.'</a>';
            if ($_GET['ip'] === true || $_GET['ip'] == 1)
                $ip = gethostbyname($obj);
                
            $str_row = "<td>$index</td><td>$url</td><td>$ip</td>";
            
            foreach ($cells as $cell) {
                if ($cell == 1)
                    $str_row .= "<td style='background-color:lightgreen;'>$cell</td>";
                else
                    $str_row .= "<td>$cell</td>";
            }
            
            if ($obj == $server_name || strpos($http_host,$obj) > -1)
                echo "<tr style='background-color:darkorange;'>$str_row</tr>";
            else
                echo "<tr>$str_row</tr>";
                
            
            // foreach ($cells as $cell) {
            //     $str_elems_file .= "$cell\t";
            // }
            // array_push($site_tpl_configs,"$obj\t$ip\t$tpl\t$site\t$tpl_fml\n");
        } else {
            echo 'File is not exist: ' . $file2get;
        }
      
   }
}


file_put_contents($file_configs,$site_tpl_configs);

function getUserIpAddr()
{
    if (!empty($_SERVER['HTTP_CLIENT_IP'])) {
        $ip = $_SERVER['HTTP_CLIENT_IP'];
    } elseif (!empty($_SERVER['HTTP_X_FORWARDED_FOR'])) {
        $ip = $_SERVER['HTTP_X_FORWARDED_FOR'];
    } else {
        $ip = $_SERVER['REMOTE_ADDR'];
    }
    return $ip;
}


function mlog($mes)
{
    $time = date('Y/m/d H:i:s');
    $file_name = 'getconfig_ip.log';
    $line = "[$time] $mes".PHP_EOL;
    file_put_contents($file_name,$line, FILE_APPEND);
}