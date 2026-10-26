<?php
declare(strict_types=1);
$pdo = new PDO('mysql:host=localhost;dbname=x', 'u', 'p');
$s = str_split('abc');
echo "Hallo {$name}";
define('BAR', true);
