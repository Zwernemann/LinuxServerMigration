<?php
/*
 * mysql-compat.php – bildet die in PHP 7.0 entfernten mysql_*-Funktionen
 * mit mysqli nach, damit alter Code unter PHP 8 unverändert weiterläuft.
 *
 * Wird von LinuxServerMigration per auto_prepend_file geladen
 * (/etc/php.d/95-mysql-compat.ini). Langfristig sollte der Code trotzdem auf
 * mysqli/PDO mit Prepared Statements umgestellt werden.
 *
 * Verhalten wie bei ext/mysql:
 *  - Fehler liefern false + Warnung statt Exceptions
 *  - ohne Link-Parameter wird die zuletzt geöffnete Verbindung verwendet
 *  - Client-Zeichensatz latin1 (Standard von ext/mysql), bis der Code selbst
 *    "SET NAMES" bzw. mysql_set_charset() aufruft
 */

if (!function_exists('mysql_connect')) {

    if (!defined('MYSQL_ASSOC')) {
        define('MYSQL_ASSOC', MYSQLI_ASSOC);
        define('MYSQL_NUM', MYSQLI_NUM);
        define('MYSQL_BOTH', MYSQLI_BOTH);
        define('MYSQL_CLIENT_COMPRESS', MYSQLI_CLIENT_COMPRESS);
        define('MYSQL_CLIENT_SSL', MYSQLI_CLIENT_SSL);
        define('MYSQL_CLIENT_INTERACTIVE', MYSQLI_CLIENT_INTERACTIVE);
        define('MYSQL_CLIENT_IGNORE_SPACE', MYSQLI_CLIENT_IGNORE_SPACE);
    }

    $GLOBALS['__mysql_compat_link'] = null;
    $GLOBALS['__mysql_compat_error'] = array('', 0);

    /** mysqli ohne Exceptions aufrufen (PHP 8.1+ wirft sonst mysqli_sql_exception) */
    function __mysql_compat_call(callable $fn)
    {
        $driver = new mysqli_driver();
        $old = $driver->report_mode;
        mysqli_report(MYSQLI_REPORT_OFF);
        try {
            return $fn();
        } finally {
            mysqli_report($old);
        }
    }

    function __mysql_compat_link($link, $func)
    {
        if ($link instanceof mysqli) {
            return $link;
        }
        if ($link === null && $GLOBALS['__mysql_compat_link'] instanceof mysqli) {
            return $GLOBALS['__mysql_compat_link'];
        }
        trigger_error("$func(): no MySQL-Link resource supplied", E_USER_WARNING);
        return false;
    }

    function __mysql_compat_result($result, $func)
    {
        if ($result instanceof mysqli_result) {
            return $result;
        }
        trigger_error("$func(): supplied argument is not a valid MySQL result resource", E_USER_WARNING);
        return false;
    }

    function mysql_connect($server = null, $username = null, $password = null, $new_link = false, $client_flags = 0)
    {
        $server = $server ?? (ini_get('mysql.default_host') ?: 'localhost');
        $username = $username ?? (ini_get('mysql.default_user') ?: '');
        $password = $password ?? (ini_get('mysql.default_password') ?: '');
        $host = $server;
        $port = null;
        $socket = null;
        if (strpos($server, ':') !== false && substr_count($server, ':') === 1) {
            list($host, $rest) = explode(':', $server, 2);
            if (ctype_digit($rest)) {
                $port = (int)$rest;
            } else {
                $socket = $rest;
            }
            if ($host === '') {
                $host = 'localhost';
            }
        }
        $link = __mysql_compat_call(function () use ($host, $username, $password, $port, $socket, $client_flags) {
            $l = mysqli_init();
            if (!@mysqli_real_connect($l, $host, $username, $password, null, $port, $socket, $client_flags)) {
                $GLOBALS['__mysql_compat_error'] = array(mysqli_connect_error(), mysqli_connect_errno());
                return false;
            }
            mysqli_set_charset($l, 'latin1');
            return $l;
        });
        if ($link === false) {
            trigger_error('mysql_connect(): ' . $GLOBALS['__mysql_compat_error'][0], E_USER_WARNING);
            return false;
        }
        $GLOBALS['__mysql_compat_link'] = $link;
        return $link;
    }

    function mysql_pconnect($server = null, $username = null, $password = null, $client_flags = 0)
    {
        return mysql_connect($server, $username, $password, false, $client_flags);
    }

    function mysql_select_db($database_name, $link = null)
    {
        $l = __mysql_compat_link($link, __FUNCTION__);
        return $l ? __mysql_compat_call(function () use ($l, $database_name) { return mysqli_select_db($l, $database_name); }) : false;
    }

    function mysql_query($query, $link = null)
    {
        $l = __mysql_compat_link($link, __FUNCTION__);
        return $l ? __mysql_compat_call(function () use ($l, $query) { return mysqli_query($l, $query); }) : false;
    }

    function mysql_unbuffered_query($query, $link = null)
    {
        $l = __mysql_compat_link($link, __FUNCTION__);
        return $l ? __mysql_compat_call(function () use ($l, $query) { return mysqli_query($l, $query, MYSQLI_USE_RESULT); }) : false;
    }

    function mysql_db_query($database, $query, $link = null)
    {
        return mysql_select_db($database, $link) ? mysql_query($query, $link) : false;
    }

    function mysql_fetch_array($result, $result_type = MYSQL_BOTH)
    {
        $r = __mysql_compat_result($result, __FUNCTION__);
        if (!$r) {
            return false;
        }
        $row = mysqli_fetch_array($r, $result_type);
        return $row === null ? false : $row;
    }

    function mysql_fetch_assoc($result)
    {
        return mysql_fetch_array($result, MYSQL_ASSOC);
    }

    function mysql_fetch_row($result)
    {
        return mysql_fetch_array($result, MYSQL_NUM);
    }

    function mysql_fetch_object($result, $class_name = 'stdClass', $params = array())
    {
        $r = __mysql_compat_result($result, __FUNCTION__);
        if (!$r) {
            return false;
        }
        $obj = $params ? mysqli_fetch_object($r, $class_name, $params) : mysqli_fetch_object($r, $class_name);
        return $obj === null ? false : $obj;
    }

    function mysql_fetch_lengths($result)
    {
        $r = __mysql_compat_result($result, __FUNCTION__);
        return $r ? mysqli_fetch_lengths($r) : false;
    }

    function mysql_num_rows($result)
    {
        $r = __mysql_compat_result($result, __FUNCTION__);
        return $r ? mysqli_num_rows($r) : false;
    }

    function mysql_num_fields($result)
    {
        $r = __mysql_compat_result($result, __FUNCTION__);
        return $r ? mysqli_num_fields($r) : false;
    }

    function mysql_result($result, $row, $field = 0)
    {
        $r = __mysql_compat_result($result, __FUNCTION__);
        if (!$r || !mysqli_data_seek($r, $row)) {
            return false;
        }
        $data = mysqli_fetch_array($r, MYSQLI_BOTH);
        if ($data === null) {
            return false;
        }
        if (is_string($field) && strpos($field, '.') !== false && !array_key_exists($field, $data)) {
            $field = substr($field, strrpos($field, '.') + 1);
        }
        return array_key_exists($field, $data) ? $data[$field] : false;
    }

    function mysql_data_seek($result, $row_number)
    {
        $r = __mysql_compat_result($result, __FUNCTION__);
        return $r ? mysqli_data_seek($r, $row_number) : false;
    }

    function mysql_field_name($result, $field_offset)
    {
        $r = __mysql_compat_result($result, __FUNCTION__);
        $f = $r ? mysqli_fetch_field_direct($r, $field_offset) : false;
        return $f ? $f->name : false;
    }

    function mysql_field_table($result, $field_offset)
    {
        $r = __mysql_compat_result($result, __FUNCTION__);
        $f = $r ? mysqli_fetch_field_direct($r, $field_offset) : false;
        return $f ? $f->table : false;
    }

    function mysql_field_len($result, $field_offset)
    {
        $r = __mysql_compat_result($result, __FUNCTION__);
        $f = $r ? mysqli_fetch_field_direct($r, $field_offset) : false;
        return $f ? $f->length : false;
    }

    function mysql_free_result($result)
    {
        $r = __mysql_compat_result($result, __FUNCTION__);
        if ($r) {
            mysqli_free_result($r);
            return true;
        }
        return false;
    }

    function mysql_affected_rows($link = null)
    {
        $l = __mysql_compat_link($link, __FUNCTION__);
        return $l ? mysqli_affected_rows($l) : -1;
    }

    function mysql_insert_id($link = null)
    {
        $l = __mysql_compat_link($link, __FUNCTION__);
        return $l ? mysqli_insert_id($l) : false;
    }

    function mysql_error($link = null)
    {
        $l = ($link instanceof mysqli) ? $link : $GLOBALS['__mysql_compat_link'];
        return $l instanceof mysqli ? mysqli_error($l) : $GLOBALS['__mysql_compat_error'][0];
    }

    function mysql_errno($link = null)
    {
        $l = ($link instanceof mysqli) ? $link : $GLOBALS['__mysql_compat_link'];
        return $l instanceof mysqli ? mysqli_errno($l) : $GLOBALS['__mysql_compat_error'][1];
    }

    function mysql_real_escape_string($unescaped_string, $link = null)
    {
        $l = __mysql_compat_link($link, __FUNCTION__);
        return $l ? mysqli_real_escape_string($l, (string)$unescaped_string) : false;
    }

    function mysql_escape_string($unescaped_string)
    {
        return addcslashes((string)$unescaped_string, "\\\x00\n\r'\"\x1a");
    }

    function mysql_set_charset($charset, $link = null)
    {
        $l = __mysql_compat_link($link, __FUNCTION__);
        return $l ? mysqli_set_charset($l, $charset) : false;
    }

    function mysql_client_encoding($link = null)
    {
        $l = __mysql_compat_link($link, __FUNCTION__);
        return $l ? mysqli_character_set_name($l) : false;
    }

    function mysql_ping($link = null)
    {
        $l = __mysql_compat_link($link, __FUNCTION__);
        return $l ? __mysql_compat_call(function () use ($l) { return @mysqli_ping($l); }) : false;
    }

    function mysql_get_server_info($link = null)
    {
        $l = __mysql_compat_link($link, __FUNCTION__);
        return $l ? mysqli_get_server_info($l) : false;
    }

    function mysql_get_client_info()
    {
        return mysqli_get_client_info();
    }

    function mysql_get_host_info($link = null)
    {
        $l = __mysql_compat_link($link, __FUNCTION__);
        return $l ? mysqli_get_host_info($l) : false;
    }

    function mysql_stat($link = null)
    {
        $l = __mysql_compat_link($link, __FUNCTION__);
        return $l ? mysqli_stat($l) : false;
    }

    function mysql_close($link = null)
    {
        $l = __mysql_compat_link($link, __FUNCTION__);
        if (!$l) {
            return false;
        }
        if ($l === $GLOBALS['__mysql_compat_link']) {
            $GLOBALS['__mysql_compat_link'] = null;
        }
        return mysqli_close($l);
    }
}
