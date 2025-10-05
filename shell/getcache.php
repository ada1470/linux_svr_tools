<?php
// if ($_GET['pass'] != 'admin1235') exit('Forbidden');
// header('Content-Type: text/plain');
define('ROOT',__DIR__);
$server_ip = $_SERVER['SERVER_ADDR'];
$server_name = $_SERVER['SERVER_NAME'];
$http_host = $_SERVER['HTTP_HOST'];



$dir2scan = 'site';
//$filelist = 'list.txt';
$file_configs = 'file_configs.txt';
$array = 'cache';
$elems = [
    'user_index',
    'user_type',
    'user_detail',
    'user_play',
    'spider_index',
    'spider_type',
    'spider_detail',
    'spider_play',
    'cache'
    ];

$array2 = 'seo';


$scan = scandir($dir2scan);
$site_tpl_configs = array();


$type = '正规';
$base = basename(ROOT);
$dir = $base;

if ($dir == "public") {
    $dir = $_SERVER['SERVER_NAME'];
    $elems = [
    'home',
    'nohome',
    'pre_play',
    'pre_play_URL',
    'pre_detail_URL',
    'home_tdk',
    ];
    $type = '泛目录';
}

// var_dump($type);die;
echo "<h1>$server_ip</h1>";
echo "<h2>$type: $dir</h2>";

$str_elems = "<th>序号</th><th>域名</th>";
foreach ($elems as $elem) {
    $str_elems .= "<th style='width:100px;'>$elem</th>";
}

echo "<style>table,th,td {border: 1px dashed grey;border-collapse: collapse;}</style>";
echo "<style>th:nth-child(1) {width:20px!important;}</style>";
echo "<table style='border-spacing: 30px;'>";

echo "<tr>$str_elems</tr>";
$index = 0;
foreach($scan as $obj) {
   if (is_dir("$dir2scan/$obj") && $obj != '.' && $obj != '..') {
      //echo $obj.'';
    //   file_put_contents($filelist,$obj);
        $file2get = "$dir2scan/$obj/config.php";
        //echo $file2get;
      //$config = file_get_contents($file2get);
      //echo $config;
        if (file_exists($file2get)) {
            $index++;
            $config = include($file2get);
            $cells = [];
            for($i=0;$i<count($elems)-1;$i++) {
                $cells[] = $config[$array][$elems[$i]];
            }
            
            if ($base != "public"){
                $cells[] = $config[$array2][$elems[8]];
            } else {
                $cells[] = $config[$array][$elems[count($elems)-1]];
            }
            
            $url = '<a target="_blank" href="http://'.$obj.'">'.$obj.'</a>';
            
            $str_row = "<td>$index</td><td>$url</td>";
            foreach ($cells as $cell) {
                $str_row .= "<td>$cell</td>";
            }
            if ($obj == $server_name || strpos($http_host,$obj) > -1)
                echo "<tr style='background-color:darkorange;'>$str_row</tr>";
            else
                echo "<tr>$str_row</tr>";
                
        } else {
            echo 'File is not exist: ' . $file2get;
        }
      
   }
}


file_put_contents($file_configs,$site_tpl_configs);