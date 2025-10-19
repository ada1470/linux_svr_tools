<?php
// simple_db_admin.php
// Single-file simple MySQL admin (CRUD + SQL exec + pagination + sort)
// Configure DB credentials below before use.

// ---------------- CONFIG ----------------
$dbHost = '127.0.0.1';
$dbUser = 'root';
$dbPass = '__root_password__';
$defaultDB = 'db_name';// optional default database to open
$perPageDefault = 20;
// ----------------------------------------

session_start();

// Basic HTTP auth protection (optional) - uncomment and set user/pass
if (!isset($_SERVER['PHP_AUTH_USER'])) {
    header('WWW-Authenticate: Basic realm="SimpleDBAdmin"');
    header('HTTP/1.0 401 Unauthorized');
    echo 'Authentication required.';
    exit;
}
if ($_SERVER['PHP_AUTH_USER'] !== $dbUser || $_SERVER['PHP_AUTH_PW'] !== $dbPass) {
// if ($_SERVER['PHP_AUTH_USER'] !== 'camuser' || $_SERVER['PHP_AUTH_PW'] !== 'campass') {
    header('HTTP/1.0 403 Forbidden');
    echo 'Forbidden';
    exit;
}

// Logout from HTTP Basic Auth
if (isset($_GET['logout'])) {
    // force browser to forget credentials
    header('HTTP/1.0 401 Unauthorized');
    header('WWW-Authenticate: Basic realm="SimpleDBAdmin"');
    exit; // browser shows login popup now
}



// Utility functions
function h($s){ return htmlspecialchars((string)$s, ENT_QUOTES, 'UTF-8'); }
function url($params = []){
    $base = strtok($_SERVER['REQUEST_URI'], '?');
    $query = array_merge($_GET, $params);
    return $base . '?' . http_build_query($query);
}

$mysqli = new mysqli($dbHost, $dbUser, $dbPass);
if ($mysqli->connect_errno) {
    die("Connect failed: (".$mysqli->connect_errno.") " . $mysqli->connect_error);
}
$mysqli->set_charset('utf8mb4');

// pick DB
$db = $_GET['db'] ?? $defaultDB;
if ($db) $mysqli->select_db($db);

// handle actions: create/update/delete/execSQL
$flash = '';
if ($_SERVER['REQUEST_METHOD'] === 'POST'){
    // simple CSRF token
    if (!isset($_POST['_token']) || $_POST['_token'] !== ($_SESSION['_token'] ?? '')){
        $flash = 'Invalid token.';
    } else {
        $action = $_POST['action'] ?? '';
        if ($action === 'exec_sql'){
            $sql = $_POST['sql'] ?? '';
            $_SESSION['last_sql'] = $sql;
            // We'll execute later when rendering to show results
            $_SESSION['exec_sql'] = $sql;
        }
        elseif ($action === 'delete_row'){
            $table = $_POST['table'];
            $pk = $_POST['pk'];
            $val = $_POST['pk_val'];
            // protect identifiers
            $table = preg_replace('/[^a-zA-Z0-9_]/','', $table);
            $pk = preg_replace('/[^a-zA-Z0-9_]/','', $pk);
            $stmt = $mysqli->prepare("DELETE FROM `$table` WHERE `$pk` = ? LIMIT 1");
            $stmt->bind_param('s', $val);
            $stmt->execute();
            $flash = 'Deleted rows: ' . $stmt->affected_rows;
            $stmt->close();
        }
        elseif ($action === 'save_row'){
            $table = preg_replace('/[^a-zA-Z0-9_]/','', $_POST['table']);
            $pk = preg_replace('/[^a-zA-Z0-9_]/','', $_POST['pk']);
            $is_new = ($_POST['is_new'] === '1');
            // collect fields
            $fields = $_POST['fields'] ?? [];
            if ($is_new){
                $cols = array_map(function($c){return "`".preg_replace('/[^a-zA-Z0-9_]/','', $c)."`";}, array_keys($fields));
                $placeholders = implode(',', array_fill(0, count($fields), '?'));
                $types = str_repeat('s', count($fields));
                $sql = "INSERT INTO `$table` (".implode(',', $cols).") VALUES ($placeholders)";
                $stmt = $mysqli->prepare($sql);
                $stmt->bind_param($types, ...array_values($fields));
                $stmt->execute();
                $flash = 'Inserted rows: '.$stmt->affected_rows;
                $stmt->close();
            } else {
                $pk_val = $_POST['pk_val'];
                $sets = [];
                foreach ($fields as $c => $v){ $sets[] = "`".preg_replace('/[^a-zA-Z0-9_]/','', $c)."` = ?"; }
                $types = str_repeat('s', count($fields)).'s';
                $sql = "UPDATE `$table` SET " . implode(',', $sets) . " WHERE `$pk` = ? LIMIT 1";
                $stmt = $mysqli->prepare($sql);
                $vals = array_values($fields);
                $vals[] = $pk_val;
                $stmt->bind_param(str_repeat('s', count($vals)), ...$vals);
                $stmt->execute();
                $flash = 'Updated rows: '.$stmt->affected_rows;
                $stmt->close();
            }
        }
    }
}

// generate token
if (empty($_SESSION['_token'])) $_SESSION['_token'] = bin2hex(random_bytes(16));

// fetch databases for sidebar
$databases = [];
$res = $mysqli->query('SHOW DATABASES');
while ($r = $res->fetch_row()) $databases[] = $r[0];
$res->free();

// if db selected, fetch tables
$tables = [];
if ($db){
    $res = $mysqli->query("SHOW TABLES");
    while ($r = $res->fetch_row()) $tables[] = $r[0];
    $res->free();
}

// helpers for columns
function get_columns($mysqli, $table){
    $cols = [];
    $res = $mysqli->query("SHOW COLUMNS FROM `".preg_replace('/[^a-zA-Z0-9_]/','',$table)."`");
    if ($res){
        while ($r = $res->fetch_assoc()){
            $cols[] = $r; // Field, Type, Null, Key, Default, Extra
        }
        $res->free();
    }
    return $cols;
}

// prepare to render table rows if table selected
$table = $_GET['table'] ?? null;
$columns = [];
$rows = [];
$totalRows = 0;
$page = max(1, (int)($_GET['page'] ?? 1));
$perPage = max(1, (int)($_GET['per_page'] ?? $perPageDefault));
$order_by = $_GET['order_by'] ?? null;
$order_dir = strtoupper(($_GET['order_dir'] ?? 'ASC')) === 'DESC' ? 'DESC' : 'ASC';

if ($db && $table){
    $columns = get_columns($mysqli, $table);
    $colNames = array_map(function($c){return $c['Field'];}, $columns);

    // build where / order
    $order_sql = '';
    if ($order_by && in_array($order_by, $colNames)){
        $order_sql = "ORDER BY `".preg_replace('/[^a-zA-Z0-9_]/','',$order_by)."` $order_dir";
    }
    // count
    $res = $mysqli->query("SELECT COUNT(*) FROM `".preg_replace('/[^a-zA-Z0-9_]/','',$table)."`");
    $totalRows = $res ? (int)$res->fetch_row()[0] : 0;
    if ($res) $res->free();

    $offset = ($page-1)*$perPage;
    $sql = "SELECT * FROM `".preg_replace('/[^a-zA-Z0-9_]/','',$table)."` $order_sql LIMIT $offset, $perPage";
    $res = $mysqli->query($sql);
    if ($res){
        while ($r = $res->fetch_assoc()) $rows[] = $r;
        $res->free();
    }
}

// handle exec SQL saved in session
$execResult = null;
$execError = null;
if (!empty($_SESSION['exec_sql'])){
    $sql = $_SESSION['exec_sql'];
    unset($_SESSION['exec_sql']);
    try {
        $res = $mysqli->query($sql);
        if ($res === false){
            $execError = $mysqli->error;
        } else {
            if ($res === true){
                $execResult = ['affected' => $mysqli->affected_rows];
            } else {
                // fetch rows
                $data = [];
                $cols = $res->fetch_fields();
                while ($r = $res->fetch_assoc()) $data[] = $r;
                $execResult = ['cols' => array_map(fn($c)=>$c->name, $cols), 'rows' => $data];
                $res->free();
            }
        }
    } catch (Exception $e){
        $execError = $e->getMessage();
    }
}

// small HTML UI
?><!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Simple DB Admin</title>
<style>
:root{font-family:Inter,Segoe UI,Arial}
body{margin:0;background:#f4f6f8;color:#111}
.wrap{display:flex;min-height:100vh}
.sidebar{width:220px;background:#1f2937;color:#fff;padding:12px 8px}
.main{flex:1;padding:12px}
a{color:#0ea5a4}
.table{width:100%;border-collapse:collapse;margin-top:12px}
.table th, .table td{padding:6px 8px;border:1px solid #e5e7eb;font-size:13px}
.table th{background:#fff;font-weight:600;cursor:pointer}
.controls{display:flex;gap:8px;align-items:center}
.small{font-size:13px;color:#555}
.form-inline{display:flex;gap:8px;align-items:center}
.btn{padding:6px 10px;border-radius:6px;border:1px solid #ddd;background:#fff;cursor:pointer}
.badge{display:inline-block;padding:4px 8px;background:#efefef;border-radius:6px}
.notice{background:#fff3cd;border-left:4px solid #ffecb5;padding:8px;margin-bottom:8px}
code{background:#111827;color:#fff;padding:2px 6px;border-radius:4px}
</style>
</head>
<body>
<div class="wrap">
  <div class="sidebar">
    <h3 style="margin:6px 8px 10px">SimpleDB</h3>
    <div class="small">Connection: <?php echo h($dbHost . ' @ ' . $dbUser);?></div>
    <hr style="border:none;border-top:1px solid #374151;margin:8px 0">
    <div><strong>Databases</strong></div>
    <ul style="list-style:none;padding-left:6px">
      <?php foreach($databases as $d): ?>
        <li style="margin:6px 0"><a href="<?php echo h(url(['db'=>$d, 'table'=>null, 'page'=>1]));?>"><?php echo h($d);?></a></li>
      <?php endforeach; ?>
    </ul>
    <?php if ($db): ?>
      <hr style="border:none;border-top:1px solid #374151;margin:8px 0">
      <div><strong>Tables in <?php echo h($db);?></strong></div>
      <ul style="list-style:none;padding-left:6px">
        <?php foreach($tables as $t): ?>
          <li style="margin:6px 0"><a href="<?php echo h(url(['table'=>$t,'page'=>1]));?>"><?php echo h($t);?></a></li>
        <?php endforeach; ?>
      </ul>
    <?php endif; ?>
    <hr style="border:none;border-top:1px solid #374151;margin:8px 0">
    <div class="small">Tip: set DB creds at top of the file. This is a development tool — do not expose publicly.</div>
  </div>
  <div class="main">
    <div style="display:flex;flex-wrap:wrap;justify-content:space-between;align-items:center;gap:10px;max-width:1200px;margin-inline:left">
      <h2 style="margin:0;flex:1;min-width:200px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap">
        <?php echo h($db ? ($table ? $db . ' / ' . $table : $db) : 'No database selected'); ?>
      </h2>
    
      <div class="controls" style="flex-shrink:0;display:flex;align-items:center;gap:6px">
        <form method="get" class="form-inline" style="margin:0;display:flex;align-items:center;gap:6px">
          <input type="hidden" name="db" value="<?php echo h($db);?>">
          <label class="small" style="display:flex;align-items:center;gap:4px">
            Per page
            <input
              name="per_page"
              type="number"
              min="1"
              max="1200"
              value="<?php echo h($perPage);?>"
              style="width:70px;padding:4px;border:1px solid #ccc;border-radius:4px;text-align:center"
            >
          </label>
          <button class="btn" type="submit">Apply</button>
        </form>
    
        <!-- Logout button -->
        <a href="#" class="btn" style="background:#d32f2f;color:#fff"
           onclick="
              if(confirm('Are you sure you want to log out?\n\nNote: You will need to close this tab before logging in again.')) {
                  window.location.href='?logout=1';
              } else {
                  // do nothing or stay on the current page
              }
           ">
           Logout
        </a>


      </div>
    </div>



    <?php if ($flash): ?><div class="notice"><?php echo h($flash);?></div><?php endif; ?>

    <!-- SQL Executor -->
    <div style="margin-top:10px;background:#fff;padding:10px;border-radius:8px;max-width:1200px;overflow-x:auto;margin-inline:left">
      <form method="post" id="sqlExecutorForm" style="display:flex;flex-direction:column;gap:10px">
        <input type="hidden" name="_token" value="<?php echo h($_SESSION['_token']);?>">
        <input type="hidden" name="action" value="exec_sql">
    
        <div style="display:flex;flex-wrap:wrap;gap:8px;align-items:flex-start">
          <textarea
            name="sql"
            id="sqlTextarea"
            rows="8"
            style="flex:1;min-width:300px;max-width:900px;padding:8px;font-family:monospace;font-size:14px;resize:vertical;border:1px solid #ccc;border-radius:4px"
          ><?php echo h($_SESSION['last_sql'] ?? 'SELECT 1'); ?></textarea>
    
          <div style="width:180px;display:flex;flex-direction:column;flex-shrink:0">
            <button class="btn" style="margin-bottom:8px" type="submit">Run SQL</button>
            <!-- Reset button now clears textarea without reloading -->
            <button type="button" class="btn" style="margin-bottom:8px;background:#f0ad4e;color:#000"
                    onclick="document.getElementById('sqlTextarea').value='SELECT 1';">
              Reset
            </button>
            <div class="small" style="margin-top:8px;line-height:1.4">
              You can run SELECT or data queries.<br>Results shown below.<br><strong>Use with caution.</strong>
            </div>
          </div>
        </div>
      </form>



      <?php if ($execError): ?><div class="notice">Error: <?php echo h($execError);?></div><?php endif; ?>
      <?php if ($execResult): ?>
        <?php if (isset($execResult['affected'])): ?>
          <div class="small">Affected rows: <?php echo h($execResult['affected']);?></div>
        <?php else: ?>
          <div style="overflow:auto;margin-top:8px">
            <table class="table"><thead><tr><?php foreach($execResult['cols'] as $c) echo "<th>".h($c)."</th>"; ?></tr></thead>
            <tbody>
            <?php foreach($execResult['rows'] as $r): ?><tr><?php foreach($execResult['cols'] as $c): ?><td><?php echo h($r[$c]);?></td><?php endforeach;?></tr><?php endforeach; ?>
            </tbody></table>
            <div class="small">Rows: <?php echo count($execResult['rows']);?></div>
          </div>
        <?php endif; ?>
      <?php endif; ?>
    </div>

    <?php if ($table): ?>
      <div style="margin-top:12px;background:#fff;padding:12px;border-radius:8px;overflow-x:auto;">
        <div style="display:flex;justify-content:space-between;align-items:center">
          <div><strong>Structure</strong> — columns: <?php echo count($columns);?></div>
          <div class="small">Total rows: <?php echo $totalRows;?></div>
        </div>

        <!-- improved table wrapper + column width limits -->
        <style>
  .table-wrapper {
    overflow-x: auto;
  }
  table.table {
    border-collapse: collapse;
    width: auto;
  }
  .table th,
  .table td {
    max-width: 260px;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
</style>


        <div style="overflow-x:auto">
        <table class="table" style="margin-top:8px"><thead><tr>
          <th style="width:48px">#</th>
          <?php foreach($columns as $col): $c=$col['Field']; $is_sorted = ($order_by==$c); ?>
            <th onclick="location.href='<?php echo h(url(['order_by'=>$c,'order_dir'=>$is_sorted && $order_dir=='ASC' ? 'DESC' : 'ASC','page'=>1])); ?>'" title="<?php echo h($c); ?>"><?php echo h($c);?><?php if($is_sorted) echo ' '.($order_dir=='ASC'?'▲':'▼'); ?></th>
          <?php endforeach; ?>
          <th class="actions">Actions</th>
        </tr></thead>
        <tbody>
          <?php $i = $offset + 1; foreach($rows as $row): ?>
            <tr>
              <td><?php echo $i++;?></td>
              <?php foreach($columns as $col): $fn=$col['Field']; ?><td title="<?php echo h($row[$fn]); ?>"><?php echo h($row[$fn]);?></td><?php endforeach; ?>
              <td class="actions">
                <?php
                $pk_col = null; foreach($columns as $c) if ($c['Key']==='PRI'){ $pk_col=$c['Field']; break; }
                ?>
                <a class="btn" href="<?php echo h(url(['action'=>'edit','pk_val'=>urlencode($row[$pk_col] ?? ''),'page'=>$page]));?>">Edit</a>
                <form method="post" style="display:inline" onsubmit="return confirm('Delete row?');">
                  <input type="hidden" name="_token" value="<?php echo h($_SESSION['_token']);?>">
                  <input type="hidden" name="action" value="delete_row">
                  <input type="hidden" name="table" value="<?php echo h($table);?>">
                  <input type="hidden" name="pk" value="<?php echo h($pk_col);?>">
                  <input type="hidden" name="pk_val" value="<?php echo h($row[$pk_col] ?? ''); ?>">
                  <button class="btn" type="submit">Delete</button>
                </form>
              </td>
            </tr>
          <?php endforeach; ?>
        </tbody></table>
        </div>

        <!-- pagination -->
        <?php
        $pages = max(1, ceil($totalRows / $perPage));
        if ($pages > 1):
          $range = 2; // how many pages before and after current
          $page = max(1, min($page, $pages));
        
          echo '<div style="margin-top:12px;display:flex;flex-wrap:wrap;gap:6px;align-items:center;justify-content:left">';
          echo '<div class="small">Page</div>';
        
          // previous button
          if ($page > 1) {
            echo '<a class="btn" href="' . h(url(['page' => $page - 1])) . '">« Prev</a>';
          }
        
          // helper to render page link
          $showPage = function($p, $active = false) {
              $cls = $active ? 'btn" style="background:#1976d2;color:#fff' : 'btn';
              echo '<a class="' . $cls . '" href="' . h(url(['page' => $p])) . '">' . $p . '</a>';
          };
        
          // show first pages
          for ($p = 1; $p <= 2 && $p <= $pages; $p++) {
              $showPage($p, $p == $page);
          }
        
          // ellipsis before middle
          if ($page - $range > 3) echo '<span style="padding:0 6px">...</span>';
        
          // middle range
          for ($p = max(3, $page - $range); $p <= min($pages - 2, $page + $range); $p++) {
              $showPage($p, $p == $page);
          }
        
          // ellipsis after middle
          if ($page + $range < $pages - 2) echo '<span style="padding:0 6px">...</span>';
        
          // last pages
          for ($p = max($pages - 1, 3); $p <= $pages; $p++) {
              if ($p > 2) $showPage($p, $p == $page);
          }
        
          // next button
          if ($page < $pages) {
            echo '<a class="btn" href="' . h(url(['page' => $page + 1])) . '">Next »</a>';
          }
        
          // Jump to page
          echo '<form method="get" style="display:inline-flex;align-items:center;margin-left:10px">'
             . '<input type="hidden" name="table" value="' . h($table) . '">'
             . '<input type="number" name="page" min="1" max="' . $pages . '" value="' . $page . '" '
             . 'style="width:70px;padding:4px;border:1px solid #ccc;border-radius:4px;text-align:center">'
             . '<button class="btn" type="submit">Go</button>'
             . '</form>';
        
          echo '</div>';
        endif;
        ?>


        <!-- Edit / Insert form -->
        <?php if (isset($_GET['action']) && $_GET['action']==='edit'): 
            $pk_val = $_GET['pk_val'] ?? '';
            $is_new = ($pk_val === 'new');
            $form_row = [];
            if (!$is_new){
                $pk = $pk_col;
                $stmt = $mysqli->prepare("SELECT * FROM `".preg_replace('/[^a-zA-Z0-9_]/','',$table)."` WHERE `$pk` = ? LIMIT 1");
                $stmt->bind_param('s', $pk_val);
                $stmt->execute();
                $res = $stmt->get_result();
                $form_row = $res->fetch_assoc() ?: [];
                $stmt->close();
            }
        ?>
          <div style="margin-top:12px">
            <form method="post">
              <input type="hidden" name="_token" value="<?php echo h($_SESSION['_token']);?>">
              <input type="hidden" name="action" value="save_row">
              <input type="hidden" name="table" value="<?php echo h($table);?>">
              <input type="hidden" name="pk" value="<?php echo h($pk_col);?>">
              <input type="hidden" name="is_new" value="<?php echo $is_new ? '1' : '0'; ?>">
              <input type="hidden" name="pk_val" value="<?php echo h($pk_val);?>">
              <table class="table"><tbody>
                <?php foreach($columns as $col): $fn=$col['Field']; ?>
                  <tr><td style="width:160px"><strong><?php echo h($fn);?></strong><div class="small"><?php echo h($col['Type']);?></div></td>
                  <td><input name="fields[<?php echo h($fn);?>]" value="<?php echo h($form_row[$fn] ?? ''); ?>" style="width:100%"></td></tr>
                <?php endforeach; ?>
              </tbody></table>
              <div style="margin-top:8px"><button class="btn" type="submit"><?php echo $is_new ? 'Insert' : 'Save';?></button>
              <a class="btn" href="<?php echo h(url(['action'=>null,'page'=>$page]));?>">Cancel</a></div>
            </form>
          </div>
        <?php else: ?>
          <div style="margin-top:12px">
            <a class="btn" href="<?php echo h(url(['action'=>'edit','pk_val'=>'new']));?>">Insert new row</a>
            <a class="btn" href="<?php echo h(url(['action'=>'edit','pk_val'=>'new','page'=>$page]));?>">Insert</a>
          </div>
        <?php endif; ?>

      </div>
    <?php endif; ?>


  </div>
</div>
</body>
</html>
